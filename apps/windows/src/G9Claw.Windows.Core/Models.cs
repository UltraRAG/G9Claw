using System.Collections.ObjectModel;

namespace G9Claw.Windows.Core;

public enum SessionProvider
{
    G9Claw,
    Cursor,
    Codex,
    Gemini,
}

public static class SessionProviderExtensions
{
    public static string Id(this SessionProvider provider) => provider switch
    {
        SessionProvider.G9Claw => "g9claw",
        SessionProvider.Cursor => "cursor",
        SessionProvider.Codex => "codex",
        SessionProvider.Gemini => "gemini",
        _ => provider.ToString().ToLowerInvariant(),
    };

    public static string DisplayName(this SessionProvider provider) =>
        provider == SessionProvider.G9Claw ? "PilotDeck" : provider.ToString();

    public static bool IsNativeAvailable(this SessionProvider provider) =>
        provider == SessionProvider.G9Claw;
}

public enum ProjectSessionKind
{
    BackgroundTask,
}

public enum ChatRunMode
{
    Agent,
    Plan,
}

public sealed record ChatRunModeDescriptor(
    ChatRunMode Mode,
    string Id,
    string Label,
    string SystemImage,
    string Detail);

public static class ChatRunModeCatalog
{
    public static readonly IReadOnlyList<ChatRunModeDescriptor> All =
    [
        new(ChatRunMode.Agent, "agent", "\u667a\u80fd\u4f53", "sparkles", "Run the agent with tools and streaming output."),
        new(ChatRunMode.Plan, "plan", "\u8ba1\u5212", "checklist", "Ask the agent to produce a plan first."),
    ];

    public static string Id(this ChatRunMode mode) => Descriptor(mode).Id;
    public static string Label(this ChatRunMode mode) => Descriptor(mode).Label;
    public static string SystemImage(this ChatRunMode mode) => Descriptor(mode).SystemImage;
    public static string Detail(this ChatRunMode mode) => Descriptor(mode).Detail;

    private static ChatRunModeDescriptor Descriptor(ChatRunMode mode) =>
        All.FirstOrDefault(descriptor => descriptor.Mode == mode)
        ?? new ChatRunModeDescriptor(mode, mode.ToString().ToLowerInvariant(), mode.ToString(), "", "");
}

public enum ComposerPermissionMode
{
    Default,
    BypassPermissions,
}

public sealed record ComposerPermissionModeDescriptor(
    ComposerPermissionMode Mode,
    string Id,
    string Label,
    string SystemImage,
    string Detail);

public static class ComposerPermissionModeCatalog
{
    public const string DefaultStorageKey = "permissionMode-default";
    public const string SessionStorageKeyPrefix = "permissionMode-";

    public static readonly IReadOnlyList<ComposerPermissionModeDescriptor> All =
    [
        new(ComposerPermissionMode.Default, "default", "Default permissions", "hand.raised", "Ask before running tools that need approval."),
        new(ComposerPermissionMode.BypassPermissions, "bypassPermissions", "\u5b8c\u5168\u8bbf\u95ee\u6743\u9650", "shield.lefthalf.filled", "Allow trusted tool actions for this run."),
    ];

    public static string Id(this ComposerPermissionMode mode) => Descriptor(mode).Id;
    public static string Label(this ComposerPermissionMode mode) => Descriptor(mode).Label;
    public static string SystemImage(this ComposerPermissionMode mode) => Descriptor(mode).SystemImage;
    public static string Detail(this ComposerPermissionMode mode) => Descriptor(mode).Detail;

    public static ComposerPermissionMode FromId(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return ComposerPermissionMode.Default;
        var descriptor = All.FirstOrDefault(item => string.Equals(item.Id, id.Trim(), StringComparison.Ordinal));
        return descriptor?.Mode ?? ComposerPermissionMode.Default;
    }

    private static ComposerPermissionModeDescriptor Descriptor(ComposerPermissionMode mode) =>
        All.FirstOrDefault(descriptor => descriptor.Mode == mode)
        ?? All[0];
}

public sealed record NativeUIPreferences(
    bool AutoExpandTools = false,
    bool ShowRawParameters = false,
    bool ShowThinking = true,
    bool AutoScrollToBottom = true,
    bool SendByCtrlEnter = false,
    bool SidebarVisible = true);

public static class ToolRowExpansionPolicy
{
    public static bool IsExpanded(
        string id,
        ISet<string> expandedIds,
        ISet<string> collapsedIds,
        bool autoExpandTools)
    {
        if (collapsedIds.Contains(id)) return false;
        if (expandedIds.Contains(id)) return true;
        return autoExpandTools;
    }

    public static void Toggle(
        string id,
        ISet<string> expandedIds,
        ISet<string> collapsedIds,
        bool autoExpandTools)
    {
        if (IsExpanded(id, expandedIds, collapsedIds, autoExpandTools))
        {
            expandedIds.Remove(id);
            collapsedIds.Add(id);
        }
        else
        {
            collapsedIds.Remove(id);
            expandedIds.Add(id);
        }
    }
}

public enum AppTab
{
    Chat,
    AlwaysOn,
    Files,
    Shell,
    Git,
    Tasks,
    Memory,
    Skills,
    Dashboard,
    Preview,
}

public enum SessionState
{
    Idle,
    Processing,
    Unread,
    Failed,
}

public sealed record WorkspaceProject(
    Guid Id,
    string Name,
    string DisplayName,
    string RootPath,
    List<ProjectSession> Sessions,
    List<ProjectSession> CodexSessions,
    List<ProjectSession> CursorSessions,
    List<ProjectSession> GeminiSessions,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastActivity)
{
    public IEnumerable<ProjectSession> AllSessions =>
        Sessions.Concat(CodexSessions).Concat(CursorSessions).Concat(GeminiSessions)
            .OrderByDescending(session => session.ActivityDate);

    public DateTimeOffset LatestActivity =>
        AllSessions.Select(session => session.ActivityDate).DefaultIfEmpty(LastActivity ?? CreatedAt).Max();

    public static List<WorkspaceProject> Sample(string homePath)
    {
        var now = DateTimeOffset.UtcNow;
        return
        [
            new WorkspaceProject(
                Guid.NewGuid(),
                "general",
                "general",
                homePath,
                [],
                [],
                [],
                [],
                now.AddHours(-2),
                now.AddMinutes(-10))
        ];
    }
}

public sealed record ProjectSession(
    string Id,
    SessionProvider Provider,
    string Title,
    string Summary,
    DateTimeOffset CreatedAt,
    DateTimeOffset? UpdatedAt,
    DateTimeOffset? LastActivity,
    DateTimeOffset? LastConversationAt,
    SessionState State,
    int? MessageCount = null,
    ProjectSessionKind? SessionKind = null,
    string? ParentSessionId = null,
    string? RelativeTranscriptPath = null,
    string? TranscriptKey = null,
    string? TaskId = null,
    string? TaskStatus = null,
    string? OutputFile = null,
    bool? IsReadOnly = null)
{
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? Id : Title.Trim();

    public DateTimeOffset ActivityDate => LastConversationAt ?? LastActivity ?? UpdatedAt ?? CreatedAt;

    public bool IsBackgroundTaskSession =>
        SessionKind == ProjectSessionKind.BackgroundTask &&
        !string.IsNullOrWhiteSpace(ParentSessionId) &&
        !string.IsNullOrWhiteSpace(RelativeTranscriptPath);
}

public enum ChatRole
{
    User,
    Assistant,
    System,
    Tool,
}

public enum ChatBlockKind
{
    Text,
    Reasoning,
    ToolCall,
    ToolResult,
    Attachment,
    ProviderError,
}

public enum AttachmentSourceKind
{
    Picker,
    ClipboardFile,
    ClipboardImage,
}

public sealed record ChatBlock(
    ChatBlockKind Kind,
    string? Text = null,
    AgentToolCall? ToolCall = null,
    AgentToolResult? ToolResult = null,
    FileAttachment? Attachment = null,
    ProviderErrorInfo? ProviderError = null)
{
    public static ChatBlock FromText(string text) => new(ChatBlockKind.Text, Text: text);
    public static ChatBlock FromReasoning(string text) => new(ChatBlockKind.Reasoning, Text: text);
}

public static class ChatBlockVisibilityPolicy
{
    public static bool IsVisible(ChatBlock block, bool showThinking) =>
        block.Kind != ChatBlockKind.Reasoning || showThinking;
}

public sealed record ChatMessage(
    Guid Id,
    string SessionId,
    SessionProvider Provider,
    ChatRole Role,
    List<ChatBlock> Blocks,
    DateTimeOffset CreatedAt,
    bool IsStreaming,
    TokenBudget? TokenBudget)
{
    public string PlainText => string.Concat(Blocks.Where(block => block.Kind == ChatBlockKind.Text).Select(block => block.Text));
}

public sealed record TokenBudget(int Used, int Total);

public sealed record AgentToolCall(
    string Id,
    string Name,
    string InputJson);

public sealed record AgentToolResult(
    string CallId,
    string ToolName,
    string Output,
    bool IsError,
    string? ArtifactPath = null,
    string? TaskId = null,
    Dictionary<string, string>? Diagnostics = null,
    bool IsPolicyBlock = false,
    bool IsBenignVerification = false);

public sealed record ProviderErrorInfo(
    string Summary,
    string Body,
    string ProviderId,
    string ModelEntryId,
    string Model,
    string Endpoint,
    string RequestId,
    string RouteTier,
    string? FallbackFromModelEntry = null,
    string? FallbackToModelEntry = null,
    string? FallbackReason = null);

public sealed record FileAttachment(
    string Path,
    string FileName,
    string? MimeType,
    long Bytes,
    AttachmentSourceKind SourceKind = AttachmentSourceKind.Picker,
    string? PreviewPath = null)
{
    public string Extension => System.IO.Path.GetExtension(Path).TrimStart('.').ToLowerInvariant();

    public bool IsImage =>
        MimeType?.StartsWith("image/", StringComparison.OrdinalIgnoreCase) == true ||
        new[] { "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp" }.Contains(Extension);

    public bool IsPdf =>
        string.Equals(MimeType, "application/pdf", StringComparison.OrdinalIgnoreCase) ||
        Extension == "pdf";

    public bool IsTextLike =>
        MimeType?.StartsWith("text/", StringComparison.OrdinalIgnoreCase) == true ||
        new[]
        {
            "txt", "md", "markdown", "json", "jsonl", "yaml", "yml", "toml", "xml",
            "cs", "swift", "ts", "tsx", "js", "jsx", "py", "rs", "rb", "go", "java", "kt",
            "cpp", "c", "h", "hpp", "html", "css", "scss", "csv", "sql", "sh", "ps1", "log"
        }.Contains(Extension);
}

public enum ContextBudgetLevel
{
    Normal,
    Attention,
    Warning,
    Compacting,
    Recovering,
}

public sealed record ContextBudgetSnapshot(
    int? Used,
    int? Total,
    int? Percent,
    ContextBudgetLevel? Level,
    string Detail,
    string? CompactStage,
    int CompactCount);

public static class ContextBudgetPresenter
{
    public static ContextBudgetSnapshot FromBudget(TokenBudget? budget, string? compactStage = null, int compactCount = 0)
    {
        if (budget is null || budget.Total <= 0)
        {
            return new ContextBudgetSnapshot(
                null,
                null,
                null,
                null,
                "Context usage unknown. It will appear after the next model response.",
                compactStage,
                Math.Max(0, compactCount));
        }

        var percent = Math.Clamp((int)Math.Round((double)Math.Max(0, budget.Used) / budget.Total * 100), 0, 999);
        var lowerStage = compactStage?.ToLowerInvariant() ?? "";
        var level = lowerStage.Contains("recover")
            ? ContextBudgetLevel.Recovering
            : lowerStage.Contains("compact")
                ? ContextBudgetLevel.Compacting
                : percent >= 95
                    ? ContextBudgetLevel.Recovering
                    : percent >= 80
                        ? ContextBudgetLevel.Warning
                        : percent >= 60
                            ? ContextBudgetLevel.Attention
                            : ContextBudgetLevel.Normal;
        var detail = $"{LevelLabel(level)}: {Math.Max(0, budget.Used):N0} / {budget.Total:N0} tokens ({percent}%)";
        return new ContextBudgetSnapshot(
            Math.Max(0, budget.Used),
            budget.Total,
            percent,
            level,
            detail,
            string.IsNullOrWhiteSpace(compactStage) ? null : compactStage.Trim(),
            Math.Max(0, compactCount));
    }

    public static string LevelLabel(ContextBudgetLevel? level) => level switch
    {
        ContextBudgetLevel.Attention => "Context attention",
        ContextBudgetLevel.Warning => "Context warning",
        ContextBudgetLevel.Compacting => "Context compacting",
        ContextBudgetLevel.Recovering => "Context recovering",
        ContextBudgetLevel.Normal => "Context normal",
        _ => "Unknown",
    };
}

public enum PermissionScope
{
    Session,
    Project,
    Global,
}

public enum PermissionRequestKind
{
    Tool,
    AskUserQuestion,
    ExitPlanMode,
    DestructivePlanApproval,
}

public sealed record PermissionRequest(
    Guid Id,
    string SessionId,
    string ToolName,
    string InputJson,
    string Reason,
    PermissionScope Scope,
    DateTimeOffset CreatedAt,
    PermissionRequestKind Kind,
    AgentInteractivePayload? InteractivePayload);

public sealed record AgentQuestionOption(string Label, string? Description = null);

public sealed record AgentQuestion(
    string Header,
    string Question,
    List<AgentQuestionOption> Options,
    bool MultiSelect);

public sealed record AgentInteractivePayload(List<AgentQuestion> Questions);

public enum ProviderApiType
{
    OpenAIChat,
    OpenAIResponses,
    AnthropicMessages,
}

public sealed record ProviderConfig(
    SessionProvider Provider,
    ProviderApiType ApiType,
    string BaseUrl,
    string Model,
    string SecretAccount,
    Dictionary<string, string> Headers)
{
    public static ProviderConfig Empty => new(
        SessionProvider.G9Claw,
        ProviderApiType.OpenAIChat,
        "",
        "",
        "g9claw-default-provider",
        []);
}

public sealed record AppSettings(
    ProviderConfig ProviderConfig,
    string WorkspacesRoot,
    string GeneralWorkspacePath,
    int ApiTimeoutMs,
    int ContextWindow,
    ProjectSortOrder ProjectSortOrder,
    AppColorScheme ColorScheme,
    AppLanguage Language,
    ToolPermissionSettings Permissions,
    V2UiSettings UiSettings,
    NativeEditorSettings EditorSettings,
    NativeRouterSettings RouterSettings,
    NativeFeatureSettings FeatureSettings,
    List<NativeProviderEntry>? Providers = null,
    List<NativeModelEntry>? ModelEntries = null,
    NativeAgentSettings? AgentSettings = null,
    NativeRuntimeSettings? RuntimeSettings = null,
    NativeAlwaysOnSettings? AlwaysOnSettings = null,
    NativeMemorySettings? MemorySettings = null,
    NativeRagSettings? RagSettings = null,
    NativeGatewaySettings? GatewaySettings = null,
    NativeConfigRawDocument? RawConfigDocument = null)
{
    public static AppSettings Defaults(string homePath) => new(
        ProviderConfig.Empty,
        homePath,
        System.IO.Path.Combine(homePath, "G9Claw", "general"),
        90_000,
        160_000,
        ProjectSortOrder.Date,
        AppColorScheme.System,
        AppLanguage.Auto,
        ToolPermissionSettings.Defaults,
        V2UiSettings.Defaults,
        NativeEditorSettings.Defaults,
        NativeRouterSettings.Defaults,
        NativeFeatureSettings.Defaults,
        [NativeProviderEntry.FromProviderConfig(ProviderConfig.Empty)],
        [NativeModelEntry.FromProviderConfig(ProviderConfig.Empty)],
        NativeAgentSettings.Defaults,
        NativeRuntimeSettings.Defaults(homePath),
        NativeAlwaysOnSettings.Defaults,
        NativeMemorySettings.Defaults,
        NativeRagSettings.Defaults,
        NativeGatewaySettings.Defaults,
        NativeConfigRawDocument.Defaults);
}

public enum ProjectSortOrder
{
    Name,
    Date,
}

public enum AppColorScheme
{
    System,
    Light,
    Dark,
}

public enum AppLanguage
{
    Auto,
    English,
    ChineseSimplified,
}

public sealed record ToolPermissionSettings(
    List<string> AllowedTools,
    List<string> DisallowedTools,
    DateTimeOffset? LastUpdated)
{
    public static readonly List<string> QuickAllowedTools =
    [
        "Bash(git log:*)",
        "Bash(git diff:*)",
        "Bash(git status:*)",
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "MultiEdit",
        "Task",
        "TodoWrite",
    ];

    public static readonly List<string> QuickBlockedTools =
    [
        "Bash(rm:*)",
        "Bash(sudo:*)",
        "WebFetch",
        "WebSearch",
    ];

    public static ToolPermissionSettings Defaults => new([], [], null);
}

public static class PermissionSettingsMutation
{
    public static ToolPermissionSettings GrantAllowedToolFromChat(
        ToolPermissionSettings? settings,
        string toolName,
        DateTimeOffset? now = null)
    {
        settings ??= ToolPermissionSettings.Defaults;
        var canonical = CanonicalPermissionRule(toolName);
        if (string.IsNullOrWhiteSpace(canonical)) return settings;

        var allowed = settings.AllowedTools
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .ToList();
        var removedDisallowed = settings.DisallowedTools.Any(item => PermissionRuleEquals(item, canonical));
        var disallowed = settings.DisallowedTools
            .Where(item => !PermissionRuleEquals(item, canonical))
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .ToList();

        var alreadyAllowed = allowed.Any(item => PermissionRuleEquals(item, canonical));
        if (!alreadyAllowed)
        {
            allowed.Add(canonical);
        }

        return settings with
        {
            AllowedTools = allowed,
            DisallowedTools = disallowed,
            LastUpdated = removedDisallowed || !alreadyAllowed ? now ?? DateTimeOffset.UtcNow : settings.LastUpdated,
        };
    }

    public static string CanonicalPermissionRule(string? tool)
    {
        var trimmed = tool?.Trim() ?? "";
        if (trimmed.Length == 0) return "";
        var lower = trimmed.ToLowerInvariant();
        if (lower.StartsWith("bash(", StringComparison.Ordinal) && trimmed.EndsWith(')'))
        {
            return trimmed;
        }

        return AgentToolNameCanonicalizer.Canonical(trimmed);
    }

    public static bool PermissionRuleEquals(string left, string right) =>
        string.Equals(CanonicalPermissionRule(left), CanonicalPermissionRule(right), StringComparison.Ordinal);
}

public static class NativeSettingsIds
{
    public static string Normalize(string? value, string fallback)
    {
        var trimmed = value?.Trim() ?? "";
        if (trimmed.Length == 0) return fallback;
        var chars = trimmed
            .Select(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.' ? ch : '-')
            .ToArray();
        var normalized = new string(chars).Trim('-', '.', '_');
        return string.IsNullOrWhiteSpace(normalized) ? fallback : normalized;
    }
}

public sealed record NativeProviderEntry(
    string Id,
    ProviderApiType ApiType,
    string BaseUrl,
    string SecretAccount,
    Dictionary<string, string> Headers)
{
    public static NativeProviderEntry FromProviderConfig(ProviderConfig config) => new(
        "g9claw",
        config.ApiType,
        config.BaseUrl,
        string.IsNullOrWhiteSpace(config.SecretAccount) ? ProviderConfig.Empty.SecretAccount : config.SecretAccount,
        config.Headers is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(config.Headers, StringComparer.OrdinalIgnoreCase));

    public NativeProviderEntry Normalize(int index = 0)
    {
        var id = NativeSettingsIds.Normalize(Id, index == 0 ? "g9claw" : $"provider{index + 1}");
        return this with
        {
            Id = id,
            BaseUrl = BaseUrl?.Trim() ?? "",
            SecretAccount = string.IsNullOrWhiteSpace(SecretAccount) ? $"g9claw-provider-{id}" : SecretAccount.Trim(),
            Headers = Headers is null
                ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, string>(Headers, StringComparer.OrdinalIgnoreCase),
        };
    }
}

public sealed record NativeModelEntry(
    string Id,
    string ProviderId,
    string Name,
    int ContextWindow)
{
    public static NativeModelEntry FromProviderConfig(ProviderConfig config) => new(
        "default",
        "g9claw",
        config.Model,
        160_000);

    public NativeModelEntry Normalize(IReadOnlyList<NativeProviderEntry> providers, int fallbackContextWindow, int index = 0)
    {
        var id = NativeSettingsIds.Normalize(Id, index == 0 ? "default" : $"model{index + 1}");
        var providerId = string.IsNullOrWhiteSpace(ProviderId) ? providers.FirstOrDefault()?.Id ?? "g9claw" : ProviderId.Trim();
        if (!providers.Any(provider => string.Equals(provider.Id, providerId, StringComparison.OrdinalIgnoreCase)))
        {
            providerId = providers.FirstOrDefault()?.Id ?? "g9claw";
        }

        return this with
        {
            Id = id,
            ProviderId = providerId,
            Name = Name?.Trim() ?? "",
            ContextWindow = Math.Clamp(ContextWindow <= 0 ? fallbackContextWindow : ContextWindow, 1_000, 2_000_000),
        };
    }
}

public sealed record NativeAgentSettings(
    string MainModelEntryId,
    string SubagentDefaultModelEntryId,
    string ParamsJson)
{
    public static NativeAgentSettings Defaults => new("default", "default", "{}");

    public NativeAgentSettings Normalize(IReadOnlyList<NativeModelEntry> modelEntries)
    {
        var fallback = modelEntries.FirstOrDefault()?.Id ?? "default";
        var main = string.IsNullOrWhiteSpace(MainModelEntryId) ? fallback : MainModelEntryId.Trim();
        var subagent = string.IsNullOrWhiteSpace(SubagentDefaultModelEntryId) ? "inherit" : SubagentDefaultModelEntryId.Trim();
        if (!string.Equals(subagent, "inherit", StringComparison.OrdinalIgnoreCase) &&
            !modelEntries.Any(entry => string.Equals(entry.Id, subagent, StringComparison.OrdinalIgnoreCase)))
        {
            subagent = "inherit";
        }
        return this with
        {
            MainModelEntryId = main,
            SubagentDefaultModelEntryId = subagent,
            ParamsJson = string.IsNullOrWhiteSpace(ParamsJson) ? "{}" : ParamsJson.Trim(),
        };
    }
}

public sealed record NativeRuntimeSettings(
    string WorkspacesRoot,
    string GeneralWorkspacePath,
    int ApiTimeoutMs,
    int ContextWindow,
    string DatabasePath,
    string HttpsProxy = "")
{
    public static NativeRuntimeSettings Defaults(string homePath)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var dataRoot = string.IsNullOrWhiteSpace(localAppData)
            ? System.IO.Path.Combine(homePath, "AppData", "Local", AppPaths.ProductDirectoryName)
            : System.IO.Path.Combine(localAppData, AppPaths.ProductDirectoryName);
        return new NativeRuntimeSettings(
            homePath,
            System.IO.Path.Combine(homePath, "G9Claw", "general"),
            120_000,
            160_000,
            System.IO.Path.Combine(dataRoot, "g9claw.db"),
            "");
    }

    public NativeRuntimeSettings Normalize(string homePath) => this with
    {
        WorkspacesRoot = string.IsNullOrWhiteSpace(WorkspacesRoot)
            ? homePath
            : PathHelpers.NormalizeFullPath(PathHelpers.ExpandHome(WorkspacesRoot.Trim(), homePath)),
        GeneralWorkspacePath = AppState.NormalizeGeneralWorkspacePath(GeneralWorkspacePath, homePath),
        ApiTimeoutMs = Math.Max(5_000, ApiTimeoutMs),
        ContextWindow = Math.Max(1_000, ContextWindow),
        DatabasePath = string.IsNullOrWhiteSpace(DatabasePath)
            ? Defaults(homePath).DatabasePath
            : PathHelpers.NormalizeFullPath(PathHelpers.ExpandHome(DatabasePath.Trim(), homePath)),
        HttpsProxy = HttpsProxy?.Trim() ?? "",
    };
}

public sealed record NativeEditorSettings(
    bool WordWrap,
    bool ShowMinimap,
    bool LineNumbers,
    int FontSize)
{
    public static NativeEditorSettings Defaults => new(false, true, true, 14);

    public NativeEditorSettings Normalize() => this with
    {
        FontSize = Math.Clamp(FontSize <= 0 ? Defaults.FontSize : FontSize, 10, 24),
    };
}

public sealed record NativeFeatureSettings(
    bool MemoryEnabled,
    bool RagEnabled,
    bool GatewayEnabled)
{
    public static NativeFeatureSettings Defaults => new(true, false, true);
}

public sealed record NativeMemorySettings(
    bool Enabled,
    string ModelEntryId,
    string ParamsJson,
    string ReasoningMode,
    int AutoIndexIntervalMinutes,
    int AutoDreamIntervalMinutes,
    string CaptureStrategy,
    bool IncludeAssistant,
    int MaxMessageChars,
    int HeartbeatBatchSize)
{
    public static NativeMemorySettings Defaults => new(
        true,
        "memory",
        "{}",
        "answer_first",
        1,
        2,
        "last_turn",
        true,
        6000,
        30);

    public NativeMemorySettings Normalize(IReadOnlyList<NativeModelEntry> modelEntries)
    {
        var model = string.IsNullOrWhiteSpace(ModelEntryId) ? "memory" : ModelEntryId.Trim();
        if (!modelEntries.Any(entry => string.Equals(entry.Id, model, StringComparison.OrdinalIgnoreCase)))
        {
            model = modelEntries.Any(entry => string.Equals(entry.Id, "memory", StringComparison.OrdinalIgnoreCase))
                ? "memory"
                : modelEntries.FirstOrDefault()?.Id ?? "default";
        }

        return this with
        {
            ModelEntryId = model,
            ParamsJson = string.IsNullOrWhiteSpace(ParamsJson) ? "{}" : ParamsJson.Trim(),
            ReasoningMode = string.IsNullOrWhiteSpace(ReasoningMode) ? Defaults.ReasoningMode : ReasoningMode.Trim(),
            AutoIndexIntervalMinutes = Math.Clamp(AutoIndexIntervalMinutes <= 0 ? Defaults.AutoIndexIntervalMinutes : AutoIndexIntervalMinutes, 1, 1440),
            AutoDreamIntervalMinutes = Math.Clamp(AutoDreamIntervalMinutes <= 0 ? Defaults.AutoDreamIntervalMinutes : AutoDreamIntervalMinutes, 1, 1440),
            CaptureStrategy = string.IsNullOrWhiteSpace(CaptureStrategy) ? Defaults.CaptureStrategy : CaptureStrategy.Trim(),
            MaxMessageChars = Math.Clamp(MaxMessageChars <= 0 ? Defaults.MaxMessageChars : MaxMessageChars, 100, 200_000),
            HeartbeatBatchSize = Math.Clamp(HeartbeatBatchSize <= 0 ? Defaults.HeartbeatBatchSize : HeartbeatBatchSize, 1, 1000),
        };
    }
}

public sealed record NativeAlwaysOnSettings(
    bool Enabled,
    int TickIntervalMinutes,
    int CooldownMinutes,
    int DailyBudget,
    int HeartbeatStaleSeconds,
    int RecentUserMessageMinutes,
    string PreferClient,
    Dictionary<string, bool> ProjectEnabled)
{
    public static NativeAlwaysOnSettings Defaults => new(
        false,
        15,
        60,
        12,
        300,
        30,
        "webui",
        new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase));

    public NativeAlwaysOnSettings Normalize() => this with
    {
        TickIntervalMinutes = Math.Clamp(TickIntervalMinutes <= 0 ? Defaults.TickIntervalMinutes : TickIntervalMinutes, 1, 1440),
        CooldownMinutes = Math.Clamp(CooldownMinutes <= 0 ? Defaults.CooldownMinutes : CooldownMinutes, 1, 1440),
        DailyBudget = Math.Clamp(DailyBudget <= 0 ? Defaults.DailyBudget : DailyBudget, 1, 500),
        HeartbeatStaleSeconds = Math.Clamp(HeartbeatStaleSeconds <= 0 ? Defaults.HeartbeatStaleSeconds : HeartbeatStaleSeconds, 30, 86_400),
        RecentUserMessageMinutes = Math.Clamp(RecentUserMessageMinutes <= 0 ? Defaults.RecentUserMessageMinutes : RecentUserMessageMinutes, 1, 1440),
        PreferClient = string.Equals(PreferClient, "tui", StringComparison.OrdinalIgnoreCase) ? "tui" : "webui",
        ProjectEnabled = ProjectEnabled is null
            ? new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, bool>(ProjectEnabled, StringComparer.OrdinalIgnoreCase),
    };
}

public sealed record NativeRagSettings(
    bool Enabled,
    bool DisableBuiltInWebTools,
    string LocalKnowledgeBaseUrl,
    string LocalKnowledgeSecretAccount,
    string LocalKnowledgeModelName,
    string LocalKnowledgeDatabaseUrl,
    int LocalKnowledgeDefaultTopK,
    string GlmWebSearchBaseUrl,
    string GlmWebSearchSecretAccount,
    int GlmWebSearchDefaultTopK)
{
    public static NativeRagSettings Defaults => new(
        false,
        false,
        "",
        "g9claw-rag-local-knowledge",
        "",
        "",
        5,
        "",
        "g9claw-rag-glm-web-search",
        5);

    public NativeRagSettings Normalize() => this with
    {
        LocalKnowledgeBaseUrl = LocalKnowledgeBaseUrl?.Trim() ?? "",
        LocalKnowledgeSecretAccount = string.IsNullOrWhiteSpace(LocalKnowledgeSecretAccount) ? Defaults.LocalKnowledgeSecretAccount : LocalKnowledgeSecretAccount.Trim(),
        LocalKnowledgeModelName = LocalKnowledgeModelName?.Trim() ?? "",
        LocalKnowledgeDatabaseUrl = LocalKnowledgeDatabaseUrl?.Trim() ?? "",
        LocalKnowledgeDefaultTopK = Math.Clamp(LocalKnowledgeDefaultTopK <= 0 ? Defaults.LocalKnowledgeDefaultTopK : LocalKnowledgeDefaultTopK, 1, 100),
        GlmWebSearchBaseUrl = GlmWebSearchBaseUrl?.Trim() ?? "",
        GlmWebSearchSecretAccount = string.IsNullOrWhiteSpace(GlmWebSearchSecretAccount) ? Defaults.GlmWebSearchSecretAccount : GlmWebSearchSecretAccount.Trim(),
        GlmWebSearchDefaultTopK = Math.Clamp(GlmWebSearchDefaultTopK <= 0 ? Defaults.GlmWebSearchDefaultTopK : GlmWebSearchDefaultTopK, 1, 100),
    };
}

public sealed record NativeGatewaySettings(
    bool Enabled,
    string Home,
    string Host,
    int ServerPort,
    int VitePort,
    int ProxyPort)
{
    public static NativeGatewaySettings Defaults => new(true, "", "0.0.0.0", 3001, 5173, 18080);

    public NativeGatewaySettings Normalize(string homePath) => this with
    {
        Home = string.IsNullOrWhiteSpace(Home)
            ? System.IO.Path.Combine(homePath, ".g9claw")
            : PathHelpers.NormalizeFullPath(PathHelpers.ExpandHome(Home.Trim(), homePath)),
        Host = string.IsNullOrWhiteSpace(Host) ? Defaults.Host : Host.Trim(),
        ServerPort = Math.Clamp(ServerPort <= 0 ? Defaults.ServerPort : ServerPort, 1, 65_535),
        VitePort = Math.Clamp(VitePort <= 0 ? Defaults.VitePort : VitePort, 1, 65_535),
        ProxyPort = Math.Clamp(ProxyPort <= 0 ? Defaults.ProxyPort : ProxyPort, 1, 65_535),
    };
}

public sealed record NativeConfigRawDocument(
    string LastYaml,
    DateTimeOffset? LastSavedAt)
{
    public static NativeConfigRawDocument Defaults => new("", null);
}

public sealed record NativeRouterSettings(
    bool Enabled,
    string DefaultRoute,
    Dictionary<string, string> TierModelEntries,
    decimal InputPricePerMillion,
    decimal OutputPricePerMillion,
    decimal BaselineInputPricePerMillion,
    decimal BaselineOutputPricePerMillion,
    bool Log = false,
    string Host = "127.0.0.1",
    int Port = 19080)
{
    public static NativeRouterSettings Defaults => new(
        false,
        "default",
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
        0,
        0,
        0,
        0,
        false,
        "127.0.0.1",
        19080);

    public NativeRouterSettings Normalize() => this with
    {
        DefaultRoute = string.IsNullOrWhiteSpace(DefaultRoute) ? "default" : DefaultRoute.Trim(),
        TierModelEntries = TierModelEntries is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(TierModelEntries, StringComparer.OrdinalIgnoreCase),
        InputPricePerMillion = Math.Max(0, InputPricePerMillion),
        OutputPricePerMillion = Math.Max(0, OutputPricePerMillion),
        BaselineInputPricePerMillion = Math.Max(0, BaselineInputPricePerMillion),
        BaselineOutputPricePerMillion = Math.Max(0, BaselineOutputPricePerMillion),
        Host = string.IsNullOrWhiteSpace(Host) ? Defaults.Host : Host.Trim(),
        Port = Math.Clamp(Port <= 0 ? Defaults.Port : Port, 1, 65_535),
    };
}

public sealed record WorkspaceFile(
    string Id,
    string Name,
    string Path,
    string RelativePath,
    int Depth,
    bool IsDirectory,
    bool IsExpanded,
    DateTimeOffset? ModifiedAt,
    long? ByteCount)
{
    public string FileExtension => System.IO.Path.GetExtension(Path).TrimStart('.').ToLowerInvariant();
    public bool IsMarkdown => FileExtension is "md" or "markdown";
    public bool IsHtml => FileExtension is "html" or "htm";
    public bool IsPdf => FileExtension == "pdf";
    public bool IsImage => new[] { "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp" }.Contains(FileExtension);
}

public sealed record TaskPlan(Guid Id, string Title, string Prompt, TaskStatus Status, DateTimeOffset CreatedAt);

public enum TaskStatus
{
    Queued,
    Running,
    Completed,
    Failed,
}

public sealed record MemoryRecord(
    Guid Id,
    string Name,
    string Summary,
    string? ProjectName,
    DateTimeOffset UpdatedAt,
    MemoryRecordType Type,
    string RelativePath,
    bool Deprecated,
    string Content);

public enum MemoryRecordType
{
    Project,
    Feedback,
    User,
    GeneralProjectMeta,
}

public sealed record SkillRecord(
    Guid Id,
    string Slug,
    string Name,
    string Description,
    string? Version,
    string SkillDir,
    string SkillFile,
    SkillScope Scope,
    DateTimeOffset? ModifiedAt,
    bool Enabled);

public enum SkillScope
{
    User,
    Project,
    Plugin,
}

public sealed record RoutingBucket(
    int Count,
    int InputTokens,
    int OutputTokens,
    int CacheReadTokens,
    int TotalTokens,
    int RequestCount,
    decimal EstimatedCost,
    decimal BaselineCost,
    decimal SavedCost);

public sealed record AlwaysOnPlan(
    string Id,
    string Title,
    string Summary,
    string Content,
    AlwaysOnStatus Status,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    string Rationale = "",
    string ApprovalMode = "",
    string PlanFilePath = "",
    Dictionary<string, List<string>>? ContextRefs = null,
    string? ExecutionSessionId = null,
    AlwaysOnStatus? ExecutionStatus = null);

public enum AlwaysOnStatus
{
    Scheduled,
    Ready,
    Queued,
    Running,
    Completed,
    Failed,
    Draft,
    Superseded,
    Unknown,
}

public sealed class ObservableList<T> : ObservableCollection<T>
{
    public ObservableList()
    {
    }

    public ObservableList(IEnumerable<T> items) : base(items)
    {
    }
}
