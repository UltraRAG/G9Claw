namespace PilotDeck.Windows.Core;

public sealed record AlwaysOnCronLatestRun(
    AlwaysOnStatus? Status,
    string? RunId,
    DateTimeOffset? StartedAt,
    string? SessionId,
    string? Summary,
    DateTimeOffset? LastActivity,
    string? TaskId,
    string? OutputFile,
    string? ParentSessionId,
    string? RelativeTranscriptPath,
    string? TranscriptKey)
{
    public string Id => RunId ?? SessionId ?? TaskId ?? TranscriptKey ?? "latest";
}

public sealed record AlwaysOnCronJob(
    string Id,
    string Prompt,
    string Cron,
    AlwaysOnStatus Status,
    bool Recurring,
    bool Durable,
    DateTimeOffset? CreatedAt,
    DateTimeOffset? LastFiredAt,
    string? LatestSessionId,
    bool Permanent = false,
    bool ManualOnly = false,
    string? OriginSessionId = null,
    string? TranscriptKey = null,
    AlwaysOnCronLatestRun? LatestRun = null);

public sealed record AlwaysOnRunHistory(
    string Id,
    string Title,
    string Kind,
    AlwaysOnStatus Status,
    DateTimeOffset StartedAt,
    string SourceId,
    string OutputLog,
    string? SessionId,
    string? ParentSessionId,
    string? RelativeTranscriptPath,
    DateTimeOffset? FinishedAt = null,
    string? Error = null,
    Dictionary<string, string>? Metadata = null,
    string? TranscriptKey = null)
{
    public bool ShouldPollLog => Status is AlwaysOnStatus.Queued or AlwaysOnStatus.Running;
}

public enum AlwaysOnRunLogSource
{
    LogFile,
    Session,
    History,
}

public static class AlwaysOnRunLogSourceExtensions
{
    public static string Id(this AlwaysOnRunLogSource source) => source switch
    {
        AlwaysOnRunLogSource.LogFile => "log-file",
        AlwaysOnRunLogSource.Session => "session",
        AlwaysOnRunLogSource.History => "history",
        _ => source.ToString().ToLowerInvariant(),
    };
}

public sealed record AlwaysOnRunLog(
    string RunId,
    string Content,
    bool Truncated,
    DateTimeOffset? UpdatedAt,
    int Size,
    AlwaysOnRunLogSource Source)
{
    public string Id => RunId;
}

public enum AlwaysOnSessionTargetKind
{
    Origin,
    Background,
}

public sealed record AlwaysOnSessionTarget(
    AlwaysOnSessionTargetKind Kind,
    string SessionId,
    string? ParentSessionId,
    string? RelativeTranscriptPath,
    string? Title,
    string? Summary,
    DateTimeOffset? LastActivity,
    string? TranscriptKey,
    string? TaskId,
    string? TaskStatus,
    string? OutputFile)
{
    public static AlwaysOnSessionTarget Origin(string sessionId) => new(
        AlwaysOnSessionTargetKind.Origin,
        sessionId,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null);

    public static AlwaysOnSessionTarget Background(
        string sessionId,
        string parentSessionId,
        string relativeTranscriptPath,
        string? title,
        string? summary,
        DateTimeOffset? lastActivity,
        string? transcriptKey,
        string? taskId,
        string? taskStatus,
        string? outputFile) => new(
        AlwaysOnSessionTargetKind.Background,
        sessionId,
        parentSessionId,
        relativeTranscriptPath,
        title,
        summary,
        lastActivity,
        transcriptKey,
        taskId,
        taskStatus,
        outputFile);
}

public sealed record AlwaysOnDiscoveryContext(
    string GeneratedAt,
    int LookbackDays,
    AlwaysOnDiscoveryWorkspace Workspace,
    IReadOnlyList<AlwaysOnDiscoveryMemoryItem> Memory,
    IReadOnlyList<AlwaysOnDiscoveryPlanItem> ExistingPlans,
    IReadOnlyList<AlwaysOnDiscoveryCronItem> CronJobs,
    IReadOnlyList<AlwaysOnDiscoveryChatItem> RecentChats);

public sealed record AlwaysOnDiscoveryWorkspace(
    string ProjectName,
    string ProjectRoot,
    IReadOnlyList<string> Signals);

public sealed record AlwaysOnDiscoveryMemoryItem(
    string Path,
    string ModifiedAt,
    string Summary);

public sealed record AlwaysOnDiscoveryPlanItem(
    string Id,
    string Title,
    string Status,
    string ApprovalMode,
    string UpdatedAt,
    string Summary);

public sealed record AlwaysOnDiscoveryCronItem(
    string Id,
    string Status,
    string Cron,
    bool Recurring,
    bool ManualOnly,
    string Prompt,
    string? LatestRunSummary);

public sealed record AlwaysOnDiscoveryChatItem(
    string Id,
    string Summary,
    string LastActivity,
    string? LastUserMessage,
    string? LastAssistantMessage);

public sealed class AlwaysOnDiscoveryRequestDedupeStore
{
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);
    private readonly List<string> _order = [];

    public IReadOnlySet<string> Seen => _seen;
    public IReadOnlyList<string> Order => _order;

    public bool ShouldProcess(string? requestId, int maxSize = 100)
    {
        var normalized = requestId?.Trim();
        if (string.IsNullOrWhiteSpace(normalized)) return false;
        if (!_seen.Add(normalized)) return false;

        _order.Add(normalized);
        var limit = Math.Max(1, maxSize);
        while (_order.Count > limit)
        {
            var oldest = _order[0];
            _order.RemoveAt(0);
            _seen.Remove(oldest);
        }

        return true;
    }
}
