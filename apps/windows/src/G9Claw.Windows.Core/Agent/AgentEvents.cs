namespace G9Claw.Windows.Core;

public enum AgentEventKind
{
    SessionCreated,
    ContentDelta,
    ReasoningDelta,
    ContextBudget,
    CompactStarted,
    CompactCompleted,
    ToolUse,
    ToolResult,
    PermissionRequest,
    SubagentStatus,
    Status,
    TokenBudget,
    StreamEnd,
    Complete,
    Abort,
    Error,
    TurnStarted,
    TurnCompleted,
}

public sealed record AgentEvent(
    AgentEventKind Kind,
    string SessionId,
    string? Text = null,
    AgentToolCall? ToolCall = null,
    AgentToolResult? ToolResult = null,
    PermissionRequest? PermissionRequest = null,
    SubagentStatusPayload? SubagentStatus = null,
    ContextBudgetPayload? ContextBudget = null,
    CompactStartedPayload? CompactStarted = null,
    CompactCompletedPayload? CompactCompleted = null,
    TokenBudget? TokenBudget = null,
    AgentTurn? Turn = null)
{
    public static AgentEvent SessionCreated(string sessionId) => new(AgentEventKind.SessionCreated, sessionId);
    public static AgentEvent ContentDelta(string sessionId, string text) => new(AgentEventKind.ContentDelta, sessionId, Text: text);
    public static AgentEvent ReasoningDelta(string sessionId, string text) => new(AgentEventKind.ReasoningDelta, sessionId, Text: text);
    public static AgentEvent Context(string sessionId, int used, int total, ContextBudgetLevel level) =>
        new(AgentEventKind.ContextBudget, sessionId, ContextBudget: new ContextBudgetPayload(used, total, level));
    public static AgentEvent CompactStart(string sessionId, string trigger, int preTokens) =>
        new(AgentEventKind.CompactStarted, sessionId, CompactStarted: new CompactStartedPayload(trigger, preTokens));
    public static AgentEvent CompactComplete(string sessionId, string status, int preTokens, int postTokens) =>
        new(AgentEventKind.CompactCompleted, sessionId, CompactCompleted: new CompactCompletedPayload(status, preTokens, postTokens));
    public static AgentEvent ToolUse(string sessionId, AgentToolCall call) => new(AgentEventKind.ToolUse, sessionId, ToolCall: call);
    public static AgentEvent ToolResultEvent(string sessionId, AgentToolResult result) => new(AgentEventKind.ToolResult, sessionId, ToolResult: result);
    public static AgentEvent Permission(string sessionId, PermissionRequest request) => new(AgentEventKind.PermissionRequest, sessionId, PermissionRequest: request);
    public static AgentEvent Subagent(string sessionId, string id, string status, string detail) =>
        new(AgentEventKind.SubagentStatus, sessionId, SubagentStatus: new SubagentStatusPayload(id, status, detail));
    public static AgentEvent Status(string sessionId, string text) => new(AgentEventKind.Status, sessionId, Text: text);
    public static AgentEvent Budget(string sessionId, TokenBudget budget) => new(AgentEventKind.TokenBudget, sessionId, TokenBudget: budget);
    public static AgentEvent StreamEnd(string sessionId) => new(AgentEventKind.StreamEnd, sessionId);
    public static AgentEvent Complete(string sessionId) => new(AgentEventKind.Complete, sessionId);
    public static AgentEvent Abort(string sessionId, string reason) => new(AgentEventKind.Abort, sessionId, Text: reason);
    public static AgentEvent Error(string sessionId, string message) => new(AgentEventKind.Error, sessionId, Text: message);
}

public sealed record SubagentStatusPayload(
    string Id,
    string Status,
    string Detail);

public sealed record ContextBudgetPayload(
    int Used,
    int Total,
    ContextBudgetLevel Level);

public sealed record CompactStartedPayload(
    string Trigger,
    int PreTokens);

public sealed record CompactCompletedPayload(
    string Status,
    int PreTokens,
    int PostTokens);

public static class AgentEventNormalizer
{
    public static IReadOnlyList<AgentEvent> FromProviderEvent(string sessionId, ProviderStreamEvent providerEvent)
    {
        return providerEvent.Kind switch
        {
            ProviderStreamEventKind.Status when providerEvent.Text is not null =>
                [AgentEvent.Status(sessionId, providerEvent.Text)],
            ProviderStreamEventKind.ContentDelta when providerEvent.Text is not null =>
                [AgentEvent.ContentDelta(sessionId, providerEvent.Text)],
            ProviderStreamEventKind.ReasoningDelta when providerEvent.Text is not null =>
                [AgentEvent.ReasoningDelta(sessionId, providerEvent.Text)],
            ProviderStreamEventKind.ToolCall when providerEvent.ToolCall is not null =>
                [AgentEvent.ToolUse(sessionId, providerEvent.ToolCall)],
            ProviderStreamEventKind.TokenBudget when providerEvent.TokenBudget is not null =>
                [AgentEvent.Budget(sessionId, providerEvent.TokenBudget)],
            ProviderStreamEventKind.Done =>
                [AgentEvent.StreamEnd(sessionId), AgentEvent.Complete(sessionId)],
            _ => [],
        };
    }
}
