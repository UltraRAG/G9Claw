using System.Text;
using System.Text.Json;
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
        turn.RecordUserMessage(request.Prompt);
        await writer.WriteAsync(new AgentEvent(AgentEventKind.TurnStarted, request.SessionId, Turn: turn.Snapshot()), cancellationToken);

        var assistantText = new StringBuilder();
        TokenBudget? lastBudget = null;

        try
        {
            var toolExchanges = new List<AgentToolExchange>();
            var currentRequest = request;
            var rootGlobPolicy = new AgentRootGlobExecutionPolicy();
            var planModePolicy = new AgentPlanModePolicy(request.RunMode);
            var planTodoGate = new AgentPlanTodoExecutionGate();
            var deduplicationPolicy = new AgentToolDeduplicationPolicy();
            var deletionVerificationPolicy = new AgentDeletionVerificationPolicy();
            var round = 0;
            var duplicateOnlyRounds = 0;
            while (true)
            {
                await writer.WriteAsync(
                    AgentEvent.Status(request.SessionId, round == 0 ? "Connecting to provider..." : "Continuing with tool results..."),
                    cancellationToken);
                var roundExchanges = new List<AgentToolExchange>();
                var roundSkippedDuplicateTool = false;
                await foreach (var providerEvent in _providerClient.StreamAsync(currentRequest, cancellationToken))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    foreach (var agentEvent in AgentEventNormalizer.FromProviderEvent(request.SessionId, providerEvent))
                    {
                        if (agentEvent.Kind == AgentEventKind.ContentDelta && agentEvent.Text is { } text)
                        {
                            assistantText.Append(text);
                        }
                        else if (agentEvent.Kind == AgentEventKind.TokenBudget)
                        {
                            lastBudget = agentEvent.TokenBudget;
                        }

                        await writer.WriteAsync(agentEvent, cancellationToken);
                    }

                    if (providerEvent.Kind == ProviderStreamEventKind.ToolCall && providerEvent.ToolCall is { } call)
                    {
                        var toolResult = await ExecuteToolAsync(currentRequest, turn, call, options, rootGlobPolicy, planModePolicy, planTodoGate, deduplicationPolicy, deletionVerificationPolicy, cancellationToken);
                        if (toolResult is null)
                        {
                            roundSkippedDuplicateTool = true;
                            await writer.WriteAsync(AgentEvent.Status(request.SessionId, "duplicate tool request skipped"), cancellationToken);
                            continue;
                        }

                        await writer.WriteAsync(AgentEvent.ToolResultEvent(request.SessionId, toolResult), cancellationToken);
                        roundExchanges.Add(new AgentToolExchange(call, toolResult));
                    }

                }

                if (roundExchanges.Count == 0)
                {
                    if (roundSkippedDuplicateTool && duplicateOnlyRounds < 2)
                    {
                        duplicateOnlyRounds++;
                        round++;
                        continue;
                    }

                    break;
                }

                duplicateOnlyRounds = 0;
                toolExchanges.AddRange(roundExchanges);
                currentRequest = request with { ToolExchanges = toolExchanges.ToList() };
                round++;
            }

            if (toolExchanges.Count == 0)
            {
                var fallbackCalls = NativeAgentRuntime.FallbackToolCalls(assistantText.ToString());
                foreach (var fallbackCall in fallbackCalls)
                {
                    await writer.WriteAsync(AgentEvent.ToolUse(request.SessionId, fallbackCall), cancellationToken);
                    var toolResult = await ExecuteToolAsync(request, turn, fallbackCall, options, rootGlobPolicy, planModePolicy, planTodoGate, deduplicationPolicy, deletionVerificationPolicy, cancellationToken);
                    if (toolResult is null)
                    {
                        continue;
                    }

                    await writer.WriteAsync(AgentEvent.ToolResultEvent(request.SessionId, toolResult), cancellationToken);
                }
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

    private async Task<AgentToolResult?> ExecuteToolAsync(
        AgentRequest request,
        NativeTurnController turn,
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
            turn.RecordToolResult(normalized.RecoveryResult);
            return normalized.RecoveryResult;
        }

        var call = normalized.Call;
        turn.RecordToolCall(call);
        if (rootGlobPolicy.CachedResultIfAvailable(call) is { } cached)
        {
            turn.RecordToolResult(cached);
            return cached;
        }

        if (planModePolicy.BlockingResult(call) is { } planBlock)
        {
            turn.RecordToolResult(planBlock);
            return planBlock;
        }

        if (planTodoGate.BlockingResult(call) is { } todoBlock)
        {
            turn.RecordToolResult(todoBlock);
            return todoBlock;
        }

        if (deduplicationPolicy.Deduplicate(call) is { } duplicate)
        {
            if (duplicate.Skip)
            {
                return null;
            }

            turn.RecordToolResult(duplicate.Result!);
            return duplicate.Result;
        }

        if (call.Name == "AskQuestion")
        {
            var questionResult = await AskQuestionAsync(request, turn, call, options, cancellationToken);
            turn.RecordToolResult(questionResult);
            planModePolicy.Record(call, questionResult);
            planTodoGate.Record(call, questionResult);
            deduplicationPolicy.Record(call, questionResult);
            return questionResult;
        }

        var decision = ToolPermissionPolicy.Decide(call, request.ToolSettings, request.PermissionMode);
        if (decision == ToolPermissionDecision.Denied)
        {
            var denied = new AgentToolResult(call.Id, call.Name, "Tool is denied by Settings permissions.", true);
            turn.RecordToolResult(denied);
            return denied;
        }

        if (planModePolicy.RequiresExitPlanApproval(call))
        {
            var approved = await RequestPermissionAsync(
                request,
                call,
                options,
                AgentPlanModePolicy.ExitPlanApprovalReason,
                PermissionRequestKind.ExitPlanMode,
                cancellationToken);
            if (!approved)
            {
                var denied = new AgentToolResult(call.Id, call.Name, "Tool execution was denied.", true);
                turn.RecordToolResult(denied);
                return denied;
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
                turn.RecordToolResult(denied);
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
                    turn.RecordToolResult(denied);
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
            request.NativeConfigValues);
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
        turn.RecordToolResult(result);
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
        var record = _permissionService.Request(request.SessionId, call.Name, inputJsonOverride ?? call.InputJson, reason, kind);
        var resolved = options.PermissionHandler is null
            ? _permissionService.Resolve(record.Request.Id, allow: false)
            : await options.PermissionHandler(record.Request, cancellationToken);
        return resolved.Decision == PermissionDecision.Allowed;
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

        return new AgentToolResult(call.Id, call.Name, string.IsNullOrWhiteSpace(resolved.Response)
            ? "User answered with an empty response."
            : resolved.Response.Trim(), false);
    }

    private static AgentInteractivePayload BuildInteractivePayload(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(inputJson);
            var root = doc.RootElement;
            var question = StringValue(root, "question") ?? StringValue(root, "prompt") ?? "The agent needs more information.";
            var header = StringValue(root, "header") ?? "Question";
            var options = new List<AgentQuestionOption>();
            if (root.TryGetProperty("options", out var values) && values.ValueKind == JsonValueKind.Array)
            {
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
            }

            return new AgentInteractivePayload([new AgentQuestion(header, question, options, false)]);
        }
        catch
        {
            return new AgentInteractivePayload([new AgentQuestion("Question", "The agent needs more information.", [], false)]);
        }
    }

    private static string? StringValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
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
