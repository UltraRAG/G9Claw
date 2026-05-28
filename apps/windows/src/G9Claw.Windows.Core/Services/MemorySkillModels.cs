namespace G9Claw.Windows.Core;

public sealed record MemoryDashboardSnapshot(
    int TotalEntries,
    int ProjectEntries,
    int FeedbackEntries,
    DateTimeOffset? LatestMemoryAt,
    IReadOnlyList<MemoryRecord> Records,
    string UserSummary,
    IReadOnlyList<string> CaseTraces,
    IReadOnlyList<string> IndexTraces,
    IReadOnlyList<string> DreamTraces,
    MemoryOverview? Overview = null,
    MemorySettingsSnapshot? Settings = null,
    MemoryWorkspaceSnapshot? Workspace = null,
    IReadOnlyList<MemoryTraceRecord>? CaseTraceRecords = null,
    IReadOnlyList<MemoryTraceRecord>? IndexTraceRecords = null,
    IReadOnlyList<MemoryTraceRecord>? DreamTraceRecords = null,
    MemoryDreamSnapshot? LastDreamSnapshot = null,
    MemorySchedulerSnapshot? Scheduler = null,
    Dictionary<MemoryJobKind, MemoryJobState>? JobStates = null)
{
    public MemoryOverview EffectiveOverview => Overview ?? MemoryOverview.Empty;
    public MemorySettingsSnapshot EffectiveSettings => Settings ?? MemorySettingsSnapshot.Defaults;
    public MemoryWorkspaceSnapshot EffectiveWorkspace => Workspace ?? MemoryWorkspaceSnapshot.Empty;
    public MemorySchedulerSnapshot EffectiveScheduler => Scheduler ?? MemorySchedulerSnapshot.Disabled;
    public Dictionary<MemoryJobKind, MemoryJobState> EffectiveJobStates =>
        JobStates ?? MemoryJobState.IdleStates();
}

public sealed record MemoryOverview(
    int TotalEntries,
    int ProjectEntries,
    int FeedbackEntries,
    int UserEntries,
    DateTimeOffset? LatestMemoryAt,
    DateTimeOffset? LastIndexedAt,
    DateTimeOffset? LastDreamAt,
    bool SchedulerEnabled)
{
    public static MemoryOverview Empty => new(0, 0, 0, 0, null, null, null, false);
}

public sealed record MemorySettingsSnapshot(
    bool Enabled = true,
    string Model = "inherit",
    string ReasoningMode = "answer_first",
    int AutoIndexIntervalMinutes = 30,
    int AutoDreamIntervalMinutes = 60,
    string CaptureStrategy = "last_turn",
    bool IncludeAssistant = true,
    int MaxMessageChars = 6000,
    int HeartbeatBatchSize = 30)
{
    public static MemorySettingsSnapshot Defaults => new();

    public MemorySettingsSnapshot Normalize() => this with
    {
        ReasoningMode = ReasoningMode == "accuracy_first" ? "accuracy_first" : "answer_first",
        AutoIndexIntervalMinutes = NormalizedInterval(AutoIndexIntervalMinutes, 30),
        AutoDreamIntervalMinutes = NormalizedInterval(AutoDreamIntervalMinutes, 60),
        CaptureStrategy = CaptureStrategy == "full_session" ? "full_session" : "last_turn",
        MaxMessageChars = Math.Max(1, MaxMessageChars),
        HeartbeatBatchSize = Math.Max(1, HeartbeatBatchSize),
    };

    public static MemorySettingsSnapshot FromConfigValues(IReadOnlyDictionary<string, string> values) => new MemorySettingsSnapshot(
        Enabled: Bool(values.GetValueOrDefault("memory.enabled"), true),
        Model: BlankToDefault(values.GetValueOrDefault("memory.model"), "inherit"),
        ReasoningMode: BlankToDefault(values.GetValueOrDefault("memory.reasoningMode"), "answer_first"),
        AutoIndexIntervalMinutes: Int(values.GetValueOrDefault("memory.autoIndexIntervalMinutes"), 30),
        AutoDreamIntervalMinutes: Int(values.GetValueOrDefault("memory.autoDreamIntervalMinutes"), 60),
        CaptureStrategy: BlankToDefault(values.GetValueOrDefault("memory.captureStrategy"), "last_turn"),
        IncludeAssistant: Bool(values.GetValueOrDefault("memory.includeAssistant"), true),
        MaxMessageChars: Int(values.GetValueOrDefault("memory.maxMessageChars"), 6000),
        HeartbeatBatchSize: Int(values.GetValueOrDefault("memory.heartbeatBatchSize"), 30)).Normalize();

    private static int NormalizedInterval(int value, int fallback)
    {
        var resolved = value < 0 ? fallback : value;
        return Math.Clamp(resolved, 0, 10_080);
    }

    private static int Int(string? value, int fallback) =>
        int.TryParse(value, out var parsed) ? parsed : fallback;

    private static bool Bool(string? value, bool fallback) => value?.Trim().ToLowerInvariant() switch
    {
        "true" or "1" or "yes" or "on" => true,
        "false" or "0" or "no" or "off" => false,
        _ => fallback,
    };

    private static string BlankToDefault(string? value, string fallback) =>
        string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
}

public sealed record MemoryWorkspaceSnapshot(
    string WorkspaceMode,
    string? ProjectPath,
    string? SelectedProjectId,
    MemoryProjectMeta? SelectedProject,
    IReadOnlyList<MemoryProjectMeta> GeneralProjects,
    MemoryProjectMeta? ProjectMeta,
    string ManifestPath,
    string ManifestContent,
    int TotalFiles,
    int TotalProjects,
    int TotalFeedback,
    IReadOnlyList<MemoryRecord> ProjectEntries,
    IReadOnlyList<MemoryRecord> FeedbackEntries,
    IReadOnlyList<MemoryRecord> DeprecatedProjectEntries,
    IReadOnlyList<MemoryRecord> DeprecatedFeedbackEntries)
{
    public static MemoryWorkspaceSnapshot Empty => new(
        "project",
        null,
        null,
        null,
        [],
        null,
        "MEMORY.md",
        "",
        0,
        0,
        0,
        [],
        [],
        [],
        []);
}

public sealed record MemoryProjectMeta(
    string ProjectId,
    string ProjectName,
    string Description,
    string Status,
    string? WorkspacePath,
    string? RelativePath,
    string SourceType,
    bool ReadOnly,
    DateTimeOffset? UpdatedAt)
{
    public string Id => ProjectId;
}

public sealed record MemoryTraceRecord(
    string Id,
    string Title,
    string Status,
    string Trigger,
    DateTimeOffset CreatedAt,
    Dictionary<string, string> Meta,
    string Context,
    string ToolEvents,
    string Reply,
    IReadOnlyList<MemoryTraceStep> Steps);

public sealed record MemoryTraceStep(
    string Id,
    string Title,
    string Detail,
    string Status,
    DateTimeOffset CreatedAt);

public enum MemoryJobKind
{
    Recall,
    Index,
    Dream,
    Rollback,
}

public enum MemoryJobPhase
{
    Idle,
    Running,
    Completed,
    Failed,
}

public sealed record MemoryJobState(
    MemoryJobKind Kind,
    MemoryJobPhase Phase,
    string Message,
    string? TraceId,
    DateTimeOffset? StartedAt,
    DateTimeOffset? EndedAt)
{
    public MemoryJobKind Id => Kind;

    public static MemoryJobState Idle(MemoryJobKind kind) => new(kind, MemoryJobPhase.Idle, "", null, null, null);

    public static Dictionary<MemoryJobKind, MemoryJobState> IdleStates() =>
        Enum.GetValues<MemoryJobKind>().ToDictionary(kind => kind, Idle);
}

public sealed record MemoryDreamSnapshot(
    DateTimeOffset CapturedAt,
    bool RollbackReady,
    string Summary);

public sealed record MemorySchedulerSnapshot(
    bool Enabled,
    string Status)
{
    public static MemorySchedulerSnapshot Disabled => new(false, "disabled");
}

public sealed record SkillValidationIssue(string Code, string Message)
{
    public Guid Id { get; init; } = Guid.NewGuid();
}

public sealed record SkillValidationResult(
    bool Ok,
    IReadOnlyList<SkillValidationIssue> HardFails,
    IReadOnlyList<SkillValidationIssue> Warnings,
    int FileCount,
    int TotalBytes);

public sealed record SkillHubSearchResult(
    string Slug,
    string Name,
    double? Score)
{
    public string Id => Slug;
}

public sealed record SkillHubInstallResult(
    bool Ok,
    string Slug,
    SkillScope Scope,
    string InstallPath,
    bool Installed,
    SkillRecord? Skill,
    string Stdout,
    string Stderr,
    int ExitCode,
    bool NeedsForce);
