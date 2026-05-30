namespace G9Claw.Windows.Core;

public sealed record LegacyConfigSnapshot(
    string? BaseUrl,
    string? Model,
    string? ApiKey,
    string? WorkspacesRoot,
    string? GeneralWorkspacePath);

public sealed record NativeConfigSnapshot(
    ProviderConfig ProviderConfig,
    string? ApiKey,
    string? WorkspacesRoot,
    string? GeneralWorkspacePath,
    int ApiTimeoutMs,
    int ContextWindow,
    string DefaultEntryId,
    Dictionary<string, string> RawValues);

public static class NativeConfigService
{
    public static string DefaultConfigPath(string? homePath = null)
    {
        var home = string.IsNullOrWhiteSpace(homePath)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : homePath;
        return Path.Combine(home, ".g9claw", "config.yaml");
    }

    public static string ReadDefaultConfigText(string? path = null)
    {
        var file = path ?? DefaultConfigPath();
        return File.Exists(file) ? File.ReadAllText(file, System.Text.Encoding.UTF8) : "";
    }

    public static void WriteDefaultConfigText(string yaml, string? path = null)
    {
        var file = path ?? DefaultConfigPath();
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, yaml, System.Text.Encoding.UTF8);
    }

    public static NativeConfigSnapshot? LoadDefaultConfig(string? path = null)
    {
        var file = path ?? DefaultConfigPath();
        return File.Exists(file) ? Snapshot(File.ReadAllText(file, System.Text.Encoding.UTF8)) : null;
    }

    public static NativeConfigSnapshot? Snapshot(string yaml)
    {
        var values = ScalarMap(yaml);
        var defaultEntry = PickFirstConfiguredEntry(values,
            "agents.main.model",
            "router.routes.default.model",
            "router.default");
        var providerConfig = ProviderConfigFor(defaultEntry, values);
        if (providerConfig is null) return null;

        var providerId = ProviderId(defaultEntry, values);
        return new NativeConfigSnapshot(
            providerConfig,
            Values.TryGetNonBlank(values, $"models.providers.{providerId}.apiKey"),
            Values.TryGetNonBlank(values, "runtime.workspacesRoot"),
            Values.TryGetNonBlank(values, "gateway.runtimePaths.generalCwd"),
            Values.TryGetInt(values, "runtime.apiTimeoutMs") ?? Values.TryGetInt(values, "router.apiTimeoutMs") ?? 120_000,
            Values.TryGetInt(values, $"models.entries.{defaultEntry}.contextWindow") ?? Values.TryGetInt(values, "runtime.contextWindow") ?? 160_000,
            defaultEntry,
            values);
    }

    private static string PickFirstConfiguredEntry(Dictionary<string, string> values, params string[] keys)
    {
        foreach (var key in keys)
        {
            var candidate = Values.TryGetNonBlank(values, key);
            if (!HasModelEntry(values, candidate)) continue;
            return candidate!;
        }

        return "default";
    }

    public static Dictionary<string, string> ScalarMap(string yaml)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var stack = new List<(int Indent, string Key)>();

        foreach (var rawLine in yaml.Replace("\r\n", "\n").Split('\n'))
        {
            var trimmed = rawLine.Trim();
            if (string.IsNullOrWhiteSpace(trimmed) || trimmed.StartsWith('#') || trimmed.StartsWith("- ", StringComparison.Ordinal)) continue;

            var indent = rawLine.TakeWhile(ch => ch == ' ').Count();
            while (stack.Count > 0 && stack[^1].Indent >= indent)
            {
                stack.RemoveAt(stack.Count - 1);
            }

            var colon = trimmed.IndexOf(':');
            if (colon <= 0) continue;

            var key = trimmed[..colon].Trim();
            var rawValue = trimmed[(colon + 1)..].Trim();
            if (string.IsNullOrWhiteSpace(rawValue))
            {
                stack.Add((indent, key));
                continue;
            }

            var path = string.Join('.', stack.Select(item => item.Key).Concat([key]));
            result[path] = NormalizeScalar(rawValue);
        }

        return NormalizeScalarMap(result);
    }

    private static Dictionary<string, string> NormalizeScalarMap(Dictionary<string, string> values)
    {
        var normalized = new Dictionary<string, string>(values, StringComparer.Ordinal);
        const string legacyAlwaysOnPrefix = "agents.alwaysOn.discovery.trigger.";
        const string topLevelAlwaysOnPrefix = "alwaysOn.discovery.trigger.";

        var hasTopLevelAlwaysOn = normalized.Keys.Any(key => key.StartsWith(topLevelAlwaysOnPrefix, StringComparison.Ordinal));
        if (!hasTopLevelAlwaysOn)
        {
            foreach (var (key, value) in values.Where(pair => pair.Key.StartsWith(legacyAlwaysOnPrefix, StringComparison.Ordinal)))
            {
                normalized[$"{topLevelAlwaysOnPrefix}{key[legacyAlwaysOnPrefix.Length..]}"] = value;
            }
        }

        normalized = normalized
            .Where(pair => !pair.Key.StartsWith("agents.alwaysOn.", StringComparison.Ordinal))
            .Where(pair => !pair.Key.StartsWith("compat.", StringComparison.Ordinal) && pair.Key != "compat")
            .ToDictionary(pair => pair.Key, pair => pair.Value);

        return normalized;
    }

    public static ProviderConfig? ProviderConfigFor(string entryId, Dictionary<string, string> values)
    {
        var providerId = ProviderId(entryId, values);
        var baseUrl = values.GetValueOrDefault($"models.providers.{providerId}.baseUrl") ?? "";
        var model = values.GetValueOrDefault($"models.entries.{entryId}.name") ?? "";
        if (string.IsNullOrWhiteSpace(baseUrl) && string.IsNullOrWhiteSpace(model)) return null;

        var apiType = (values.GetValueOrDefault($"models.providers.{providerId}.type") ?? "openai-chat") switch
        {
            "openai-responses" => ProviderApiType.OpenAIResponses,
            "anthropic-messages" or "anthropic" => ProviderApiType.AnthropicMessages,
            _ => ProviderApiType.OpenAIChat,
        };
        var headersPrefix = $"models.providers.{providerId}.headers.";
        var headers = values
            .Where(pair => pair.Key.StartsWith(headersPrefix, StringComparison.Ordinal))
            .ToDictionary(pair => pair.Key[headersPrefix.Length..], pair => pair.Value);

        var secretAccount = providerId is "g9claw" or "edgeclaw"
            ? ProviderConfig.Empty.SecretAccount
            : $"g9claw-provider-{providerId}";
        return new ProviderConfig(
            SessionProvider.G9Claw,
            apiType,
            baseUrl,
            model,
            secretAccount,
            headers);
    }

    public static string ProviderId(string entryId, Dictionary<string, string> values) =>
        Values.TryGetNonBlank(values, $"models.entries.{entryId}.provider") ?? "g9claw";

    public static string ResolveApiKey(string routeEntryId, NativeConfigSnapshot? nativeConfig, string? credentialValue, string apiKeyDraft)
    {
        if (nativeConfig is null)
        {
            return Values.FirstNonBlank(credentialValue, apiKeyDraft) ?? "";
        }

        var providerId = ProviderId(routeEntryId, nativeConfig.RawValues);
        return Values.FirstNonMasked(
            nativeConfig.RawValues.GetValueOrDefault($"models.providers.{providerId}.apiKey"),
            nativeConfig.ApiKey,
            credentialValue,
            apiKeyDraft) ?? "";
    }

    private static string NormalizeScalar(string rawValue)
    {
        var value = rawValue;
        var commentStart = value.IndexOf('#');
        if (commentStart >= 0)
        {
            value = value[..commentStart].Trim();
        }

        if ((value.StartsWith('"') && value.EndsWith('"')) || (value.StartsWith('\'') && value.EndsWith('\'')))
        {
            value = value[1..^1];
        }

        return value;
    }
}

public static class NativeRouterRuntime
{
    private const int PerMessageOverhead = 4;
    private const int MultimediaTokens = 2_000;

    public sealed record Decision(string EntryId, string Scenario, string? Tier);

    public sealed record RequestSignals(
        int TokenCount = 0,
        bool IsBackgroundRequest = false,
        bool HasWebSearchTools = false,
        bool HasThinking = false);

    public sealed record ProviderRoute(
        Decision Decision,
        ProviderConfig ProviderConfig,
        string ApiKey,
        int ContextWindow,
        string ProviderId);

    public static string EntryIdForTier(string tier, Dictionary<string, string> values) =>
        DecisionForTier(tier, values).EntryId;

    public static RequestSignals SignalsForPrompt(
        string prompt,
        bool isBackgroundRequest = false,
        bool hasWebSearchTools = false,
        bool hasThinking = false) =>
        new(EstimatedTokens(prompt), isBackgroundRequest, hasWebSearchTools, hasThinking);

    public static RequestSignals SignalsForRequest(
        string prompt,
        IReadOnlyList<ChatMessage> priorMessages,
        IReadOnlyList<FileAttachment> attachments,
        bool isBackgroundRequest = false,
        bool hasWebSearchTools = false,
        bool hasThinking = false)
    {
        var tokenCount = priorMessages.Sum(EstimatedTokens);
        tokenCount += PerMessageOverhead + EstimatedTokens(UserContentForEstimate(prompt, attachments));
        tokenCount += EstimatedTools(AgentToolRegistry.OpenAITools());
        return new RequestSignals(tokenCount, isBackgroundRequest, hasWebSearchTools, hasThinking);
    }

    public static ProviderRoute ResolveProviderRoute(
        string tier,
        Dictionary<string, string> values,
        ProviderConfig fallbackProviderConfig,
        string fallbackApiKey,
        int fallbackContextWindow,
        RequestSignals? signals = null)
    {
        signals ??= new RequestSignals();
        var decision = DecisionForTier(tier, values, signals);
        var providerConfig = NativeConfigService.ProviderConfigFor(decision.EntryId, values) ?? fallbackProviderConfig;
        var providerId = NativeConfigService.ProviderId(decision.EntryId, values);
        var apiKey = Values.FirstNonMasked(
            values.GetValueOrDefault($"models.providers.{providerId}.apiKey"),
            fallbackApiKey) ?? "";
        var contextWindow = Values.TryGetInt(values, $"models.entries.{decision.EntryId}.contextWindow") ?? fallbackContextWindow;
        return new ProviderRoute(decision, providerConfig, apiKey, contextWindow, providerId);
    }

    public static Decision DecisionForTier(
        string tier,
        Dictionary<string, string> values,
        RequestSignals? signals = null)
    {
        signals ??= new RequestSignals();
        var mainRoute = MainEntryId(values) ?? "default";
        var defaultRoute = RouteEntryId("default", values) ?? mainRoute;
        if (!IsEnabled(values.GetValueOrDefault("router.enabled")))
        {
            return new Decision(mainRoute, "default", null);
        }

        var normalizedTier = (tier ?? "").Trim().ToUpperInvariant();
        var tokenSaverTier = Values.TryGetNonBlank(values, $"router.tokenSaver.tiers.{normalizedTier}.model");
        if (TokenSaverCanRoute(values) &&
            HasModelEntry(values, tokenSaverTier))
        {
            return new Decision(tokenSaverTier!, "tokenSaver", normalizedTier);
        }

        var threshold = LongContextThreshold(values);
        if (signals.TokenCount > threshold &&
            RouteEntryId("longContext", values) is { } longContextRoute)
        {
            return new Decision(longContextRoute, "longContext", null);
        }

        if (signals.IsBackgroundRequest &&
            RouteEntryId("background", values) is { } backgroundRoute)
        {
            return new Decision(backgroundRoute, "background", null);
        }

        if (signals.HasWebSearchTools &&
            RouteEntryId("webSearch", values) is { } webSearchRoute)
        {
            return new Decision(webSearchRoute, "webSearch", null);
        }

        if (signals.HasThinking &&
            RouteEntryId("think", values) is { } thinkRoute)
        {
            return new Decision(thinkRoute, "think", null);
        }

        return new Decision(defaultRoute, "default", null);
    }

    private static bool TokenSaverCanRoute(Dictionary<string, string> values)
    {
        var enabled = values.GetValueOrDefault("router.tokenSaver.enabled")?.Trim().ToLowerInvariant();
        if (enabled is "false" or "0" or "no") return false;
        if (enabled is "true" or "1" or "yes") return true;
        return values.Keys.Any(key => key.StartsWith("router.tokenSaver.tiers.", StringComparison.Ordinal) &&
                                      key.EndsWith(".model", StringComparison.Ordinal));
    }

    private static string? MainEntryId(Dictionary<string, string> values)
    {
        var configured = Values.TryGetNonBlank(values, "agents.main.model");
        if (HasModelEntry(values, configured)) return configured;
        return HasModelEntry(values, "default") ? "default" : null;
    }

    private static string? RouteEntryId(string route, Dictionary<string, string> values)
    {
        var candidate = Values.TryGetNonBlank(values, $"router.routes.{route}.model") ??
                        Values.TryGetNonBlank(values, $"router.{route}");
        return HasModelEntry(values, candidate) ? candidate : null;
    }

    private static bool HasModelEntry(Dictionary<string, string> values, string? entryId) =>
        !string.IsNullOrWhiteSpace(entryId) &&
        values.ContainsKey($"models.entries.{entryId.Trim()}.provider");

    private static int LongContextThreshold(Dictionary<string, string> values) =>
        Values.TryGetInt(values, "router.routes.longContextThreshold") ??
        Values.TryGetInt(values, "router.longContextThreshold") ??
        60_000;

    private static bool IsEnabled(string? rawValue)
    {
        var value = rawValue?.Trim().ToLowerInvariant();
        return value is "true" or "1" or "yes";
    }

    private static int EstimatedTokens(string? text) =>
        Math.Max(0, (text ?? "").Length / 4);

    private static int EstimatedTokens(ChatMessage message)
    {
        var content = message.PlainText.Trim();
        return string.IsNullOrEmpty(content)
            ? 0
            : PerMessageOverhead + EstimatedTokens(content);
    }

    private static int EstimatedTools(IReadOnlyList<Dictionary<string, object?>> tools)
    {
        var total = 0;
        foreach (var tool in tools)
        {
            if (tool.TryGetValue("function", out var functionValue) &&
                functionValue is Dictionary<string, object?> function)
            {
                total += EstimatedTokens(function.GetValueOrDefault("name")?.ToString());
                total += EstimatedTokens(function.GetValueOrDefault("description")?.ToString());
                total += EstimatedSerialized(function.GetValueOrDefault("parameters"));
            }
            else
            {
                total += EstimatedSerialized(tool);
            }
        }

        return total;
    }

    private static int EstimatedSerialized(object? value) =>
        value switch
        {
            null => 0,
            string text => EstimatedTokens(text),
            Dictionary<string, object?> dict => Math.Max(1, dict.Sum(item => EstimatedTokens(item.Key) + EstimatedSerialized(item.Value))),
            IReadOnlyDictionary<string, object?> dict => Math.Max(1, dict.Sum(item => EstimatedTokens(item.Key) + EstimatedSerialized(item.Value))),
            IEnumerable<object?> values => Math.Max(1, values.Sum(EstimatedSerialized)),
            _ => EstimatedTokens(value.ToString()),
        };

    private static string UserContentForEstimate(string prompt, IReadOnlyList<FileAttachment> attachments)
    {
        if (attachments.Count == 0) return prompt;

        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(prompt))
        {
            parts.Add(prompt);
        }

        foreach (var attachment in attachments)
        {
            parts.Add(AttachmentEstimateText(attachment));
        }

        return string.Join('\n', parts);
    }

    private static string AttachmentEstimateText(FileAttachment attachment)
    {
        if (attachment.IsImage)
        {
            return new string('i', MultimediaTokens * 4);
        }

        if (attachment.IsTextLike && File.Exists(attachment.Path))
        {
            try
            {
                var text = File.ReadAllText(attachment.Path);
                if (!string.IsNullOrWhiteSpace(text))
                {
                    return $"<attachment path=\"{attachment.Path}\">\n{text[..Math.Min(text.Length, 30_000)]}\n</attachment>";
                }
            }
            catch
            {
            }
        }

        return $"{attachment.FileName} {attachment.MimeType ?? "file"} {attachment.Bytes} {attachment.Path}";
    }
}

public static class NativeRoutingClassifier
{
    public static string ClassifyTier(string prompt, ChatRunMode runMode)
    {
        if (runMode == ChatRunMode.Plan) return "REASONING";

        var normalized = (prompt ?? "").Trim().ToLowerInvariant();
        var words = normalized.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < 20 && !ContainsAny(normalized,
                "修改", "优化", "实现", "生成", "创建", "网页", "网站", "代码",
                "edit", "fix", "build", "implement", "website", "code"))
        {
            return "SIMPLE";
        }

        if (ContainsAny(normalized,
                "架构", "重构", "全量", "复杂", "深入", "推理", "research", "architecture", "refactor", "reasoning"))
        {
            return "REASONING";
        }

        if (ContainsAny(normalized,
                "修改", "优化", "实现", "生成", "创建", "网页", "网站", "多文件",
                "edit", "fix", "build", "implement", "website", "multi-file"))
        {
            return "COMPLEX";
        }

        return "MEDIUM";
    }

    private static bool ContainsAny(string value, params string[] needles) =>
        needles.Any(value.Contains);
}

public static class LegacyConfigLoader
{
    public static LegacyConfigSnapshot? LoadDefaultConfig(string? path = null)
    {
        var native = NativeConfigService.LoadDefaultConfig(path);
        return native is null ? null : LegacySnapshot(native);
    }

    public static LegacyConfigSnapshot? Snapshot(string yaml)
    {
        var native = NativeConfigService.Snapshot(yaml);
        return native is null ? null : LegacySnapshot(native);
    }

    public static Dictionary<string, string> ScalarMap(string yaml) => NativeConfigService.ScalarMap(yaml);

    private static LegacyConfigSnapshot LegacySnapshot(NativeConfigSnapshot native) => new(
        native.ProviderConfig.BaseUrl,
        native.ProviderConfig.Model,
        native.ApiKey,
        native.WorkspacesRoot,
        native.GeneralWorkspacePath);
}

internal static class Values
{
    private const string MaskedSecret = "********";

    public static string? TryGetNonBlank(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? FirstNonBlank(value) : null;

    public static int? TryGetInt(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) && int.TryParse(value, out var parsed) ? parsed : null;

    public static string? FirstNonBlank(params string?[] values)
    {
        foreach (var value in values)
        {
            if (!string.IsNullOrWhiteSpace(value)) return value.Trim();
        }

        return null;
    }

    public static string? FirstNonMasked(params string?[] values)
    {
        foreach (var value in values)
        {
            var trimmed = value?.Trim();
            if (string.IsNullOrWhiteSpace(trimmed) || trimmed == MaskedSecret) continue;
            return trimmed;
        }

        return null;
    }
}
