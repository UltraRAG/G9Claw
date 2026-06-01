namespace PilotDeck.Windows.Core;

public enum AgentTurnStatus
{
    InProgress,
    Completed,
    Interrupted,
    Failed,
}

public enum TurnLifecycle
{
    Idle,
    RunningModel,
    RunningTool,
    WaitingApproval,
    WaitingUserInput,
    Retrying,
    Completed,
    Failed,
    Cancelled,
}

public enum AgentTurnItemKind
{
    UserMessage,
    AgentMessage,
    Reasoning,
    Plan,
    CommandExecution,
    FileChange,
    ToolCall,
    ToolResult,
    WebSearch,
    ContextCompaction,
    Status,
}

public enum AgentTurnItemStatus
{
    Pending,
    InProgress,
    Completed,
    Failed,
    Declined,
    Interrupted,
}

public sealed record CommandExecutionPayload(
    string Command,
    string Cwd,
    string Stdout,
    string Stderr,
    int? ExitCode,
    int? DurationMs = null);

public sealed record FileChangePayload(
    string Path,
    string Operation,
    string? Diff = null,
    int? Additions = null,
    int? Deletions = null);

public sealed record ToolInvocationPayload(
    string CallId,
    string ToolName,
    string InputJson,
    string? Output,
    bool IsError);

public sealed record WebSearchPayload(
    string Query,
    int? ResultCount);

public sealed record AgentTurnItem(
    string Id,
    int Sequence,
    AgentTurnItemKind Kind,
    AgentTurnItemStatus Status,
    string Title,
    string Text,
    string? ToolName,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? CompletedAt,
    CommandExecutionPayload? CommandExecution,
    FileChangePayload? FileChange,
    ToolInvocationPayload? ToolInvocation,
    string SessionId = "",
    string TurnId = "",
    WebSearchPayload? WebSearch = null)
{
    public bool IsRenderable =>
        !string.IsNullOrWhiteSpace(Title) ||
        !string.IsNullOrWhiteSpace(Text) ||
        ToolInvocation is not null ||
        CommandExecution is not null ||
        FileChange is not null ||
        WebSearch is not null;
}

public sealed record AgentTurn(
    string Id,
    string SessionId,
    Guid RunToken,
    string WorkspacePath,
    AgentTurnStatus Status,
    ChatRunMode Mode,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? CompletedAt,
    List<AgentTurnItem> Items)
{
    public bool HasPendingWork =>
        Status == AgentTurnStatus.InProgress &&
        Items.Any(item => item.Status is AgentTurnItemStatus.Pending or AgentTurnItemStatus.InProgress);
}

public sealed record AgentTurnStoreSnapshot(
    string SessionId,
    string? ActiveTurnId,
    List<AgentTurn> Turns);

public sealed record AgentRequest(
    string SessionId,
    string ProjectPath,
    string Prompt,
    List<FileAttachment> Attachments,
    ProviderConfig ProviderConfig,
    string ApiKey,
    List<ChatMessage> PriorMessages,
    int TimeoutMs,
    int ContextWindow,
    ComposerPermissionMode PermissionMode,
    ChatRunMode RunMode,
    ToolPermissionSettings ToolSettings,
    string RouterRoute,
    Dictionary<string, string> NativeConfigValues)
{
    public List<AgentToolExchange> ToolExchanges { get; init; } = [];
    public bool EnableTools { get; init; } = true;
    public bool Stream { get; init; } = true;
    public bool IncludeNativeSystemPrompt { get; init; } = true;
}

public sealed record AgentToolExchange(
    AgentToolCall Call,
    AgentToolResult Result);

public sealed class NativeThreadManager
{
    private readonly Dictionary<string, NativeSession> _sessions = [];

    public NativeSession SessionFor(AgentRequest request)
    {
        if (_sessions.TryGetValue(request.SessionId, out var existing))
        {
            existing.UpdateWorkspacePath(request.ProjectPath);
            return existing;
        }

        var session = new NativeSession(request.SessionId, request.ProjectPath);
        _sessions[request.SessionId] = session;
        return session;
    }

    public void Interrupt(string sessionId)
    {
        if (_sessions.TryGetValue(sessionId, out var session))
        {
            session.InterruptActiveTurn("Interrupted by user.");
        }
    }

    public void Shutdown()
    {
        foreach (var session in _sessions.Values)
        {
            session.InterruptActiveTurn("Shutting down.");
        }

        _sessions.Clear();
    }
}

public sealed class NativeSession
{
    private readonly Dictionary<string, AgentTurn> _turns = [];
    private string _workspacePath;
    private NativeTurnController? _activeTurn;

    public string SessionId { get; }

    public NativeSession(string sessionId, string workspacePath)
    {
        SessionId = sessionId;
        _workspacePath = workspacePath;
    }

    public void UpdateWorkspacePath(string path) => _workspacePath = path;

    public NativeTurnController StartTurn(AgentRequest request)
    {
        _activeTurn?.Interrupt("Superseded by a new turn.");
        _activeTurn = new NativeTurnController(SessionId, request.ProjectPath, request.RunMode);
        var snapshot = _activeTurn.Snapshot();
        _turns[snapshot.Id] = snapshot;
        return _activeTurn;
    }

    public AgentTurnStoreSnapshot Snapshot()
    {
        if (_activeTurn is not null)
        {
            var activeSnapshot = _activeTurn.Snapshot();
            _turns[activeSnapshot.Id] = activeSnapshot;
            if (activeSnapshot.Status != AgentTurnStatus.InProgress)
            {
                _activeTurn = null;
            }
        }

        return new AgentTurnStoreSnapshot(
            SessionId,
            _activeTurn?.TurnId,
            _turns.Values.OrderBy(turn => turn.StartedAt).ToList());
    }

    public void InterruptActiveTurn(string reason)
    {
        _activeTurn?.Interrupt(reason);
        Snapshot();
    }
}

public sealed class NativeTurnController
{
    private readonly List<AgentTurnItem> _items = [];
    private readonly Dictionary<string, string> _itemIdByToolCallId = [];
    private int _nextSequence;

    public string TurnId { get; }
    public Guid RunToken { get; } = Guid.NewGuid();
    public string SessionId { get; }
    public string WorkspacePath { get; }
    public ChatRunMode Mode { get; private set; }
    public AgentTurnStatus Status { get; private set; } = AgentTurnStatus.InProgress;
    public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; private set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? CompletedAt { get; private set; }

    public NativeTurnController(string sessionId, string workspacePath, ChatRunMode mode)
    {
        TurnId = $"turn-{Guid.NewGuid():D}";
        SessionId = sessionId;
        WorkspacePath = workspacePath;
        Mode = mode;
    }

    public AgentTurn Snapshot() => new(
        TurnId,
        SessionId,
        RunToken,
        WorkspacePath,
        Status,
        Mode,
        StartedAt,
        UpdatedAt,
        CompletedAt,
        _items.ToList());

    public bool Accepts(Guid runToken) => runToken == RunToken && Status == AgentTurnStatus.InProgress;

    public AgentTurnItem RecordUserMessage(string text) =>
        MakeItem(AgentTurnItemKind.UserMessage, AgentTurnItemStatus.Completed, "User", text);

    public AgentTurnItem RecordStatus(string title, string text = "") =>
        MakeItem(AgentTurnItemKind.Status, AgentTurnItemStatus.InProgress, title, text);

    public AgentTurnItem RecordContextCompaction(NativeContextRecoveryResult compaction) =>
        MakeItem(
            AgentTurnItemKind.ContextCompaction,
            AgentTurnItemStatus.InProgress,
            "Compacting context",
            $"trigger={compaction.Trigger}, status={compaction.Status}, {compaction.PreTokens:N0} -> {compaction.PostTokens:N0} tokens");

    public AgentTurnItem? RecordAssistantText(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        return MakeItem(AgentTurnItemKind.AgentMessage, AgentTurnItemStatus.Completed, "", text);
    }

    public AgentTurnItem RecordToolCall(AgentToolCall call)
    {
        var item = MakeItem(
            ItemKindForTool(call.Name),
            AgentTurnItemStatus.InProgress,
            call.Name,
            "",
            call.Name,
            toolInvocation: new ToolInvocationPayload(call.Id, call.Name, call.InputJson, null, false));
        _itemIdByToolCallId[call.Id] = item.Id;
        return item;
    }

    public (AgentTurnItem? CallItem, AgentTurnItem ResultItem) RecordToolResult(AgentToolResult result)
    {
        var displayAsError = result.IsError && !result.IsBenignVerification;
        AgentTurnItem? updatedCall = null;
        if (_itemIdByToolCallId.TryGetValue(result.CallId, out var itemId))
        {
            var index = _items.FindIndex(item => item.Id == itemId);
            if (index >= 0)
            {
                var original = _items[index];
                updatedCall = original with
                {
                    Status = displayAsError ? AgentTurnItemStatus.Failed : AgentTurnItemStatus.Completed,
                    Text = result.Output,
                    UpdatedAt = DateTimeOffset.UtcNow,
                    CompletedAt = DateTimeOffset.UtcNow,
                    ToolInvocation = original.ToolInvocation is null
                        ? null
                        : original.ToolInvocation with { Output = result.Output, IsError = displayAsError },
                };
                _items[index] = updatedCall;
            }
        }

        var resultItem = MakeItem(
            AgentTurnItemKind.ToolResult,
            displayAsError ? AgentTurnItemStatus.Failed : AgentTurnItemStatus.Completed,
            displayAsError ? $"{result.ToolName} failed" : $"{result.ToolName} result",
            result.Output,
            result.ToolName,
            toolInvocation: new ToolInvocationPayload(result.CallId, result.ToolName, "", result.Output, displayAsError));

        return (updatedCall, resultItem);
    }

    public void MarkPlanExited()
    {
        Mode = ChatRunMode.Agent;
        UpdatedAt = DateTimeOffset.UtcNow;
    }

    public void Finish()
    {
        if (Status != AgentTurnStatus.InProgress) return;
        CompleteOpenItems(AgentTurnItemStatus.Completed);
        Status = AgentTurnStatus.Completed;
        CompletedAt = UpdatedAt = DateTimeOffset.UtcNow;
    }

    public void Fail(string reason)
    {
        CompleteOpenItems(AgentTurnItemStatus.Failed);
        MakeItem(AgentTurnItemKind.Status, AgentTurnItemStatus.Failed, "Error", reason);
        Status = AgentTurnStatus.Failed;
        CompletedAt = UpdatedAt = DateTimeOffset.UtcNow;
    }

    public void Interrupt(string reason)
    {
        CompleteOpenItems(AgentTurnItemStatus.Interrupted);
        MakeItem(AgentTurnItemKind.Status, AgentTurnItemStatus.Interrupted, "Interrupted", reason);
        Status = AgentTurnStatus.Interrupted;
        CompletedAt = UpdatedAt = DateTimeOffset.UtcNow;
    }

    private AgentTurnItem MakeItem(
        AgentTurnItemKind kind,
        AgentTurnItemStatus status,
        string title,
        string text,
        string? toolName = null,
        CommandExecutionPayload? commandExecution = null,
        FileChangePayload? fileChange = null,
        ToolInvocationPayload? toolInvocation = null)
    {
        var now = DateTimeOffset.UtcNow;
        var sequence = ++_nextSequence;
        var item = new AgentTurnItem(
            $"{TurnId}-{sequence}",
            sequence,
            kind,
            status,
            title,
            text,
            toolName,
            now,
            now,
            status == AgentTurnItemStatus.InProgress ? null : now,
            commandExecution,
            fileChange,
            toolInvocation,
            SessionId,
            TurnId);
        _items.Add(item);
        UpdatedAt = now;
        return item;
    }

    private static AgentTurnItemKind ItemKindForTool(string toolName)
    {
        var lower = AgentToolNameCanonicalizer.Canonical(toolName).ToLowerInvariant();
        if (lower == "bash" || lower.Contains("shell", StringComparison.Ordinal))
        {
            return AgentTurnItemKind.CommandExecution;
        }

        if (lower is "write" or "strreplace" or "delete" or "editnotebook")
        {
            return AgentTurnItemKind.FileChange;
        }

        if (lower is "grep" or "glob" or "semanticsearch" or "websearch" or "webfetch" or "readlints")
        {
            return AgentTurnItemKind.WebSearch;
        }

        if (lower is "skill" or "task" or "await")
        {
            return AgentTurnItemKind.ToolCall;
        }

        if (lower.Contains("switchmode", StringComparison.Ordinal) ||
            lower.Contains("exitplan", StringComparison.Ordinal) ||
            lower.Contains("plan", StringComparison.Ordinal))
        {
            return AgentTurnItemKind.Plan;
        }

        return AgentTurnItemKind.ToolCall;
    }

    private void CompleteOpenItems(AgentTurnItemStatus status)
    {
        var now = DateTimeOffset.UtcNow;
        for (var i = 0; i < _items.Count; i++)
        {
            if (_items[i].Status != AgentTurnItemStatus.InProgress) continue;
            _items[i] = _items[i] with
            {
                Status = status,
                UpdatedAt = now,
                CompletedAt = now,
            };
        }
    }
}
