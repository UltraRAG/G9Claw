namespace PilotDeck.Windows.Core;

public sealed record ResolvedAgentModel(
    string ProviderId,
    string ModelEntryId,
    ProviderApiType ApiType,
    string BaseUrl,
    Uri EndpointUrl,
    string ModelName,
    string SecretAccount,
    Dictionary<string, string> Headers,
    int ContextWindow,
    string RouteTier = "direct",
    string RouteEntryId = "",
    string RouteSource = "agent")
{
    public string DisplayLabel => $"{ModelEntryId}:{ModelName}";

    public ProviderConfig ToProviderConfig() => new(
        SessionProvider.PilotDeck,
        ApiType,
        BaseUrl,
        ModelName,
        SecretAccount,
        new Dictionary<string, string>(Headers, StringComparer.OrdinalIgnoreCase));
}

public sealed record ProviderPreflightResult(
    bool Ok,
    string ProviderId,
    string ModelEntryId,
    string EndpointUrl,
    string Diagnostic,
    string SuggestedFix)
{
    public static ProviderPreflightResult Success(ResolvedAgentModel model) => new(
        true,
        model.ProviderId,
        model.ModelEntryId,
        model.EndpointUrl.ToString(),
        "",
        "");

    public static ProviderPreflightResult Failure(
        ResolvedAgentModel? model,
        string diagnostic,
        string suggestedFix) => new(
        false,
        model?.ProviderId ?? "",
        model?.ModelEntryId ?? "",
        model?.EndpointUrl.ToString() ?? "",
        diagnostic,
        suggestedFix);
}

public static class AgentModelResolver
{
    public static ResolvedAgentModel Resolve(
        AppSettings settings,
        string? modelEntryId = null,
        string routeTier = "direct",
        string routeSource = "agent")
    {
        settings = AppState.NormalizeSettings(settings);
        var entries = settings.ModelEntries ?? [];
        var providers = settings.Providers ?? [];
        var agent = settings.AgentSettings ?? NativeAgentSettings.Defaults;
        var requestedEntryId = string.IsNullOrWhiteSpace(modelEntryId)
            ? string.IsNullOrWhiteSpace(agent.MainModelEntryId) ? "default" : agent.MainModelEntryId.Trim()
            : modelEntryId.Trim();
        var entry = entries.FirstOrDefault(item => string.Equals(item.Id, requestedEntryId, StringComparison.OrdinalIgnoreCase));
        if (entry is null && entries.Count > 0)
        {
            throw new InvalidOperationException($"Agent main model entry '{requestedEntryId}' was not found in models.entries.");
        }

        entry ??= NativeModelEntry.FromProviderConfig(settings.ProviderConfig);

        var provider = providers.FirstOrDefault(item => string.Equals(item.Id, entry.ProviderId, StringComparison.OrdinalIgnoreCase));
        if (provider is null && providers.Count > 0)
        {
            throw new InvalidOperationException($"Provider '{entry.ProviderId}' for model entry '{entry.Id}' was not found in models.providers.");
        }

        provider ??= NativeProviderEntry.FromProviderConfig(settings.ProviderConfig);

        var endpoint = NativeAgentRuntime.EndpointUrl(provider.BaseUrl, SuffixFor(provider.ApiType));
        return new ResolvedAgentModel(
            provider.Id,
            entry.Id,
            provider.ApiType,
            provider.BaseUrl,
            endpoint,
            entry.Name,
            provider.SecretAccount,
            new Dictionary<string, string>(provider.Headers, StringComparer.OrdinalIgnoreCase),
            entry.ContextWindow,
            string.IsNullOrWhiteSpace(routeTier) ? "direct" : routeTier,
            entry.Id,
            string.IsNullOrWhiteSpace(routeSource) ? "agent" : routeSource);
    }

    public static ProviderPreflightResult Preflight(AppSettings settings, string? apiKey)
    {
        ResolvedAgentModel? model = null;
        try
        {
            model = Resolve(settings);
        }
        catch (Exception ex)
        {
            return ProviderPreflightResult.Failure(null, ex.Message, "Fix the provider baseUrl in ~/.pd/config.yaml or Settings.");
        }

        return Preflight(model, apiKey);
    }

    public static ProviderPreflightResult Preflight(ResolvedAgentModel model, string? apiKey)
    {
        if (string.IsNullOrWhiteSpace(model.BaseUrl))
        {
            return ProviderPreflightResult.Failure(model, "Provider base URL is empty.", "Set models.providers.<id>.baseUrl.");
        }

        if (string.IsNullOrWhiteSpace(model.ModelName))
        {
            return ProviderPreflightResult.Failure(model, "Model name is empty.", "Set models.entries.<id>.name.");
        }

        var key = apiKey?.Trim();
        if (string.IsNullOrWhiteSpace(key) || key == "********")
        {
            return ProviderPreflightResult.Failure(model, "Provider API key is missing.", "Save a real apiKey in Settings or ~/.pd/config.yaml so it can be stored in DPAPI.");
        }

        return ProviderPreflightResult.Success(model);
    }

    public static string SuffixFor(ProviderApiType apiType) => apiType switch
    {
        ProviderApiType.OpenAIResponses => "responses",
        ProviderApiType.AnthropicMessages => "messages",
        _ => "chat/completions",
    };
}

public sealed record RouterFallbackCandidate(
    ResolvedAgentModel Model,
    string FromModelEntryId,
    string Reason);

public static class RouterFallbackPolicy
{
    public static bool IsModelUnavailable(string error)
    {
        var normalized = (error ?? "").ToLowerInvariant();
        return normalized.Contains("model_not_found") ||
               normalized.Contains("no channel") ||
               normalized.Contains("distributor") ||
               normalized.Contains("\u65e0\u53ef\u7528\u6e20\u9053") ||
               normalized.Contains("\u4e0d\u53ef\u7528\u6e20\u9053");
    }

    public static RouterFallbackCandidate? TryResolve(
        AppSettings settings,
        IReadOnlyDictionary<string, string> nativeConfigValues,
        ResolvedAgentModel failedModel,
        string error)
    {
        if (!IsModelUnavailable(error)) return null;
        if (!failedModel.RouteSource.Contains("router", StringComparison.OrdinalIgnoreCase)) return null;

        var fallbackEntry = FirstNonBlank(
            settings.AgentSettings?.MainModelEntryId,
            TryGet(nativeConfigValues, "agents.main.model"),
            TryGet(nativeConfigValues, "router.routes.default.model"),
            "default");
        if (string.IsNullOrWhiteSpace(fallbackEntry) ||
            string.Equals(fallbackEntry, failedModel.ModelEntryId, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var fallbackModel = AgentModelResolver.Resolve(
            settings,
            fallbackEntry,
            failedModel.RouteTier,
            "router-fallback");
        return new RouterFallbackCandidate(
            fallbackModel,
            failedModel.ModelEntryId,
            "Router-selected model is unavailable; retrying with the main/default model.");
    }

    private static string? TryGet(IReadOnlyDictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;

    private static string FirstNonBlank(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? "default";
}
