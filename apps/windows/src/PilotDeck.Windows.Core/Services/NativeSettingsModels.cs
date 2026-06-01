namespace PilotDeck.Windows.Core;

public sealed record NativeSettingsDraft(
    ProviderApiType ApiType,
    string BaseUrl,
    string Model,
    string ApiKey,
    string WorkspacesRoot,
    string GeneralWorkspacePath,
    int ApiTimeoutMs,
    int ContextWindow,
    ProjectSortOrder ProjectSortOrder,
    AppColorScheme ColorScheme,
    AppLanguage Language,
    bool EditorWordWrap,
    bool EditorShowMinimap,
    bool EditorLineNumbers,
    int EditorFontSize,
    List<string> AllowedTools,
    List<string> DisallowedTools,
    bool RouterEnabled,
    string RouterDefaultRoute,
    decimal RouterInputPricePerMillion,
    decimal RouterOutputPricePerMillion,
    decimal RouterBaselineInputPricePerMillion,
    decimal RouterBaselineOutputPricePerMillion,
    bool MemoryEnabled,
    bool RagEnabled,
    bool GatewayEnabled,
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
    public static NativeSettingsDraft From(AppSettings settings, string apiKey = "") => new(
        settings.ProviderConfig.ApiType,
        settings.ProviderConfig.BaseUrl,
        settings.ProviderConfig.Model,
        apiKey,
        settings.WorkspacesRoot,
        settings.GeneralWorkspacePath,
        settings.ApiTimeoutMs,
        settings.ContextWindow,
        settings.ProjectSortOrder,
        settings.ColorScheme,
        settings.Language,
        settings.EditorSettings.WordWrap,
        settings.EditorSettings.ShowMinimap,
        settings.EditorSettings.LineNumbers,
        settings.EditorSettings.FontSize,
        settings.Permissions.AllowedTools.ToList(),
        settings.Permissions.DisallowedTools.ToList(),
        settings.RouterSettings.Enabled,
        settings.RouterSettings.DefaultRoute,
        settings.RouterSettings.InputPricePerMillion,
        settings.RouterSettings.OutputPricePerMillion,
        settings.RouterSettings.BaselineInputPricePerMillion,
        settings.RouterSettings.BaselineOutputPricePerMillion,
        settings.FeatureSettings.MemoryEnabled,
        settings.FeatureSettings.RagEnabled,
        settings.FeatureSettings.GatewayEnabled,
        settings.Providers?.ToList() ?? [NativeProviderEntry.FromProviderConfig(settings.ProviderConfig)],
        settings.ModelEntries?.ToList() ?? [NativeModelEntry.FromProviderConfig(settings.ProviderConfig)],
        settings.AgentSettings ?? NativeAgentSettings.Defaults,
        settings.RuntimeSettings ?? new NativeRuntimeSettings(
            settings.WorkspacesRoot,
            settings.GeneralWorkspacePath,
            settings.ApiTimeoutMs,
            settings.ContextWindow,
            NativeRuntimeSettings.Defaults(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).DatabasePath),
        settings.AlwaysOnSettings ?? NativeAlwaysOnSettings.Defaults,
        settings.MemorySettings ?? NativeMemorySettings.Defaults,
        settings.RagSettings ?? NativeRagSettings.Defaults,
        settings.GatewaySettings ?? NativeGatewaySettings.Defaults,
        settings.RawConfigDocument ?? NativeConfigRawDocument.Defaults);

    public SettingsValidationResult Validate()
    {
        var errors = new List<string>();
        if (!string.IsNullOrWhiteSpace(BaseUrl) && !Uri.TryCreate(BaseUrl.Trim(), UriKind.Absolute, out _))
        {
            errors.Add("Provider base URL must be an absolute URL.");
        }

        if (ApiTimeoutMs < 5_000) errors.Add("API timeout must be at least 5000 ms.");
        if (ContextWindow < 1_000) errors.Add("Context window must be at least 1000 tokens.");
        if (EditorFontSize is < 10 or > 24) errors.Add("Editor font size must be between 10 and 24.");
        ValidateAbsolutePath(WorkspacesRoot, "Workspaces root", errors);
        ValidateAbsolutePath(GeneralWorkspacePath, "General workspace path", errors);
        if (RouterInputPricePerMillion < 0 || RouterOutputPricePerMillion < 0 ||
            RouterBaselineInputPricePerMillion < 0 || RouterBaselineOutputPricePerMillion < 0)
        {
            errors.Add("Router pricing cannot be negative.");
        }

        var providerIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var provider in Providers ?? [])
        {
            if (string.IsNullOrWhiteSpace(provider.Id)) errors.Add("Provider id is required.");
            if (!providerIds.Add(provider.Id.Trim())) errors.Add($"Duplicate provider id: {provider.Id}");
            if (!string.IsNullOrWhiteSpace(provider.BaseUrl) && !Uri.TryCreate(provider.BaseUrl.Trim(), UriKind.Absolute, out _))
            {
                errors.Add($"Provider {provider.Id} base URL must be an absolute URL.");
            }
        }

        var modelIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in ModelEntries ?? [])
        {
            if (string.IsNullOrWhiteSpace(entry.Id)) errors.Add("Model entry id is required.");
            if (!modelIds.Add(entry.Id.Trim())) errors.Add($"Duplicate model entry id: {entry.Id}");
            if (string.IsNullOrWhiteSpace(entry.ProviderId)) errors.Add($"Model entry {entry.Id} requires a provider id.");
            if (entry.ContextWindow is > 0 and < 1_000) errors.Add($"Model entry {entry.Id} context window must be at least 1000 tokens.");
        }

        if (AgentSettings is { } agent && modelIds.Count > 0 &&
            !modelIds.Contains(string.IsNullOrWhiteSpace(agent.MainModelEntryId) ? "default" : agent.MainModelEntryId))
        {
            errors.Add("Agent main model entry must reference an existing model entry.");
        }

        if (RagSettings is { } rag)
        {
            ValidateOptionalUrl(rag.LocalKnowledgeBaseUrl, "Local knowledge base URL", errors);
            ValidateOptionalUrl(rag.GlmWebSearchBaseUrl, "GLM web search base URL", errors);
        }

        return new SettingsValidationResult(errors.Count == 0, errors);
    }

    public AppSettings ApplyTo(AppSettings current)
    {
        var provider = current.ProviderConfig with
        {
            ApiType = ApiType,
            BaseUrl = BaseUrl.Trim(),
            Model = Model.Trim(),
        };
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var runtime = (RuntimeSettings ?? new NativeRuntimeSettings(
            WorkspacesRoot,
            GeneralWorkspacePath,
            ApiTimeoutMs,
            ContextWindow,
            NativeRuntimeSettings.Defaults(home).DatabasePath)).Normalize(home);
        var hasExplicitProviders = Providers is { Count: > 0 };
        var rawProviders = hasExplicitProviders
            ? Providers!.Select(entry => entry).ToList()
            : [NativeProviderEntry.FromProviderConfig(provider) with
            {
                ApiType = ApiType,
                BaseUrl = BaseUrl.Trim(),
                SecretAccount = provider.SecretAccount,
            }];
        var providers = rawProviders.Select((entry, index) => entry.Normalize(index)).ToList();

        var hasExplicitModels = ModelEntries is { Count: > 0 };
        var rawModels = hasExplicitModels
            ? ModelEntries!.Select(entry => entry).ToList()
            : [NativeModelEntry.FromProviderConfig(provider) with
            {
                ProviderId = providers.FirstOrDefault()?.Id ?? "pilotdeck",
                Name = Model.Trim(),
                ContextWindow = ContextWindow,
            }];
        var models = rawModels.Select((entry, index) => entry.Normalize(providers, runtime.ContextWindow, index)).ToList();
        var agents = (AgentSettings ?? NativeAgentSettings.Defaults).Normalize(models);
        var alwaysOn = (AlwaysOnSettings ?? NativeAlwaysOnSettings.Defaults).Normalize();
        var memory = (MemorySettings ?? NativeMemorySettings.Defaults).Normalize(models);
        var rag = (RagSettings ?? NativeRagSettings.Defaults).Normalize();
        var gateway = (GatewaySettings ?? NativeGatewaySettings.Defaults).Normalize(home);

        return AppState.NormalizeSettings(current with
        {
            ProviderConfig = provider,
            WorkspacesRoot = runtime.WorkspacesRoot,
            GeneralWorkspacePath = runtime.GeneralWorkspacePath,
            ApiTimeoutMs = runtime.ApiTimeoutMs,
            ContextWindow = runtime.ContextWindow,
            ProjectSortOrder = ProjectSortOrder,
            ColorScheme = ColorScheme,
            Language = Language,
            Permissions = new ToolPermissionSettings(
                NormalizeToolList(AllowedTools),
                NormalizeToolList(DisallowedTools),
                DateTimeOffset.UtcNow),
            EditorSettings = new NativeEditorSettings(EditorWordWrap, EditorShowMinimap, EditorLineNumbers, EditorFontSize).Normalize(),
            RouterSettings = new NativeRouterSettings(
                RouterEnabled,
                RouterDefaultRoute,
                current.RouterSettings.TierModelEntries,
                RouterInputPricePerMillion,
                RouterOutputPricePerMillion,
                RouterBaselineInputPricePerMillion,
                RouterBaselineOutputPricePerMillion).Normalize(),
            FeatureSettings = new NativeFeatureSettings(MemoryEnabled, RagEnabled, GatewayEnabled),
            Providers = providers,
            ModelEntries = models,
            AgentSettings = agents,
            RuntimeSettings = runtime,
            AlwaysOnSettings = alwaysOn,
            MemorySettings = memory,
            RagSettings = rag,
            GatewaySettings = gateway,
            RawConfigDocument = RawConfigDocument ?? current.RawConfigDocument ?? NativeConfigRawDocument.Defaults,
        });
    }

    private static List<string> NormalizeToolList(IEnumerable<string> values) =>
        values.Select(value => value.Trim())
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    private static void ValidateAbsolutePath(string value, string label, List<string> errors)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            errors.Add($"{label} is required.");
            return;
        }

        var expanded = PathHelpers.ExpandHome(value.Trim());
        if (!Path.IsPathFullyQualified(expanded))
        {
            errors.Add($"{label} must be an absolute path.");
        }
    }

    private static void ValidateOptionalUrl(string value, string label, List<string> errors)
    {
        if (!string.IsNullOrWhiteSpace(value) && !Uri.TryCreate(value.Trim(), UriKind.Absolute, out _))
        {
            errors.Add($"{label} must be an absolute URL.");
        }
    }
}

public sealed record SettingsValidationResult(bool Valid, IReadOnlyList<string> Errors);

public static class PermissionsExportCodec
{
    public static string Export(ToolPermissionSettings settings) =>
        System.Text.Json.JsonSerializer.Serialize(new
        {
            allowedTools = settings.AllowedTools,
            disallowedTools = settings.DisallowedTools,
            exportedAt = DateTimeOffset.UtcNow,
        }, new System.Text.Json.JsonSerializerOptions { WriteIndented = true });

    public static ToolPermissionSettings Import(string json)
    {
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var root = doc.RootElement;
        return new ToolPermissionSettings(
            ReadToolArray(root, "allowedTools"),
            ReadToolArray(root, "disallowedTools"),
            DateTimeOffset.UtcNow);
    }

    private static List<string> ReadToolArray(System.Text.Json.JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value) || value.ValueKind != System.Text.Json.JsonValueKind.Array) return [];
        return value.EnumerateArray()
            .Where(item => item.ValueKind == System.Text.Json.JsonValueKind.String)
            .Select(item => item.GetString()!.Trim())
            .Where(item => item.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }
}
