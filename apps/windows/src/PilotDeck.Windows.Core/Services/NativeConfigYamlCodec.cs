using System.Text.Json;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace PilotDeck.Windows.Core;

public sealed record NativeConfigYamlParseResult(AppSettings Settings, Dictionary<string, string> Secrets);

public static class NativeConfigYamlCodec
{
    private const string Mask = "********";

    private static readonly ISerializer Serializer = new SerializerBuilder()
        .WithNamingConvention(CamelCaseNamingConvention.Instance)
        .ConfigureDefaultValuesHandling(DefaultValuesHandling.OmitNull)
        .Build();

    private static readonly IDeserializer Deserializer = new DeserializerBuilder()
        .WithNamingConvention(CamelCaseNamingConvention.Instance)
        .Build();

    public static string ToYaml(AppSettings settings) =>
        ToYaml(settings, settings.RawConfigDocument?.LastYaml);

    public static string ToYaml(AppSettings settings, string? baseYaml)
    {
        settings = AppState.NormalizeSettings(settings);
        var gateway = settings.GatewaySettings ?? NativeGatewaySettings.Defaults;
        var alwaysOn = settings.AlwaysOnSettings ?? NativeAlwaysOnSettings.Defaults;
        var memory = settings.MemorySettings ?? NativeMemorySettings.Defaults;
        var rag = settings.RagSettings ?? NativeRagSettings.Defaults;

        var raw = RootFromYaml(baseYaml);
        raw["version"] = 1;

        var runtime = EnsureDict(raw, "runtime");
        runtime["host"] = gateway.Host;
        runtime["serverPort"] = gateway.ServerPort;
        runtime["vitePort"] = gateway.VitePort;
        runtime["proxyPort"] = gateway.ProxyPort;
        runtime["contextWindow"] = settings.ContextWindow;
        runtime["apiTimeoutMs"] = settings.ApiTimeoutMs;
        runtime["httpsProxy"] = settings.RuntimeSettings?.HttpsProxy ?? "";
        runtime["databasePath"] = settings.RuntimeSettings?.DatabasePath;
        runtime["workspacesRoot"] = settings.WorkspacesRoot;

        var models = EnsureDict(raw, "models");
        var providers = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var provider in settings.Providers ?? [NativeProviderEntry.FromProviderConfig(settings.ProviderConfig)])
        {
            var node = GetDict(EnsureDict(models, "providers"), provider.Id);
            node["type"] = ApiTypeToYaml(provider.ApiType);
            node["baseUrl"] = provider.BaseUrl;
            node["apiKey"] = Mask;
            node["transformer"] = node.TryGetValue("transformer", out var transformer) ? transformer : null;
            node["headers"] = provider.Headers;
            node.Remove("secretAccount");
            providers[provider.Id] = node;
        }
        models["providers"] = providers;

        models["entries"] = (settings.ModelEntries ?? [NativeModelEntry.FromProviderConfig(settings.ProviderConfig)])
            .ToDictionary(
                entry => entry.Id,
                entry => (object?)new Dictionary<string, object?>
                {
                    ["provider"] = entry.ProviderId,
                    ["name"] = entry.Name,
                    ["contextWindow"] = entry.ContextWindow,
                }, StringComparer.OrdinalIgnoreCase);

        var agents = EnsureDict(raw, "agents");
        EnsureDict(agents, "main")["model"] = settings.AgentSettings?.MainModelEntryId;
        EnsureDict(agents, "main")["params"] = ParamsFromJson(settings.AgentSettings?.ParamsJson);
        EnsureDict(agents, "subagents")["default"] = settings.AgentSettings?.SubagentDefaultModelEntryId;
        EnsureDict(agents, "subagents")["params"] = ParamsFromJson(settings.AgentSettings?.ParamsJson);

        var alwaysOnRoot = EnsureDict(EnsureDict(raw, "alwaysOn"), "discovery");
        var alwaysOnTrigger = EnsureDict(alwaysOnRoot, "trigger");
        alwaysOnTrigger["enabled"] = alwaysOn.Enabled;
        alwaysOnTrigger["tickIntervalMinutes"] = alwaysOn.TickIntervalMinutes;
        alwaysOnTrigger["cooldownMinutes"] = alwaysOn.CooldownMinutes;
        alwaysOnTrigger["dailyBudget"] = alwaysOn.DailyBudget;
        alwaysOnTrigger["heartbeatStaleSeconds"] = alwaysOn.HeartbeatStaleSeconds;
        alwaysOnTrigger["recentUserMsgMinutes"] = alwaysOn.RecentUserMessageMinutes;
        alwaysOnTrigger["preferClient"] = alwaysOn.PreferClient;
        alwaysOnRoot["projects"] = alwaysOn.ProjectEnabled.ToDictionary(
            item => item.Key,
            item => (object?)new Dictionary<string, object?> { ["enabled"] = item.Value },
            StringComparer.OrdinalIgnoreCase);

        var memoryRoot = EnsureDict(raw, "memory");
        memoryRoot["enabled"] = memory.Enabled;
        memoryRoot["model"] = memory.ModelEntryId;
        memoryRoot["params"] = ParamsFromJson(memory.ParamsJson);
        memoryRoot["reasoningMode"] = memory.ReasoningMode;
        memoryRoot["autoIndexIntervalMinutes"] = memory.AutoIndexIntervalMinutes;
        memoryRoot["autoDreamIntervalMinutes"] = memory.AutoDreamIntervalMinutes;
        memoryRoot["captureStrategy"] = memory.CaptureStrategy;
        memoryRoot["includeAssistant"] = memory.IncludeAssistant;
        memoryRoot["maxMessageChars"] = memory.MaxMessageChars;
        memoryRoot["heartbeatBatchSize"] = memory.HeartbeatBatchSize;

        var ragRoot = EnsureDict(raw, "rag");
        ragRoot["enabled"] = rag.Enabled;
        ragRoot["disableBuiltInWebTools"] = rag.DisableBuiltInWebTools;
        var localKnowledge = EnsureDict(ragRoot, "localKnowledge");
        localKnowledge["baseUrl"] = rag.LocalKnowledgeBaseUrl;
        localKnowledge["apiKey"] = Mask;
        localKnowledge["modelName"] = rag.LocalKnowledgeModelName;
        localKnowledge["databaseUrl"] = rag.LocalKnowledgeDatabaseUrl;
        localKnowledge["defaultTopK"] = rag.LocalKnowledgeDefaultTopK;
        localKnowledge.Remove("secretAccount");
        var glmWebSearch = EnsureDict(ragRoot, "glmWebSearch");
        glmWebSearch["baseUrl"] = rag.GlmWebSearchBaseUrl;
        glmWebSearch["apiKey"] = Mask;
        glmWebSearch["defaultTopK"] = rag.GlmWebSearchDefaultTopK;
        glmWebSearch.Remove("secretAccount");

        var router = EnsureDict(raw, "router");
        router["enabled"] = settings.RouterSettings.Enabled;
        router["log"] = settings.RouterSettings.Log;
        router["host"] = settings.RouterSettings.Host;
        router["port"] = settings.RouterSettings.Port;
        router["apiTimeoutMs"] = settings.ApiTimeoutMs;
        var routes = EnsureDict(router, "routes");
        EnsureDict(routes, "default")["model"] = settings.RouterSettings.DefaultRoute;
        if (settings.RouterSettings.TierModelEntries.Count > 0)
        {
            var tiers = EnsureDict(EnsureDict(router, "tokenSaver"), "tiers");
            foreach (var (tier, modelEntry) in settings.RouterSettings.TierModelEntries)
            {
                EnsureDict(tiers, tier)["model"] = modelEntry;
            }
        }

        var gatewayRoot = EnsureDict(raw, "gateway");
        gatewayRoot["enabled"] = settings.FeatureSettings.GatewayEnabled;
        gatewayRoot["home"] = gateway.Home;
        EnsureDict(gatewayRoot, "runtimePaths")["generalCwd"] = settings.GeneralWorkspacePath;

        return Serializer.Serialize(raw);
    }

    public static string MaskSecretsInYaml(string yaml)
    {
        if (string.IsNullOrWhiteSpace(yaml)) return "";
        try
        {
            return Serializer.Serialize(MaskSensitiveObject(Deserializer.Deserialize<object>(yaml), null));
        }
        catch
        {
            return string.Join(Environment.NewLine, yaml.Split(["\r\n", "\n"], StringSplitOptions.None)
                .Select(line => IsSensitiveKey(line.Split(':', 2)[0].Trim()) && line.Contains(':')
                    ? $"{line.Split(':', 2)[0]}: {Mask}"
                    : line));
        }
    }

    public static NativeConfigYamlParseResult ApplyYaml(AppSettings current, string yaml)
    {
        var root = Dict(Deserializer.Deserialize<object>(yaml));
        var runtime = GetDict(root, "runtime");
        var models = GetDict(root, "models");
        var providersYaml = GetDict(models, "providers");
        var entriesYaml = GetDict(models, "entries");
        var agents = GetDict(root, "agents");
        var memory = GetDict(root, "memory");
        var alwaysOn = GetDict(GetDict(root, "alwaysOn"), "discovery");
        var alwaysOnTrigger = GetDict(alwaysOn, "trigger");
        var rag = GetDict(root, "rag");
        var router = GetDict(root, "router");
        var gateway = GetDict(root, "gateway");
        var secrets = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        var providers = new List<NativeProviderEntry>();
        foreach (var (id, value) in providersYaml)
        {
            var provider = Dict(value);
            var normalizedId = NativeSettingsIds.Normalize(id, providers.Count == 0 ? "pilotdeck" : $"provider{providers.Count + 1}");
            var secretAccount = GetString(provider, "secretAccount", $"pilotdeck-provider-{normalizedId}");
            var apiKey = GetString(provider, "apiKey", "");
            if (!string.IsNullOrWhiteSpace(apiKey) && apiKey != Mask)
            {
                secrets[secretAccount] = apiKey;
            }

            providers.Add(new NativeProviderEntry(
                normalizedId,
                ApiTypeFromYaml(GetString(provider, "type", "openai-chat")),
                GetString(provider, "baseUrl", ""),
                secretAccount,
                ReadStringMap(GetDict(provider, "headers"))));
        }

        if (providers.Count == 0)
        {
            providers.Add(NativeProviderEntry.FromProviderConfig(current.ProviderConfig));
        }

        var modelEntries = new List<NativeModelEntry>();
        foreach (var (id, value) in entriesYaml)
        {
            var entry = Dict(value);
            modelEntries.Add(new NativeModelEntry(
                NativeSettingsIds.Normalize(id, modelEntries.Count == 0 ? "default" : $"model{modelEntries.Count + 1}"),
                GetString(entry, "provider", providers[0].Id),
                GetString(entry, "name", ""),
                GetInt(entry, "contextWindow", GetInt(runtime, "contextWindow", current.ContextWindow))));
        }

        if (modelEntries.Count == 0)
        {
            modelEntries.Add(NativeModelEntry.FromProviderConfig(current.ProviderConfig) with { ProviderId = providers[0].Id });
        }

        var mainAgent = GetDict(agents, "main");
        var subagents = GetDict(agents, "subagents");
        var agentSettings = new NativeAgentSettings(
            GetString(mainAgent, "model", modelEntries[0].Id),
            GetString(subagents, "default", modelEntries[0].Id),
            JsonSerializer.Serialize(GetObject(mainAgent, "params") ?? GetObject(subagents, "params") ?? new Dictionary<string, object>()));

        var memorySettings = new NativeMemorySettings(
            GetBool(memory, "enabled", current.MemorySettings?.Enabled ?? current.FeatureSettings.MemoryEnabled),
            GetString(memory, "model", current.MemorySettings?.ModelEntryId ?? "memory"),
            JsonSerializer.Serialize(GetObject(memory, "params") ?? new Dictionary<string, object>()),
            GetString(memory, "reasoningMode", current.MemorySettings?.ReasoningMode ?? NativeMemorySettings.Defaults.ReasoningMode),
            GetInt(memory, "autoIndexIntervalMinutes", current.MemorySettings?.AutoIndexIntervalMinutes ?? NativeMemorySettings.Defaults.AutoIndexIntervalMinutes),
            GetInt(memory, "autoDreamIntervalMinutes", current.MemorySettings?.AutoDreamIntervalMinutes ?? NativeMemorySettings.Defaults.AutoDreamIntervalMinutes),
            GetString(memory, "captureStrategy", current.MemorySettings?.CaptureStrategy ?? NativeMemorySettings.Defaults.CaptureStrategy),
            GetBool(memory, "includeAssistant", current.MemorySettings?.IncludeAssistant ?? NativeMemorySettings.Defaults.IncludeAssistant),
            GetInt(memory, "maxMessageChars", current.MemorySettings?.MaxMessageChars ?? NativeMemorySettings.Defaults.MaxMessageChars),
            GetInt(memory, "heartbeatBatchSize", current.MemorySettings?.HeartbeatBatchSize ?? NativeMemorySettings.Defaults.HeartbeatBatchSize));

        var alwaysOnSettings = new NativeAlwaysOnSettings(
            GetBool(alwaysOnTrigger, "enabled", current.AlwaysOnSettings?.Enabled ?? false),
            GetInt(alwaysOnTrigger, "tickIntervalMinutes", current.AlwaysOnSettings?.TickIntervalMinutes ?? 15),
            GetInt(alwaysOnTrigger, "cooldownMinutes", current.AlwaysOnSettings?.CooldownMinutes ?? 60),
            GetInt(alwaysOnTrigger, "dailyBudget", current.AlwaysOnSettings?.DailyBudget ?? 12),
            GetInt(alwaysOnTrigger, "heartbeatStaleSeconds", current.AlwaysOnSettings?.HeartbeatStaleSeconds ?? 300),
            GetInt(alwaysOnTrigger, "recentUserMsgMinutes", current.AlwaysOnSettings?.RecentUserMessageMinutes ?? 30),
            GetString(alwaysOnTrigger, "preferClient", current.AlwaysOnSettings?.PreferClient ?? "webui"),
            ReadProjectEnabled(GetDict(alwaysOn, "projects")));

        var localKnowledge = GetDict(rag, "localKnowledge");
        var glmWebSearch = GetDict(rag, "glmWebSearch");
        var localSecret = GetString(localKnowledge, "secretAccount", current.RagSettings?.LocalKnowledgeSecretAccount ?? NativeRagSettings.Defaults.LocalKnowledgeSecretAccount);
        var localKey = GetString(localKnowledge, "apiKey", "");
        if (!string.IsNullOrWhiteSpace(localKey) && localKey != Mask) secrets[localSecret] = localKey;
        var glmSecret = GetString(glmWebSearch, "secretAccount", current.RagSettings?.GlmWebSearchSecretAccount ?? NativeRagSettings.Defaults.GlmWebSearchSecretAccount);
        var glmKey = GetString(glmWebSearch, "apiKey", "");
        if (!string.IsNullOrWhiteSpace(glmKey) && glmKey != Mask) secrets[glmSecret] = glmKey;

        var ragSettings = new NativeRagSettings(
            GetBool(rag, "enabled", current.RagSettings?.Enabled ?? false),
            GetBool(rag, "disableBuiltInWebTools", current.RagSettings?.DisableBuiltInWebTools ?? false),
            GetString(localKnowledge, "baseUrl", current.RagSettings?.LocalKnowledgeBaseUrl ?? ""),
            localSecret,
            GetString(localKnowledge, "modelName", current.RagSettings?.LocalKnowledgeModelName ?? ""),
            GetString(localKnowledge, "databaseUrl", current.RagSettings?.LocalKnowledgeDatabaseUrl ?? ""),
            GetInt(localKnowledge, "defaultTopK", current.RagSettings?.LocalKnowledgeDefaultTopK ?? 5),
            GetString(glmWebSearch, "baseUrl", current.RagSettings?.GlmWebSearchBaseUrl ?? ""),
            glmSecret,
            GetInt(glmWebSearch, "defaultTopK", current.RagSettings?.GlmWebSearchDefaultTopK ?? 5));

        var gatewaySettings = new NativeGatewaySettings(
            GetBool(gateway, "enabled", current.FeatureSettings.GatewayEnabled),
            GetString(gateway, "home", current.GatewaySettings?.Home ?? ""),
            GetString(runtime, "host", current.GatewaySettings?.Host ?? "0.0.0.0"),
            GetInt(runtime, "serverPort", current.GatewaySettings?.ServerPort ?? 3001),
            GetInt(runtime, "vitePort", current.GatewaySettings?.VitePort ?? 5173),
            GetInt(runtime, "proxyPort", current.GatewaySettings?.ProxyPort ?? 18080));

        var settings = AppState.NormalizeSettings(current with
        {
            WorkspacesRoot = GetString(runtime, "workspacesRoot", current.WorkspacesRoot),
            GeneralWorkspacePath = GetString(runtime, "generalWorkspacePath",
                GetString(GetDict(gateway, "runtimePaths"), "generalCwd", current.GeneralWorkspacePath)),
            ApiTimeoutMs = GetInt(runtime, "apiTimeoutMs", current.ApiTimeoutMs),
            ContextWindow = GetInt(runtime, "contextWindow", current.ContextWindow),
            RuntimeSettings = new NativeRuntimeSettings(
                GetString(runtime, "workspacesRoot", current.WorkspacesRoot),
                GetString(runtime, "generalWorkspacePath",
                    GetString(GetDict(gateway, "runtimePaths"), "generalCwd", current.GeneralWorkspacePath)),
                GetInt(runtime, "apiTimeoutMs", current.ApiTimeoutMs),
                GetInt(runtime, "contextWindow", current.ContextWindow),
                GetString(runtime, "databasePath", current.RuntimeSettings?.DatabasePath ?? NativeRuntimeSettings.Defaults(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).DatabasePath),
                GetString(runtime, "httpsProxy", current.RuntimeSettings?.HttpsProxy ?? "")),
            Providers = providers,
            ModelEntries = modelEntries,
            AgentSettings = agentSettings,
            FeatureSettings = new NativeFeatureSettings(
                GetBool(memory, "enabled", current.FeatureSettings.MemoryEnabled),
                GetBool(rag, "enabled", current.FeatureSettings.RagEnabled),
                GetBool(gateway, "enabled", current.FeatureSettings.GatewayEnabled)),
            AlwaysOnSettings = alwaysOnSettings,
            MemorySettings = memorySettings,
            RagSettings = ragSettings,
            RouterSettings = new NativeRouterSettings(
                GetBool(router, "enabled", current.RouterSettings.Enabled),
                GetString(router, "defaultRoute",
                    GetString(GetDict(GetDict(router, "routes"), "default"), "model", current.RouterSettings.DefaultRoute)),
                ReadRouterTierMap(router),
                GetDecimal(router, "inputPricePerMillion", current.RouterSettings.InputPricePerMillion),
                GetDecimal(router, "outputPricePerMillion", current.RouterSettings.OutputPricePerMillion),
                GetDecimal(router, "baselineInputPricePerMillion", current.RouterSettings.BaselineInputPricePerMillion),
                GetDecimal(router, "baselineOutputPricePerMillion", current.RouterSettings.BaselineOutputPricePerMillion),
                GetBool(router, "log", current.RouterSettings.Log),
                GetString(router, "host", current.RouterSettings.Host),
                GetInt(router, "port", current.RouterSettings.Port)).Normalize(),
            GatewaySettings = gatewaySettings,
        });

        settings = settings with
        {
            RawConfigDocument = new NativeConfigRawDocument(MaskSecretsInYaml(yaml), DateTimeOffset.UtcNow),
        };

        return new NativeConfigYamlParseResult(settings, secrets);
    }

    private static object? ParamsFromJson(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new Dictionary<string, object?>();
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, object?>>(json) ?? new Dictionary<string, object?>();
        }
        catch
        {
            return new Dictionary<string, object?> { ["raw"] = json };
        }
    }

    private static string ApiTypeToYaml(ProviderApiType type) => type switch
    {
        ProviderApiType.OpenAIResponses => "openai-responses",
        ProviderApiType.AnthropicMessages => "anthropic-messages",
        _ => "openai-chat",
    };

    private static ProviderApiType ApiTypeFromYaml(string value) => value.Trim().ToLowerInvariant() switch
    {
        "openai-responses" or "responses" => ProviderApiType.OpenAIResponses,
        "anthropic-messages" or "anthropic" => ProviderApiType.AnthropicMessages,
        _ => ProviderApiType.OpenAIChat,
    };

    private static Dictionary<string, object?> Dict(object? value)
    {
        if (value is Dictionary<object, object> objectDict)
        {
            return objectDict.ToDictionary(item => item.Key.ToString() ?? "", item => (object?)item.Value, StringComparer.OrdinalIgnoreCase);
        }

        if (value is Dictionary<string, object?> stringDict)
        {
            return new Dictionary<string, object?>(stringDict, StringComparer.OrdinalIgnoreCase);
        }

        return new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
    }

    private static Dictionary<string, object?> RootFromYaml(string? yaml)
    {
        if (string.IsNullOrWhiteSpace(yaml)) return new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        try
        {
            return Dict(Deserializer.Deserialize<object>(yaml));
        }
        catch
        {
            return new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        }
    }

    private static Dictionary<string, object?> EnsureDict(Dictionary<string, object?> dict, string key)
    {
        if (dict.TryGetValue(key, out var value))
        {
            var existing = Dict(value);
            dict[key] = existing;
            return existing;
        }

        var created = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        dict[key] = created;
        return created;
    }

    private static Dictionary<string, object?> GetDict(Dictionary<string, object?> dict, string key) =>
        dict.TryGetValue(key, out var value) ? Dict(value) : new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);

    private static object? GetObject(Dictionary<string, object?> dict, string key) =>
        dict.TryGetValue(key, out var value) ? value : null;

    private static string GetString(Dictionary<string, object?> dict, string key, string fallback) =>
        dict.TryGetValue(key, out var value) && value is not null ? value.ToString() ?? fallback : fallback;

    private static int GetInt(Dictionary<string, object?> dict, string key, int fallback) =>
        dict.TryGetValue(key, out var value) && int.TryParse(value?.ToString(), out var parsed) ? parsed : fallback;

    private static decimal GetDecimal(Dictionary<string, object?> dict, string key, decimal fallback) =>
        dict.TryGetValue(key, out var value) && decimal.TryParse(value?.ToString(), out var parsed) ? parsed : fallback;

    private static bool GetBool(Dictionary<string, object?> dict, string key, bool fallback) =>
        dict.TryGetValue(key, out var value) && bool.TryParse(value?.ToString(), out var parsed) ? parsed : fallback;

    private static Dictionary<string, string> ReadStringMap(Dictionary<string, object?> dict) =>
        dict.ToDictionary(item => item.Key, item => item.Value?.ToString() ?? "", StringComparer.OrdinalIgnoreCase);

    private static Dictionary<string, string> ReadRouterTierMap(Dictionary<string, object?> router)
    {
        var direct = ReadStringMap(GetDict(router, "tierModelEntries"));
        var tiers = GetDict(GetDict(router, "tokenSaver"), "tiers");
        foreach (var (tier, value) in tiers)
        {
            var model = GetString(Dict(value), "model", "");
            if (!string.IsNullOrWhiteSpace(model))
            {
                direct[tier] = model;
            }
        }

        return direct;
    }

    private static Dictionary<string, bool> ReadProjectEnabled(Dictionary<string, object?> dict)
    {
        var result = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in dict)
        {
            result[key] = GetBool(Dict(value), "enabled", false);
        }

        return result;
    }

    private static object? MaskSensitiveObject(object? value, string? key)
    {
        if (IsSensitiveKey(key))
        {
            var text = value?.ToString() ?? "";
            return string.IsNullOrWhiteSpace(text) ? value : Mask;
        }

        if (value is Dictionary<object, object> objectDict)
        {
            return objectDict.ToDictionary(
                item => item.Key.ToString() ?? "",
                item => MaskSensitiveObject(item.Value, item.Key.ToString()),
                StringComparer.OrdinalIgnoreCase);
        }

        if (value is Dictionary<string, object?> stringDict)
        {
            return stringDict.ToDictionary(
                item => item.Key,
                item => MaskSensitiveObject(item.Value, item.Key),
                StringComparer.OrdinalIgnoreCase);
        }

        if (value is not string && value is System.Collections.IEnumerable list)
        {
            return list.Cast<object?>().Select(item => MaskSensitiveObject(item, null)).ToList();
        }

        return value;
    }

    private static bool IsSensitiveKey(string? key)
    {
        if (string.IsNullOrWhiteSpace(key)) return false;
        var normalized = key.Replace("_", "", StringComparison.Ordinal).Replace("-", "", StringComparison.Ordinal).ToLowerInvariant();
        return normalized is "apikey" or "key" or "token" or "password" or "secret" or "authtoken" or "accesstoken"
            || normalized.Contains("secret", StringComparison.Ordinal)
            || normalized.Contains("token", StringComparison.Ordinal)
            || normalized.Contains("password", StringComparison.Ordinal)
            || normalized.Contains("apikey", StringComparison.Ordinal)
            || normalized.Contains("aeskey", StringComparison.Ordinal);
    }
}
