using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace G9Claw.Windows.Core;

public sealed class AppState : INotifyPropertyChanged
{
    private Guid? _selectedProjectId;
    private string? _selectedSessionId;
    private AppTab _activeTab = AppTab.Chat;
    private string _composerText = "";
    private string _statusLine = "Ready";
    private string? _errorBanner;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableList<WorkspaceProject> Projects { get; } = [];
    public Dictionary<string, List<ChatMessage>> MessagesBySession { get; } = [];
    public Dictionary<string, List<AgentTurn>> TurnsBySession { get; } = [];
    public Dictionary<string, TokenBudget> TokenBudgetBySession { get; } = [];
    public List<PermissionRequest> PendingPermissions { get; } = [];
    public List<TerminalRun> TerminalRuns { get; } = [];
    public List<TaskPlan> TaskPlans { get; } = [];
    public List<MemoryRecord> MemoryRecords { get; } = [];
    public List<SkillRecord> Skills { get; } = [];
    public List<AlwaysOnPlan> AlwaysOnPlans { get; } = [];
    public List<RoutingUsageRecord> RoutingUsage { get; } = [];
    public List<FileAttachment> PendingAttachments { get; } = [];

    public AppSettings Settings { get; set; }

    public Guid? SelectedProjectId
    {
        get => _selectedProjectId;
        set => SetField(ref _selectedProjectId, value);
    }

    public string? SelectedSessionId
    {
        get => _selectedSessionId;
        set => SetField(ref _selectedSessionId, value);
    }

    public AppTab ActiveTab
    {
        get => _activeTab;
        set => SetField(ref _activeTab, value);
    }

    public string ComposerText
    {
        get => _composerText;
        set => SetField(ref _composerText, value);
    }

    public ChatRunMode ComposerRunMode { get; set; } = ChatRunMode.Agent;
    public ComposerPermissionMode ComposerPermissionMode { get; set; } = ComposerPermissionMode.Default;

    public string StatusLine
    {
        get => _statusLine;
        set => SetField(ref _statusLine, value);
    }

    public string? ErrorBanner
    {
        get => _errorBanner;
        set => SetField(ref _errorBanner, value);
    }

    public WorkspaceProject? SelectedProject =>
        SelectedProjectId is { } id ? Projects.FirstOrDefault(project => project.Id == id) : null;

    public ProjectSession? SelectedSession =>
        SelectedProject is { } project && SelectedSessionId is { } sessionId
            ? project.AllSessions.FirstOrDefault(session => session.Id == sessionId)
            : null;

    public IReadOnlyList<ChatMessage> CurrentMessages =>
        SelectedSessionId is { } sessionId && MessagesBySession.TryGetValue(sessionId, out var messages)
            ? messages
            : [];

    public static AppState CreateDefault()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var state = new AppState(AppSettings.Defaults(home));
        foreach (var project in WorkspaceProject.Sample(home))
        {
            state.Projects.Add(project);
        }

        state.SelectedProjectId = state.Projects.FirstOrDefault()?.Id;
        state.StatusLine = "Native Windows G9Claw initialized.";
        return state;
    }

    public AppState(AppSettings settings)
    {
        Settings = NormalizeSettings(settings);
    }

    public static string DefaultGeneralWorkspacePath(string? homePath = null)
    {
        var home = string.IsNullOrWhiteSpace(homePath)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : homePath;
        return Path.GetFullPath(Path.Combine(home, "G9Claw", "general"));
    }

    public static string NormalizeGeneralWorkspacePath(string rawPath, string? homePath = null)
    {
        var fallback = DefaultGeneralWorkspacePath(homePath);
        if (string.IsNullOrWhiteSpace(rawPath)) return fallback;
        var expanded = PathHelpers.ExpandHome(rawPath.Trim(), homePath);
        return Path.IsPathFullyQualified(expanded) ? Path.GetFullPath(expanded) : fallback;
    }

    public static AppSettings NormalizeSettings(AppSettings settings)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var runtime = (settings.RuntimeSettings ?? new NativeRuntimeSettings(
            settings.WorkspacesRoot,
            settings.GeneralWorkspacePath,
            settings.ApiTimeoutMs,
            settings.ContextWindow,
            NativeRuntimeSettings.Defaults(home).DatabasePath)).Normalize(home);
        var providerConfig = NormalizeProviderConfig(settings.ProviderConfig);
        var providers = NormalizeProviders(settings.Providers, providerConfig);
        var modelEntries = NormalizeModelEntries(settings.ModelEntries, providers, providerConfig, runtime.ContextWindow);
        var agentSettings = (settings.AgentSettings ?? NativeAgentSettings.Defaults).Normalize(modelEntries);
        var memorySettings = (settings.MemorySettings ?? NativeMemorySettings.Defaults).Normalize(modelEntries);
        var gatewaySettings = (settings.GatewaySettings ?? NativeGatewaySettings.Defaults).Normalize(home);
        providerConfig = ProviderConfigFromNative(providerConfig, providers, modelEntries, agentSettings);
        return settings with
        {
            WorkspacesRoot = runtime.WorkspacesRoot,
            GeneralWorkspacePath = runtime.GeneralWorkspacePath,
            ApiTimeoutMs = runtime.ApiTimeoutMs,
            ContextWindow = runtime.ContextWindow,
            UiSettings = (settings.UiSettings ?? V2UiSettings.Defaults).Normalize(),
            EditorSettings = (settings.EditorSettings ?? NativeEditorSettings.Defaults).Normalize(),
            RouterSettings = (settings.RouterSettings ?? NativeRouterSettings.Defaults).Normalize(),
            FeatureSettings = settings.FeatureSettings ?? NativeFeatureSettings.Defaults,
            Permissions = NormalizePermissions(settings.Permissions),
            ProviderConfig = providerConfig,
            Providers = providers,
            ModelEntries = modelEntries,
            AgentSettings = agentSettings,
            RuntimeSettings = runtime,
            AlwaysOnSettings = (settings.AlwaysOnSettings ?? NativeAlwaysOnSettings.Defaults).Normalize(),
            MemorySettings = memorySettings,
            RagSettings = (settings.RagSettings ?? NativeRagSettings.Defaults).Normalize(),
            GatewaySettings = gatewaySettings,
            RawConfigDocument = settings.RawConfigDocument ?? NativeConfigRawDocument.Defaults,
        };
    }

    private static ProviderConfig NormalizeProviderConfig(ProviderConfig? config)
    {
        config ??= ProviderConfig.Empty;
        return config with
        {
            BaseUrl = config.BaseUrl ?? "",
            Model = config.Model ?? "",
            SecretAccount = string.IsNullOrWhiteSpace(config.SecretAccount) ? ProviderConfig.Empty.SecretAccount : config.SecretAccount,
            Headers = config.Headers is null
                ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, string>(config.Headers, StringComparer.OrdinalIgnoreCase),
        };
    }

    private static ToolPermissionSettings NormalizePermissions(ToolPermissionSettings? permissions)
    {
        permissions ??= ToolPermissionSettings.Defaults;
        return permissions with
        {
            AllowedTools = permissions.AllowedTools?.Where(item => !string.IsNullOrWhiteSpace(item)).Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? [],
            DisallowedTools = permissions.DisallowedTools?.Where(item => !string.IsNullOrWhiteSpace(item)).Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? [],
        };
    }

    private static List<NativeProviderEntry> NormalizeProviders(List<NativeProviderEntry>? providers, ProviderConfig providerConfig)
    {
        var raw = providers is { Count: > 0 } ? providers : [NativeProviderEntry.FromProviderConfig(providerConfig)];
        return raw
            .Select((provider, index) => provider.Normalize(index))
            .GroupBy(provider => provider.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
    }

    private static List<NativeModelEntry> NormalizeModelEntries(
        List<NativeModelEntry>? modelEntries,
        IReadOnlyList<NativeProviderEntry> providers,
        ProviderConfig providerConfig,
        int contextWindow)
    {
        var raw = modelEntries is { Count: > 0 } ? modelEntries : [NativeModelEntry.FromProviderConfig(providerConfig)];
        return raw
            .Select((entry, index) => entry.Normalize(providers, contextWindow, index))
            .GroupBy(entry => entry.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
    }

    private static ProviderConfig ProviderConfigFromNative(
        ProviderConfig current,
        IReadOnlyList<NativeProviderEntry> providers,
        IReadOnlyList<NativeModelEntry> modelEntries,
        NativeAgentSettings agentSettings)
    {
        var model = modelEntries.FirstOrDefault(entry => string.Equals(entry.Id, agentSettings.MainModelEntryId, StringComparison.OrdinalIgnoreCase))
                    ?? modelEntries.FirstOrDefault();
        var provider = model is null
            ? providers.FirstOrDefault()
            : providers.FirstOrDefault(item => string.Equals(item.Id, model.ProviderId, StringComparison.OrdinalIgnoreCase));
        if (provider is null || model is null) return current;

        return current with
        {
            ApiType = provider.ApiType,
            BaseUrl = provider.BaseUrl,
            Model = model.Name,
            SecretAccount = provider.SecretAccount,
            Headers = provider.Headers,
        };
    }

    public void SelectProject(WorkspaceProject project)
    {
        SelectedProjectId = project.Id;
        SelectedSessionId = null;
        ActiveTab = AppTab.Chat;
    }

    public void SelectSession(ProjectSession session)
    {
        SelectedSessionId = session.Id;
        ActiveTab = AppTab.Chat;
    }

    public void MarkSessionState(string sessionId, SessionState state)
    {
        foreach (var project in Projects)
        {
            if (ReplaceSessionState(project.Sessions, sessionId, state) ||
                ReplaceSessionState(project.CodexSessions, sessionId, state) ||
                ReplaceSessionState(project.CursorSessions, sessionId, state) ||
                ReplaceSessionState(project.GeminiSessions, sessionId, state))
            {
                return;
            }
        }
    }

    public ProjectSession? CreateSessionForSelectedProject(string title = "New Session")
    {
        var project = SelectedProject;
        if (project is null) return null;

        var session = new ProjectSession(
            Guid.NewGuid().ToString("D"),
            SessionProvider.G9Claw,
            string.IsNullOrWhiteSpace(title) ? "New Session" : title.Trim(),
            "",
            DateTimeOffset.UtcNow,
            null,
            null,
            null,
            SessionState.Idle);

        project.Sessions.Insert(0, session);
        SelectedSessionId = session.Id;
        MessagesBySession[session.Id] = [];
        return session;
    }

    public void AppendMessage(ChatMessage message)
    {
        if (!MessagesBySession.TryGetValue(message.SessionId, out var messages))
        {
            messages = [];
            MessagesBySession[message.SessionId] = messages;
        }

        messages.Add(message);
    }

    public void ReplaceLastStreamingAssistantMessage(string sessionId, string text, TokenBudget? budget)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out var messages))
        {
            messages = [];
            MessagesBySession[sessionId] = messages;
        }

        var index = messages.FindLastIndex(message => message.Role == ChatRole.Assistant && message.IsStreaming);
        var message = new ChatMessage(
            index >= 0 ? messages[index].Id : Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Assistant,
            [ChatBlock.FromText(text)],
            index >= 0 ? messages[index].CreatedAt : DateTimeOffset.UtcNow,
            true,
            budget);

        if (index >= 0)
        {
            messages[index] = message;
        }
        else
        {
            messages.Add(message);
        }
    }

    public Guid EnsureStreamingAssistantMessage(string sessionId, TokenBudget? budget = null)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out var messages))
        {
            messages = [];
            MessagesBySession[sessionId] = messages;
        }

        var existing = messages.LastOrDefault(message => message.Role == ChatRole.Assistant && message.IsStreaming);
        if (existing is not null)
        {
            return existing.Id;
        }

        var message = new ChatMessage(
            Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Assistant,
            [ChatBlock.FromText("")],
            DateTimeOffset.UtcNow,
            true,
            budget);
        messages.Add(message);
        return message.Id;
    }

    public Guid BeginStreamingAssistantMessage(string sessionId, TokenBudget? budget = null, bool forceNew = true)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out var messages))
        {
            messages = [];
            MessagesBySession[sessionId] = messages;
        }

        if (!forceNew)
        {
            var existing = messages.LastOrDefault(message => message.Role == ChatRole.Assistant && message.IsStreaming);
            if (existing is not null)
            {
                return existing.Id;
            }
        }

        for (var i = 0; i < messages.Count; i++)
        {
            if (messages[i].Role == ChatRole.Assistant && messages[i].IsStreaming)
            {
                messages[i] = messages[i] with { IsStreaming = false };
            }
        }

        var message = new ChatMessage(
            Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Assistant,
            [ChatBlock.FromText("")],
            DateTimeOffset.UtcNow,
            true,
            budget);
        messages.Add(message);
        return message.Id;
    }

    public void AppendStreamingAssistantText(string sessionId, string text, TokenBudget? budget)
    {
        if (string.IsNullOrEmpty(text))
        {
            EnsureStreamingAssistantMessage(sessionId, budget);
            return;
        }

        var (messages, index) = StreamingAssistantSlot(sessionId, budget);
        AppendStreamingAssistantText(messages, index, text, budget);
    }

    public void AppendStreamingAssistantText(string sessionId, Guid assistantMessageId, string text, TokenBudget? budget)
    {
        if (!TryStreamingAssistantSlot(sessionId, assistantMessageId, out var messages, out var index))
        {
            return;
        }

        if (string.IsNullOrEmpty(text))
        {
            messages[index] = messages[index] with { TokenBudget = budget };
            return;
        }

        AppendStreamingAssistantText(messages, index, text, budget);
    }

    private static void AppendStreamingAssistantText(List<ChatMessage> messages, int index, string text, TokenBudget? budget)
    {
        var message = messages[index];
        var blocks = message.Blocks.ToList();
        var lastIndex = blocks.Count - 1;
        if (lastIndex >= 0 && blocks[lastIndex].Kind == ChatBlockKind.Text)
        {
            blocks[lastIndex] = blocks[lastIndex] with { Text = (blocks[lastIndex].Text ?? "") + text };
        }
        else
        {
            blocks.Add(ChatBlock.FromText(text));
        }

        messages[index] = message with { Blocks = blocks, TokenBudget = budget };
    }

    public void AppendStreamingAssistantToolCall(string sessionId, AgentToolCall call)
    {
        var (messages, index) = StreamingAssistantSlot(sessionId, null);
        AppendStreamingAssistantToolCall(messages, index, call);
    }

    public void AppendStreamingAssistantToolCall(string sessionId, Guid assistantMessageId, AgentToolCall call)
    {
        if (!TryStreamingAssistantSlot(sessionId, assistantMessageId, out var messages, out var index))
        {
            return;
        }

        AppendStreamingAssistantToolCall(messages, index, call);
    }

    private static void AppendStreamingAssistantToolCall(List<ChatMessage> messages, int index, AgentToolCall call)
    {
        var message = messages[index];
        var blocks = message.Blocks.ToList();
        blocks.Add(new ChatBlock(ChatBlockKind.ToolCall, ToolCall: call));
        messages[index] = message with { Blocks = blocks };
    }

    public void AppendStreamingAssistantToolResult(string sessionId, AgentToolResult result)
    {
        var (messages, index) = StreamingAssistantSlot(sessionId, null);
        AppendStreamingAssistantToolResult(messages, index, result);
    }

    public void AppendStreamingAssistantToolResult(string sessionId, Guid assistantMessageId, AgentToolResult result)
    {
        if (!TryStreamingAssistantSlot(sessionId, assistantMessageId, out var messages, out var index))
        {
            return;
        }

        AppendStreamingAssistantToolResult(messages, index, result);
    }

    private static void AppendStreamingAssistantToolResult(List<ChatMessage> messages, int index, AgentToolResult result)
    {
        var message = messages[index];
        var blocks = message.Blocks.ToList();
        blocks.Add(new ChatBlock(ChatBlockKind.ToolResult, ToolResult: result));
        messages[index] = message with { Blocks = blocks };
    }

    public void AppendStreamingAssistantProviderError(string sessionId, ProviderErrorInfo error)
    {
        var (messages, index) = StreamingAssistantSlot(sessionId, null);
        AppendStreamingAssistantProviderError(messages, index, error);
    }

    public void AppendStreamingAssistantProviderError(string sessionId, Guid assistantMessageId, ProviderErrorInfo error)
    {
        if (!TryStreamingAssistantSlot(sessionId, assistantMessageId, out var messages, out var index))
        {
            return;
        }

        AppendStreamingAssistantProviderError(messages, index, error);
    }

    private static void AppendStreamingAssistantProviderError(List<ChatMessage> messages, int index, ProviderErrorInfo error)
    {
        var message = messages[index];
        var blocks = message.Blocks.ToList();
        var duplicateIndex = blocks.FindIndex(block =>
            block.Kind == ChatBlockKind.ProviderError &&
            block.ProviderError is not null &&
            string.Equals(block.ProviderError.RequestId, error.RequestId, StringComparison.OrdinalIgnoreCase));

        var block = new ChatBlock(ChatBlockKind.ProviderError, ProviderError: error);
        if (duplicateIndex >= 0)
        {
            blocks[duplicateIndex] = block;
        }
        else
        {
            blocks.Add(block);
        }

        messages[index] = message with { Blocks = blocks };
    }

    public void FinishStreamingAssistantMessage(string sessionId)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out var messages)) return;
        var index = messages.FindLastIndex(message => message.Role == ChatRole.Assistant && message.IsStreaming);
        if (index < 0) return;
        messages[index] = messages[index] with { IsStreaming = false };
    }

    public void FinishStreamingAssistantMessage(string sessionId, Guid assistantMessageId)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out var messages)) return;
        var index = messages.FindIndex(message => message.Id == assistantMessageId && message.Role == ChatRole.Assistant);
        if (index < 0) return;
        messages[index] = messages[index] with { IsStreaming = false };
    }

    private (List<ChatMessage> Messages, int Index) StreamingAssistantSlot(string sessionId, TokenBudget? budget)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out var messages))
        {
            messages = [];
            MessagesBySession[sessionId] = messages;
        }

        var index = messages.FindLastIndex(message => message.Role == ChatRole.Assistant && message.IsStreaming);
        if (index >= 0)
        {
            return (messages, index);
        }

        messages.Add(new ChatMessage(
            Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Assistant,
            [ChatBlock.FromText("")],
            DateTimeOffset.UtcNow,
            true,
            budget));
        return (messages, messages.Count - 1);
    }

    private bool TryStreamingAssistantSlot(string sessionId, Guid assistantMessageId, out List<ChatMessage> messages, out int index)
    {
        if (!MessagesBySession.TryGetValue(sessionId, out messages!))
        {
            index = -1;
            return false;
        }

        index = messages.FindIndex(message =>
            message.Id == assistantMessageId &&
            message.Role == ChatRole.Assistant &&
            message.IsStreaming);
        return index >= 0;
    }

    private static bool ReplaceSessionState(List<ProjectSession> sessions, string sessionId, SessionState state)
    {
        var index = sessions.FindIndex(session => string.Equals(session.Id, sessionId, StringComparison.OrdinalIgnoreCase));
        if (index < 0) return false;
        sessions[index] = sessions[index] with
        {
            State = state,
            UpdatedAt = DateTimeOffset.UtcNow,
            LastActivity = DateTimeOffset.UtcNow,
            LastConversationAt = DateTimeOffset.UtcNow,
        };
        return true;
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        return true;
    }
}
