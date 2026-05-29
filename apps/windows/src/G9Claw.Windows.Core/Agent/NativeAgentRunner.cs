using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace G9Claw.Windows.Core;

public sealed record NativeAgentRunOptions(
    Func<PermissionRequest, CancellationToken, Task<PermissionRecord>>? PermissionHandler = null);

public sealed class NativeAgentRunner
{
    private readonly IProviderClient _providerClient;
    private readonly AgentToolExecutor _toolExecutor;
    private readonly PermissionService _permissionService;
    private readonly NativeThreadManager _threadManager;
    private readonly NativeRunStore _runStore;

    public NativeAgentRunner(
        IProviderClient? providerClient = null,
        AgentToolExecutor? toolExecutor = null,
        PermissionService? permissionService = null,
        NativeThreadManager? threadManager = null,
        NativeRunStore? runStore = null)
    {
        _runStore = runStore ?? new NativeRunStore();
        _providerClient = providerClient ?? new ProviderClient();
        _toolExecutor = toolExecutor ?? new AgentToolExecutor(runStore: _runStore);
        _permissionService = permissionService ?? new PermissionService();
        _threadManager = threadManager ?? new NativeThreadManager();
    }

    public void Interrupt(string sessionId) => _threadManager.Interrupt(sessionId);

    public void Shutdown() => _threadManager.Shutdown();

    public IAsyncEnumerable<AgentEvent> RunAsync(
        AgentRequest request,
        NativeAgentRunOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        options ??= new NativeAgentRunOptions();
        var channel = Channel.CreateUnbounded<AgentEvent>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = true,
        });

        _ = Task.Run(async () =>
        {
            try
            {
                await RunCoreAsync(channel.Writer, request, options, cancellationToken);
                channel.Writer.TryComplete();
            }
            catch (Exception ex)
            {
                channel.Writer.TryComplete(ex);
            }
        }, CancellationToken.None);

        return channel.Reader.ReadAllAsync(cancellationToken);
    }

    private async Task RunCoreAsync(
        ChannelWriter<AgentEvent> writer,
        AgentRequest request,
        NativeAgentRunOptions options,
        CancellationToken cancellationToken)
    {
        var nativeSession = _threadManager.SessionFor(request);
        var turn = nativeSession.StartTurn(request);
        await writer.WriteAsync(new AgentEvent(AgentEventKind.TurnStarted, request.SessionId, Turn: turn.Snapshot()), cancellationToken);
        var userItem = turn.RecordUserMessage(request.Prompt);
        await writer.WriteAsync(AgentEvent.TurnItemCompleted(request.SessionId, userItem), cancellationToken);
        await writer.WriteAsync(AgentEvent.SessionCreated(request.SessionId), cancellationToken);
        await WriteStatusStartedAsync(turn, writer, request.SessionId, "connecting", "", cancellationToken);

        var assistantText = new StringBuilder();
        TokenBudget? lastBudget = null;

        try
        {
            var toolExchanges = request.ToolExchanges.ToList();
            var currentRequest = request;
            var rootGlobPolicy = new AgentRootGlobExecutionPolicy();
            var planModePolicy = new AgentPlanModePolicy(request.RunMode);
            var planTodoGate = new AgentPlanTodoExecutionGate();
            var deduplicationPolicy = new AgentToolDeduplicationPolicy();
            var deletionVerificationPolicy = new AgentDeletionVerificationPolicy();
            var loopWatchdog = new AgentLoopWatchdog();
            var completionGate = new AgentCompletionGate();
            var round = 0;
            var partialStreamRecoveryCount = 0;
            var didRecoverContextOverflow = false;
            var didForceWorkspaceBootstrap = false;
            while (true)
            {
                var roundStatus = round == 0 ? "thinking" : "processing";
                await WriteStatusStartedAsync(turn, writer, request.SessionId, roundStatus, "", cancellationToken);
                var contextBudget = NativeAgentRuntime.ContextBudgetSnapshot(currentRequest);
                await writer.WriteAsync(AgentEvent.Budget(request.SessionId, contextBudget), cancellationToken);
                await writer.WriteAsync(
                    AgentEvent.Context(request.SessionId, contextBudget.Used, contextBudget.Total, NativeAgentRuntime.ContextBudgetLevelFor(contextBudget)),
                    cancellationToken);
                if (NativeAgentRuntime.CompactContextIfNeeded(currentRequest) is { } compaction)
                {
                    await writer.WriteAsync(AgentEvent.CompactStart(request.SessionId, compaction.Trigger, compaction.PreTokens), cancellationToken);
                    currentRequest = currentRequest with
                    {
                        PriorMessages = compaction.PriorMessages,
                        ToolExchanges = compaction.ToolExchanges,
                    };
                    toolExchanges = compaction.ToolExchanges.ToList();
                    var compactItem = turn.RecordContextCompaction(compaction);
                    await writer.WriteAsync(AgentEvent.TurnItemStarted(request.SessionId, compactItem), cancellationToken);
                    await writer.WriteAsync(AgentEvent.Status(request.SessionId, "context compacting"), cancellationToken);
                    await writer.WriteAsync(
                        AgentEvent.CompactComplete(request.SessionId, compaction.Status, compaction.PreTokens, compaction.PostTokens),
                        cancellationToken);
                    await writer.WriteAsync(AgentEvent.Budget(request.SessionId, new TokenBudget(compaction.PostTokens, request.ContextWindow)), cancellationToken);
                    await writer.WriteAsync(
                        AgentEvent.Context(
                            request.SessionId,
                            compaction.PostTokens,
                            request.ContextWindow,
                            NativeAgentRuntime.ContextBudgetLevelFor(new TokenBudget(compaction.PostTokens, request.ContextWindow))),
                        cancellationToken);
                }

                var roundExchanges = new List<AgentToolExchange>();
                var roundSkippedDuplicateTool = false;
                var roundAssistantText = new StringBuilder();
                var deferredPlanContent = new StringBuilder();
                var roundSynthesizedPlanIntro = false;
                try
                {
                    var providerFailedAttempts = 0;
                    while (true)
                    {
                        try
                        {
                            await foreach (var providerEvent in _providerClient.StreamAsync(currentRequest, cancellationToken))
                            {
                                cancellationToken.ThrowIfCancellationRequested();

                                if (providerEvent.Kind == ProviderStreamEventKind.Status && providerEvent.Text is { } status)
                                {
                                    await writer.WriteAsync(AgentEvent.Status(request.SessionId, status), cancellationToken);
                                    continue;
                                }

                                if (providerEvent.Kind == ProviderStreamEventKind.ContentDelta && providerEvent.Text is { } text)
                                {
                                    roundAssistantText.Append(text);
                                    if (ShouldDeferVisiblePlanContent(request.RunMode, planModePolicy.PlanExited))
                                    {
                                        deferredPlanContent.Append(text);
                                    }
                                    else
                                    {
                                        await FlushDeferredContentAsync(deferredPlanContent, assistantText, writer, request.SessionId, cancellationToken);
                                        assistantText.Append(text);
                                        await writer.WriteAsync(AgentEvent.ContentDelta(request.SessionId, text), cancellationToken);
                                    }

                                    continue;
                                }

                                if (providerEvent.Kind == ProviderStreamEventKind.ReasoningDelta && providerEvent.Text is { } reasoning)
                                {
                                    await writer.WriteAsync(AgentEvent.ReasoningDelta(request.SessionId, reasoning), cancellationToken);
                                    continue;
                                }

                                if (providerEvent.Kind == ProviderStreamEventKind.TokenBudget && providerEvent.TokenBudget is { } budget)
                                {
                                    lastBudget = budget;
                                    await writer.WriteAsync(AgentEvent.Budget(request.SessionId, budget), cancellationToken);
                                    continue;
                                }

                                if (providerEvent.Kind == ProviderStreamEventKind.Done)
                                {
                                    await writer.WriteAsync(AgentEvent.StreamEnd(request.SessionId), cancellationToken);
                                    await writer.WriteAsync(AgentEvent.Complete(request.SessionId), cancellationToken);
                                    continue;
                                }

                                if (providerEvent.Kind == ProviderStreamEventKind.ToolCall && providerEvent.ToolCall is { } call)
                                {
                                    if (ShouldShowDeferredPlanContentBeforeTool(deferredPlanContent.ToString(), call, request.RunMode, planModePolicy.PlanExited))
                                    {
                                        await FlushDeferredContentAsync(deferredPlanContent, assistantText, writer, request.SessionId, cancellationToken);
                                    }
                                    else
                                    {
                                        deferredPlanContent.Clear();
                                    }

                                    if (!roundSynthesizedPlanIntro &&
                                        request.RunMode == ChatRunMode.Plan &&
                                        !planModePolicy.PlanExited &&
                                        roundAssistantText.Length == 0 &&
                                        PlanModeIntroSynthesizer.Intro([call], ChatRunMode.Plan) is { } planIntro)
                                    {
                                        roundSynthesizedPlanIntro = true;
                                        assistantText.Append(planIntro);
                                        await writer.WriteAsync(AgentEvent.ContentDelta(request.SessionId, planIntro), cancellationToken);
                                    }

                                    await WritePlanGenerationStatusAsync(writer, request.SessionId, call, EffectiveWorkflowRunMode(request.RunMode, planModePolicy.PlanExited), cancellationToken);
                                    await writer.WriteAsync(AgentEvent.ToolUse(request.SessionId, call), cancellationToken);
                                    var toolResult = await ExecuteToolAsync(currentRequest, turn, writer, call, options, rootGlobPolicy, planModePolicy, planTodoGate, deduplicationPolicy, deletionVerificationPolicy, cancellationToken);
                                    if (toolResult is null)
                                    {
                                        roundSkippedDuplicateTool = true;
                                        await writer.WriteAsync(AgentEvent.Status(request.SessionId, "duplicate tool request skipped"), cancellationToken);
                                        continue;
                                    }

                                    await WriteToolResultEventsAsync(writer, request.SessionId, call, toolResult, cancellationToken);
                                    completionGate.RecordToolResult(call, toolResult);
                                    if (loopWatchdog.RecordToolResult(toolResult) is { } watchdogMessage)
                                    {
                                        throw ProviderClientException.Transport(watchdogMessage);
                                    }

                                    roundExchanges.Add(new AgentToolExchange(call, toolResult));
                                }
                            }

                            partialStreamRecoveryCount = 0;
                            break;
                        }
                        catch (Exception ex) when (ShouldRetryProviderTurn(ex, providerFailedAttempts, cancellationToken))
                        {
                            var decision = NativeAgentRuntime.RetryDecision(ex, providerFailedAttempts);
                            providerFailedAttempts++;
                            await writer.WriteAsync(
                                AgentEvent.Status(request.SessionId, $"Reconnecting... {providerFailedAttempts}/{ProviderRetryPolicy.CodexDefault.StreamMaxRetries}"),
                                cancellationToken);
                            if (decision.Delay > TimeSpan.Zero)
                            {
                                await Task.Delay(decision.Delay, cancellationToken);
                            }
                        }
                    }
                }
                catch (ProviderClientException ex) when (ex.PartialVisibleOutput && partialStreamRecoveryCount < 2)
                {
                    partialStreamRecoveryCount++;
                    toolExchanges.AddRange(roundExchanges);
                    currentRequest = currentRequest with
                    {
                        PriorMessages = RecoveryPriorMessages(currentRequest, ex.Message),
                        ToolExchanges = toolExchanges.ToList(),
                    };
                    await WriteStatusStartedAsync(turn, writer, request.SessionId, "waiting for model response", "partial_stream_timeout_recovery", cancellationToken);
                    round++;
                    continue;
                }
                catch (ProviderClientException ex) when (!didRecoverContextOverflow && NativeAgentRuntime.IsPromptTooLongError(ex))
                {
                    didRecoverContextOverflow = true;
                    toolExchanges.AddRange(roundExchanges);
                    currentRequest = currentRequest with { ToolExchanges = toolExchanges.ToList() };
                    var recovery = NativeAgentRuntime.ForceRecoverContext(currentRequest);
                    await writer.WriteAsync(AgentEvent.CompactStart(request.SessionId, recovery.Trigger, recovery.PreTokens), cancellationToken);
                    toolExchanges = recovery.ToolExchanges.ToList();
                    currentRequest = currentRequest with
                    {
                        PriorMessages = recovery.PriorMessages,
                        ToolExchanges = recovery.ToolExchanges,
                    };
                    var recoveryCompaction = turn.RecordContextCompaction(recovery);
                    await writer.WriteAsync(AgentEvent.TurnItemStarted(request.SessionId, recoveryCompaction), cancellationToken);
                    await WriteStatusStartedAsync(turn, writer, request.SessionId, "context recovering", recovery.Trigger, cancellationToken);
                    await writer.WriteAsync(
                        AgentEvent.CompactComplete(request.SessionId, recovery.Status, recovery.PreTokens, recovery.PostTokens),
                        cancellationToken);
                    await writer.WriteAsync(AgentEvent.Budget(request.SessionId, new TokenBudget(recovery.PostTokens, request.ContextWindow)), cancellationToken);
                    await writer.WriteAsync(
                        AgentEvent.Context(request.SessionId, recovery.PostTokens, request.ContextWindow, ContextBudgetLevel.Recovering),
                        cancellationToken);
                    round++;
                    continue;
                }

                if (roundExchanges.Count == 0)
                {
                    foreach (var fallbackCall in NativeAgentRuntime.FallbackToolCalls(roundAssistantText.ToString()))
                    {
                        await WritePlanGenerationStatusAsync(writer, request.SessionId, fallbackCall, EffectiveWorkflowRunMode(request.RunMode, planModePolicy.PlanExited), cancellationToken);
                        await writer.WriteAsync(AgentEvent.ToolUse(request.SessionId, fallbackCall), cancellationToken);
                        var toolResult = await ExecuteToolAsync(currentRequest, turn, writer, fallbackCall, options, rootGlobPolicy, planModePolicy, planTodoGate, deduplicationPolicy, deletionVerificationPolicy, cancellationToken);
                        if (toolResult is null)
                        {
                            roundSkippedDuplicateTool = true;
                            await writer.WriteAsync(AgentEvent.Status(request.SessionId, "duplicate fallback tool request skipped"), cancellationToken);
                            continue;
                        }

                        await WriteToolResultEventsAsync(writer, request.SessionId, fallbackCall, toolResult, cancellationToken);
                        completionGate.RecordToolResult(fallbackCall, toolResult);
                        if (loopWatchdog.RecordToolResult(toolResult) is { } watchdogMessage)
                        {
                            throw ProviderClientException.Transport(watchdogMessage);
                        }

                        roundExchanges.Add(new AgentToolExchange(fallbackCall, toolResult));
                    }
                }

                if (roundExchanges.Count == 0 &&
                    request.RunMode == ChatRunMode.Plan &&
                    !planModePolicy.PlanExited &&
                    PlanTurnRecoveryClassifier.Recovery(
                        roundAssistantText.ToString(),
                        request.Prompt,
                        planModePolicy.PlanQuestionAnswered) is { } planRecovery)
                {
                    if (!string.IsNullOrWhiteSpace(planRecovery.IntroText))
                    {
                        deferredPlanContent.Clear();
                        assistantText.Append(planRecovery.IntroText);
                        await writer.WriteAsync(AgentEvent.ContentDelta(request.SessionId, planRecovery.IntroText), cancellationToken);
                    }

                    if (deduplicationPolicy.WouldSkipWithoutResult(planRecovery.Call))
                    {
                        await WriteStatusStartedAsync(turn, writer, request.SessionId, PlanWorkflowPresentation.RecoveryNeededStatus, "", cancellationToken);
                        break;
                    }

                    await WriteStatusStartedAsync(turn, writer, request.SessionId, planRecovery.WorkflowStatus, "", cancellationToken);
                    await WriteStatusStartedAsync(turn, writer, request.SessionId, planRecovery.GenerationStatus, "", cancellationToken);
                    await writer.WriteAsync(AgentEvent.ToolUse(request.SessionId, planRecovery.Call), cancellationToken);
                    var toolResult = await ExecuteToolAsync(currentRequest, turn, writer, planRecovery.Call, options, rootGlobPolicy, planModePolicy, planTodoGate, deduplicationPolicy, deletionVerificationPolicy, cancellationToken);
                    if (toolResult is not null)
                    {
                        await WriteToolResultEventsAsync(writer, request.SessionId, planRecovery.Call, toolResult, cancellationToken);
                        completionGate.RecordToolResult(planRecovery.Call, toolResult);
                        if (loopWatchdog.RecordToolResult(toolResult) is { } watchdogMessage)
                        {
                            throw ProviderClientException.Transport(watchdogMessage);
                        }

                        roundExchanges.Add(new AgentToolExchange(planRecovery.Call, toolResult));
                    }
                }

                if (roundExchanges.Count == 0 &&
                    !didForceWorkspaceBootstrap &&
                    WorkspaceBootstrapPolicy.ShouldForceWorkspaceBootstrap(currentRequest, toolExchanges, roundAssistantText.ToString()))
                {
                    didForceWorkspaceBootstrap = true;
                    var bootstrapCall = WorkspaceBootstrapPolicy.ForcedWorkspaceBootstrapToolCall();
                    await WriteStatusStartedAsync(turn, writer, request.SessionId, "exploring workspace", "", cancellationToken);
                    await WritePlanGenerationStatusAsync(writer, request.SessionId, bootstrapCall, EffectiveWorkflowRunMode(request.RunMode, planModePolicy.PlanExited), cancellationToken);
                    await writer.WriteAsync(AgentEvent.ToolUse(request.SessionId, bootstrapCall), cancellationToken);
                    var toolResult = await ExecuteToolAsync(currentRequest, turn, writer, bootstrapCall, options, rootGlobPolicy, planModePolicy, planTodoGate, deduplicationPolicy, deletionVerificationPolicy, cancellationToken);
                    if (toolResult is not null)
                    {
                        await WriteToolResultEventsAsync(writer, request.SessionId, bootstrapCall, toolResult, cancellationToken);
                        completionGate.RecordToolResult(bootstrapCall, toolResult);
                        if (loopWatchdog.RecordToolResult(toolResult) is { } watchdogMessage)
                        {
                            throw ProviderClientException.Transport(watchdogMessage);
                        }

                        roundExchanges.Add(new AgentToolExchange(bootstrapCall, toolResult));
                    }
                }

                if (roundExchanges.Count == 0)
                {
                    if (roundSkippedDuplicateTool)
                    {
                        var decision = loopWatchdog.RecordDuplicateOnlyTurn();
                        if (decision.Kind == AgentLoopWatchdogDecisionKind.ContinueWithNudge)
                        {
                            currentRequest = currentRequest with
                            {
                                PriorMessages = NudgePriorMessages(currentRequest, roundAssistantText.ToString(), decision.Message),
                                ToolExchanges = toolExchanges.ToList(),
                            };
                            await WriteStatusStartedAsync(turn, writer, request.SessionId, "continuing", decision.Message, cancellationToken);
                            round++;
                            continue;
                        }

                        await WriteStatusStartedAsync(turn, writer, request.SessionId, "needs continuation", decision.Message, cancellationToken);
                        break;
                    }

                    var completionDecision = completionGate.Decision(currentRequest, roundAssistantText.ToString());
                    if (completionDecision.Kind == AgentCompletionDecisionKind.ContinueWithNudge)
                    {
                        currentRequest = currentRequest with
                        {
                            PriorMessages = NudgePriorMessages(currentRequest, roundAssistantText.ToString(), completionDecision.Message),
                            ToolExchanges = toolExchanges.ToList(),
                        };
                        await WriteStatusStartedAsync(turn, writer, request.SessionId, "continuing", completionDecision.Message, cancellationToken);
                        round++;
                        continue;
                    }

                    if (completionDecision.Kind == AgentCompletionDecisionKind.PauseNeedsUser)
                    {
                        await WriteStatusStartedAsync(turn, writer, request.SessionId, "needs continuation", completionDecision.Message, cancellationToken);
                        break;
                    }

                    if (completionDecision.Kind == AgentCompletionDecisionKind.RealError)
                    {
                        throw ProviderClientException.Transport(completionDecision.Message);
                    }

                    break;
                }

                loopWatchdog.RecordProgress();
                toolExchanges.AddRange(roundExchanges);
                currentRequest = currentRequest with { ToolExchanges = toolExchanges.ToList() };
                round++;
            }

            turn.RecordAssistantText(assistantText.ToString());
            turn.Finish();
            if (lastBudget is not null)
            {
                await writer.WriteAsync(AgentEvent.Budget(request.SessionId, lastBudget), cancellationToken);
            }

            await writer.WriteAsync(new AgentEvent(AgentEventKind.TurnCompleted, request.SessionId, Turn: turn.Snapshot()), cancellationToken);
            await writer.WriteAsync(AgentEvent.Complete(request.SessionId), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            turn.Interrupt("Interrupted by user.");
            await writer.WriteAsync(AgentEvent.Abort(request.SessionId, "Interrupted by user."), CancellationToken.None);
            await writer.WriteAsync(new AgentEvent(AgentEventKind.TurnCompleted, request.SessionId, Turn: turn.Snapshot()), CancellationToken.None);
        }
        catch (Exception ex)
        {
            turn.Fail(ex.Message);
            await writer.WriteAsync(AgentEvent.Error(request.SessionId, ex.Message), CancellationToken.None);
            await writer.WriteAsync(new AgentEvent(AgentEventKind.TurnCompleted, request.SessionId, Turn: turn.Snapshot()), CancellationToken.None);
        }
    }

    private static List<ChatMessage> RecoveryPriorMessages(AgentRequest request, string message)
    {
        var messages = request.PriorMessages.ToList();
        messages.Add(new ChatMessage(
            Guid.NewGuid(),
            request.SessionId,
            SessionProvider.G9Claw,
            ChatRole.User,
            [ChatBlock.FromText($"""
            The provider response stream disconnected after partial visible output: {message}
            Continue the same task from the latest completed tool result. Do not repeat already completed tool calls unless needed for verification.
            """)],
            DateTimeOffset.UtcNow,
            false,
            null));
        return messages;
    }

    private static List<ChatMessage> NudgePriorMessages(AgentRequest request, string assistantContent, string nudge)
    {
        var messages = request.PriorMessages.ToList();
        if (!string.IsNullOrWhiteSpace(assistantContent))
        {
            messages.Add(new ChatMessage(
                Guid.NewGuid(),
                request.SessionId,
                request.ProviderConfig.Provider,
                ChatRole.Assistant,
                [ChatBlock.FromText(assistantContent)],
                DateTimeOffset.UtcNow,
                false,
                null));
        }

        messages.Add(new ChatMessage(
            Guid.NewGuid(),
            request.SessionId,
            request.ProviderConfig.Provider,
            ChatRole.User,
            [ChatBlock.FromText(nudge)],
            DateTimeOffset.UtcNow,
            false,
            null));
        return messages;
    }

    private static bool ShouldDeferVisiblePlanContent(ChatRunMode runMode, bool planExited) =>
        runMode == ChatRunMode.Plan && !planExited;

    private static bool ShouldRetryProviderTurn(Exception error, int failedAttempts, CancellationToken cancellationToken) =>
        !cancellationToken.IsCancellationRequested &&
        NativeAgentRuntime.RetryDecision(error, failedAttempts).ShouldRetry;

    private static bool ShouldShowDeferredPlanContentBeforeTool(
        string deferredContent,
        AgentToolCall call,
        ChatRunMode runMode,
        bool planExited)
    {
        if (!ShouldDeferVisiblePlanContent(runMode, planExited))
        {
            return !string.IsNullOrWhiteSpace(deferredContent);
        }

        var trimmed = deferredContent.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return false;
        }

        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName is "AskQuestion" or "SwitchMode")
        {
            return false;
        }

        return !LooksLikeInteractiveProtocolText(trimmed) && !LooksLikePotentialPlanText(trimmed);
    }

    private static async Task FlushDeferredContentAsync(
        StringBuilder deferredContent,
        StringBuilder assistantText,
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        CancellationToken cancellationToken)
    {
        if (deferredContent.Length == 0)
        {
            return;
        }

        var text = deferredContent.ToString();
        deferredContent.Clear();
        assistantText.Append(text);
        await writer.WriteAsync(AgentEvent.ContentDelta(sessionId, text), cancellationToken);
    }

    private static bool LooksLikeInteractiveProtocolText(string text)
    {
        var trimmed = text.Trim();
        var lower = trimmed.ToLowerInvariant();
        if (trimmed.StartsWith("{", StringComparison.Ordinal) &&
            (lower.Contains("\"tool\"", StringComparison.Ordinal) ||
             lower.Contains("\"name\"", StringComparison.Ordinal) ||
             lower.Contains("switchmode", StringComparison.Ordinal) ||
             lower.Contains("askquestion", StringComparison.Ordinal)))
        {
            return true;
        }

        return trimmed.StartsWith("<", StringComparison.Ordinal) &&
            (lower.Contains("call", StringComparison.Ordinal) ||
             lower.Contains("tool", StringComparison.Ordinal) ||
             lower.Contains("switchmode", StringComparison.Ordinal) ||
             lower.Contains("askquestion", StringComparison.Ordinal));
    }

    private static bool LooksLikePotentialPlanText(string text)
    {
        var trimmed = text.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return false;
        }

        var lower = trimmed.ToLowerInvariant();
        if (lower.Contains("switchmode", StringComparison.Ordinal))
        {
            return true;
        }

        if (lower.Contains("plan", StringComparison.Ordinal) &&
            (lower.Contains("execute", StringComparison.Ordinal) ||
             lower.Contains("implementation", StringComparison.Ordinal) ||
             lower.Contains("step", StringComparison.Ordinal)))
        {
            return true;
        }

        if (trimmed.StartsWith("#", StringComparison.Ordinal) &&
            lower.Contains("plan", StringComparison.Ordinal))
        {
            return true;
        }

        return Regex.IsMatch(trimmed, @"(?m)^\s*\d+\.\s+.+") &&
            (lower.Contains("implement", StringComparison.Ordinal) ||
             lower.Contains("optimize", StringComparison.Ordinal) ||
             lower.Contains("execute", StringComparison.Ordinal));
    }

    private static ChatRunMode EffectiveWorkflowRunMode(ChatRunMode runMode, bool planExited) =>
        runMode == ChatRunMode.Plan && planExited ? ChatRunMode.Agent : runMode;

    private static async Task WritePlanGenerationStatusAsync(
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        AgentToolCall call,
        ChatRunMode runMode,
        CancellationToken cancellationToken)
    {
        if (PlanWorkflowPresentation.GenerationStatus([call], runMode) is { } status)
        {
            await writer.WriteAsync(AgentEvent.Status(sessionId, status), cancellationToken);
        }
    }

    private static async Task WritePlanWaitingStatusAsync(
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        string toolName,
        ChatRunMode runMode,
        CancellationToken cancellationToken)
    {
        if (PlanWorkflowPresentation.WaitingStatus(toolName, runMode) is { } status)
        {
            await writer.WriteAsync(AgentEvent.Status(sessionId, status), cancellationToken);
        }
    }

    private static async Task<AgentTurnItem> WriteStatusStartedAsync(
        NativeTurnController turn,
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        string title,
        string text,
        CancellationToken cancellationToken)
    {
        var item = turn.RecordStatus(title, text);
        await writer.WriteAsync(AgentEvent.TurnItemStarted(sessionId, item), cancellationToken);
        await writer.WriteAsync(AgentEvent.Status(sessionId, title), cancellationToken);
        return item;
    }

    private static async Task WriteToolResultEventsAsync(
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        AgentToolCall call,
        AgentToolResult result,
        CancellationToken cancellationToken)
    {
        await writer.WriteAsync(AgentEvent.ToolResultEvent(sessionId, result), cancellationToken);
        if (AgentToolNameCanonicalizer.Canonical(call.Name) == "Task")
        {
            await writer.WriteAsync(
                AgentEvent.Subagent(sessionId, call.Id, result.IsError ? "failed" : "completed", result.Output),
                cancellationToken);
        }
    }

    private static async Task<AgentTurnItem> WriteToolCallStartedAsync(
        NativeTurnController turn,
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        AgentToolCall call,
        CancellationToken cancellationToken)
    {
        var item = turn.RecordToolCall(call);
        await writer.WriteAsync(AgentEvent.TurnItemStarted(sessionId, item), cancellationToken);
        return item;
    }

    private static async Task RecordToolResultAsync(
        NativeTurnController turn,
        ChannelWriter<AgentEvent> writer,
        string sessionId,
        AgentToolResult result,
        CancellationToken cancellationToken)
    {
        var recorded = turn.RecordToolResult(result);
        if (recorded.CallItem is not null)
        {
            await writer.WriteAsync(AgentEvent.TurnItemUpdated(sessionId, recorded.CallItem), cancellationToken);
        }

        await writer.WriteAsync(AgentEvent.TurnItemCompleted(sessionId, recorded.ResultItem), cancellationToken);
    }

    private async Task<AgentToolResult?> ExecuteToolAsync(
        AgentRequest request,
        NativeTurnController turn,
        ChannelWriter<AgentEvent> writer,
        AgentToolCall rawCall,
        NativeAgentRunOptions options,
        AgentRootGlobExecutionPolicy rootGlobPolicy,
        AgentPlanModePolicy planModePolicy,
        AgentPlanTodoExecutionGate planTodoGate,
        AgentToolDeduplicationPolicy deduplicationPolicy,
        AgentDeletionVerificationPolicy deletionVerificationPolicy,
        CancellationToken cancellationToken)
    {
        var normalized = ToolArgumentNormalizer.Normalize(rawCall);
        if (normalized.RecoveryResult is not null)
        {
            await RecordToolResultAsync(turn, writer, request.SessionId, normalized.RecoveryResult, cancellationToken);
            return normalized.RecoveryResult;
        }

        var call = normalized.Call;
        await WriteToolCallStartedAsync(turn, writer, request.SessionId, call, cancellationToken);
        var isSubagentTool = AgentToolNameCanonicalizer.Canonical(call.Name) == "Task";
        if (isSubagentTool)
        {
            await writer.WriteAsync(AgentEvent.Subagent(request.SessionId, call.Id, "running", call.InputJson), cancellationToken);
        }

        if (rootGlobPolicy.CachedResultIfAvailable(call) is { } cached)
        {
            await RecordToolResultAsync(turn, writer, request.SessionId, cached, cancellationToken);
            return cached;
        }

        if (planModePolicy.BlockingResult(call) is { } planBlock)
        {
            await RecordToolResultAsync(turn, writer, request.SessionId, planBlock, cancellationToken);
            return planBlock;
        }

        if (planTodoGate.BlockingResult(call) is { } todoBlock)
        {
            await RecordToolResultAsync(turn, writer, request.SessionId, todoBlock, cancellationToken);
            return todoBlock;
        }

        if (deduplicationPolicy.Deduplicate(call) is { } duplicate)
        {
            if (duplicate.Skip)
            {
                return null;
            }

            await RecordToolResultAsync(turn, writer, request.SessionId, duplicate.Result!, cancellationToken);
            return duplicate.Result;
        }

        if (call.Name == "AskQuestion")
        {
            await WritePlanWaitingStatusAsync(writer, request.SessionId, call.Name, request.RunMode, cancellationToken);
            var questionResult = await AskQuestionAsync(request, turn, call, options, cancellationToken);
            await RecordToolResultAsync(turn, writer, request.SessionId, questionResult, cancellationToken);
            planModePolicy.Record(call, questionResult);
            planTodoGate.Record(call, questionResult);
            deduplicationPolicy.Record(call, questionResult);
            return questionResult;
        }

        var decision = ToolPermissionPolicy.Decide(call, request.ToolSettings, request.PermissionMode);
        if (decision == ToolPermissionDecision.Denied)
        {
            var denied = new AgentToolResult(call.Id, call.Name, "Tool is denied by Settings permissions.", true);
            await RecordToolResultAsync(turn, writer, request.SessionId, denied, cancellationToken);
            return denied;
        }

        if (planModePolicy.RequiresExitPlanApproval(call))
        {
            await WritePlanWaitingStatusAsync(writer, request.SessionId, call.Name, request.RunMode, cancellationToken);
            var permission = await RequestPermissionRecordAsync(
                request,
                call,
                options,
                AgentPlanModePolicy.ExitPlanApprovalReason,
                PermissionRequestKind.ExitPlanMode,
                cancellationToken);
            if (permission.Decision != PermissionDecision.Allowed)
            {
                var denied = new AgentToolResult(call.Id, call.Name, "Tool execution was denied.", true);
                await RecordToolResultAsync(turn, writer, request.SessionId, denied, cancellationToken);
                return denied;
            }

            if (!string.IsNullOrWhiteSpace(permission.Response) &&
                ToolArgumentNormalizer.CanonicalObjectJson(permission.Response).Success)
            {
                call = call with { InputJson = permission.Response };
            }
        }
        else if (AgentDestructiveToolClassifier.IsDestructive(call) && !planModePolicy.PlanExecutionApproved)
        {
            var approved = await RequestPermissionAsync(
                request,
                call,
                options,
                AgentDestructiveToolClassifier.ApprovalReason,
                PermissionRequestKind.DestructivePlanApproval,
                cancellationToken,
                AgentDestructiveToolClassifier.PlanJson(call));
            if (!approved)
            {
                var denied = new AgentToolResult(call.Id, call.Name, "Tool execution was denied.", true);
                await RecordToolResultAsync(turn, writer, request.SessionId, denied, cancellationToken);
                return denied;
            }
        }
        else if (!planModePolicy.AllowsWithoutGenericPermission(call))
        {
            if (decision == ToolPermissionDecision.RequiresApproval)
            {
                var approved = await RequestPermissionAsync(
                    request,
                    call,
                    options,
                    ToolPermissionPolicy.Reason(call.Name),
                    PermissionRequestKind.Tool,
                    cancellationToken);
                if (!approved)
                {
                    var denied = new AgentToolResult(call.Id, call.Name, "Tool execution was denied.", true);
                    await RecordToolResultAsync(turn, writer, request.SessionId, denied, cancellationToken);
                    return denied;
                }
            }
        }

        var context = new AgentToolExecutionContext(
            request.SessionId,
            request.ProjectPath,
            request.RunMode,
            request.ToolSettings,
            cancellationToken,
            request.NativeConfigValues,
            ProviderConfig: request.ProviderConfig,
            ApiKey: request.ApiKey,
            TimeoutMs: request.TimeoutMs,
            ContextWindow: request.ContextWindow,
            PermissionMode: request.PermissionMode);
        var result = await _toolExecutor.ExecuteAsync(call, context);
        if (!result.IsError)
        {
            result = rootGlobPolicy.RecordIfRootGlob(call, result);
        }
        result = deletionVerificationPolicy.Record(call, result);

        if (!result.IsError && call.Name == "SwitchMode")
        {
            turn.MarkPlanExited();
        }

        planModePolicy.Record(call, result);
        planTodoGate.Record(call, result);
        deduplicationPolicy.Record(call, result);
        await RecordToolResultAsync(turn, writer, request.SessionId, result, cancellationToken);
        return result;
    }

    private async Task<bool> RequestPermissionAsync(
        AgentRequest request,
        AgentToolCall call,
        NativeAgentRunOptions options,
        string reason,
        PermissionRequestKind kind,
        CancellationToken cancellationToken,
        string? inputJsonOverride = null)
    {
        var resolved = await RequestPermissionRecordAsync(
            request,
            call,
            options,
            reason,
            kind,
            cancellationToken,
            inputJsonOverride);
        return resolved.Decision == PermissionDecision.Allowed;
    }

    private async Task<PermissionRecord> RequestPermissionRecordAsync(
        AgentRequest request,
        AgentToolCall call,
        NativeAgentRunOptions options,
        string reason,
        PermissionRequestKind kind,
        CancellationToken cancellationToken,
        string? inputJsonOverride = null)
    {
        var record = _permissionService.Request(request.SessionId, call.Name, inputJsonOverride ?? call.InputJson, reason, kind);
        return options.PermissionHandler is null
            ? _permissionService.Resolve(record.Request.Id, allow: false)
            : await options.PermissionHandler(record.Request, cancellationToken);
    }

    private async Task<AgentToolResult> AskQuestionAsync(
        AgentRequest request,
        NativeTurnController turn,
        AgentToolCall call,
        NativeAgentRunOptions options,
        CancellationToken cancellationToken)
    {
        if (options.PermissionHandler is null)
        {
            return new AgentToolResult(call.Id, call.Name, "AskQuestion requires an interactive UI handler.", true);
        }

        var payload = BuildInteractivePayload(call.InputJson);
        var record = _permissionService.Request(
            request.SessionId,
            call.Name,
            call.InputJson,
            "The agent is asking for input before continuing.",
            PermissionRequestKind.AskUserQuestion,
            PermissionScope.Session,
            payload);
        var resolved = await options.PermissionHandler(record.Request, cancellationToken);
        if (resolved.Decision != PermissionDecision.Allowed)
        {
            return new AgentToolResult(call.Id, call.Name, "User declined to answer.", true);
        }

        var response = resolved.Response?.Trim() ?? "";
        if (AskQuestionAnswerCodec.HasNonEmptyAnswers(response))
        {
            return new AgentToolResult(call.Id, call.Name, AskQuestionAnswerCodec.Output(response), false);
        }

        return new AgentToolResult(call.Id, call.Name, string.IsNullOrWhiteSpace(response)
            ? "User answered with an empty response."
            : response, false);
    }

    private static AgentInteractivePayload BuildInteractivePayload(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(inputJson);
            var root = doc.RootElement;
            if (root.TryGetProperty("questions", out var questionValues) && questionValues.ValueKind == JsonValueKind.Array)
            {
                var questions = new List<AgentQuestion>();
                foreach (var questionValue in questionValues.EnumerateArray())
                {
                    if (questionValue.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }

                    var itemQuestion = StringValue(questionValue, "question") ?? StringValue(questionValue, "prompt");
                    if (string.IsNullOrWhiteSpace(itemQuestion))
                    {
                        continue;
                    }

                    questions.Add(new AgentQuestion(
                        StringValue(questionValue, "header") ?? "Question",
                        itemQuestion,
                        QuestionOptions(questionValue),
                        BoolValue(questionValue, "multiSelect") ?? false));
                }

                if (questions.Count > 0)
                {
                    return new AgentInteractivePayload(questions);
                }
            }

            var question = StringValue(root, "question") ?? StringValue(root, "prompt") ?? "The agent needs more information.";
            var header = StringValue(root, "header") ?? "Question";
            return new AgentInteractivePayload([new AgentQuestion(header, question, QuestionOptions(root), BoolValue(root, "multiSelect") ?? false)]);
        }
        catch
        {
            return new AgentInteractivePayload([new AgentQuestion("Question", "The agent needs more information.", [], false)]);
        }
    }

    private static List<AgentQuestionOption> QuestionOptions(JsonElement root)
    {
        var options = new List<AgentQuestionOption>();
        if (!root.TryGetProperty("options", out var values) || values.ValueKind != JsonValueKind.Array)
        {
            return options;
        }

        foreach (var option in values.EnumerateArray())
        {
            if (option.ValueKind == JsonValueKind.String)
            {
                options.Add(new AgentQuestionOption(option.GetString() ?? ""));
            }
            else
            {
                options.Add(new AgentQuestionOption(StringValue(option, "label") ?? option.ToString(), StringValue(option, "description")));
            }
        }

        return options;
    }

    private static string? StringValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
    }

    private static bool? BoolValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }
}

public enum ToolPermissionDecision
{
    Allowed,
    Denied,
    RequiresApproval,
}

public static class ToolPermissionPolicy
{
    private static readonly HashSet<string> ApprovalTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "Write",
        "StrReplace",
        "Delete",
        "EditNotebook",
        "Shell",
        "Task",
        "SwitchMode",
    };

    public static ToolPermissionDecision Decide(
        AgentToolCall call,
        ToolPermissionSettings settings,
        ComposerPermissionMode composerMode)
    {
        settings ??= ToolPermissionSettings.Defaults;
        if (MatchesAny(call, settings.DisallowedTools)) return ToolPermissionDecision.Denied;
        if (composerMode == ComposerPermissionMode.BypassPermissions) return ToolPermissionDecision.Allowed;
        if (MatchesAny(call, settings.AllowedTools)) return ToolPermissionDecision.Allowed;
        return ApprovalTools.Contains(AgentToolNameCanonicalizer.Canonical(call.Name))
            ? ToolPermissionDecision.RequiresApproval
            : ToolPermissionDecision.Allowed;
    }

    public static string Reason(string toolName) => AgentToolNameCanonicalizer.Canonical(toolName) switch
    {
        "Shell" => "Shell commands can modify files or run programs.",
        "Write" or "StrReplace" or "EditNotebook" => "This tool changes files in the workspace.",
        "Delete" => "This tool deletes files or folders.",
        "SwitchMode" => "This tool changes the active agent mode.",
        _ => "This tool requires confirmation.",
    };

    private static bool MatchesAny(AgentToolCall call, IEnumerable<string> specs) =>
        specs.Any(spec => Matches(call, spec));

    private static bool Matches(AgentToolCall call, string spec)
    {
        if (string.IsNullOrWhiteSpace(spec)) return false;
        var canonical = AgentToolNameCanonicalizer.Canonical(call.Name);
        var trimmed = spec.Trim();
        var paren = trimmed.IndexOf('(');
        if (paren < 0)
        {
            return string.Equals(canonical, AgentToolNameCanonicalizer.Canonical(trimmed), StringComparison.OrdinalIgnoreCase);
        }

        var name = trimmed[..paren].Trim();
        if (!string.Equals(canonical, AgentToolNameCanonicalizer.Canonical(name), StringComparison.OrdinalIgnoreCase)) return false;
        var pattern = trimmed[(paren + 1)..].TrimEnd(')').Trim();
        if (string.IsNullOrWhiteSpace(pattern) || pattern == "*") return true;
        if (pattern.EndsWith('*'))
        {
            var prefix = pattern[..^1].TrimEnd(':');
            return call.InputJson.Contains(prefix, StringComparison.OrdinalIgnoreCase);
        }

        return call.InputJson.Contains(pattern, StringComparison.OrdinalIgnoreCase);
    }
}
