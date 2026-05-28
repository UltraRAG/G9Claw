using System.Collections;

namespace G9Claw.Windows.Core;

public static class SkillRuntimeEnvironment
{
    public static Dictionary<string, string> Build(
        IReadOnlyDictionary<string, string>? configValues,
        IReadOnlyDictionary<string, string>? baseEnvironment = null,
        string? pluginRoot = null)
    {
        var environment = new Dictionary<string, string>(
            baseEnvironment ?? ProcessEnvironment(),
            OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

        environment.Remove("CLAUDE_PLUGIN_ROOT");
        var resolvedPluginRoot = pluginRoot ?? PluginRoot();
        if (!string.IsNullOrWhiteSpace(resolvedPluginRoot))
        {
            environment["G9CLAW_PLUGIN_ROOT"] = resolvedPluginRoot;
        }

        var values = configValues ?? new Dictionary<string, string>();
        var ragValues = new Dictionary<string, string>
        {
            ["RAG_ENABLED"] = BoolEnvironmentValue(Get(values, "rag.enabled"), false),
            ["RAG_DISABLE_BUILTIN_WEB_TOOLS"] = BoolEnvironmentValue(Get(values, "rag.disableBuiltInWebTools"), true),
            ["RAG_LOCAL_KNOWLEDGE_BASE_URL"] = StripTrailingSlash(Get(values, "rag.localKnowledge.baseUrl")),
            ["RAG_LOCAL_KNOWLEDGE_API_KEY"] = Get(values, "rag.localKnowledge.apiKey") ?? "",
            ["RAG_LOCAL_KNOWLEDGE_MODEL_NAME"] = Get(values, "rag.localKnowledge.modelName") ?? "",
            ["RAG_LOCAL_KNOWLEDGE_DATABASE_URL"] =
                FirstNonBlank(Get(values, "rag.localKnowledge.databaseUrl"), Get(values, "rag.localKnowledge.milvusUri")),
            ["RAG_LOCAL_KNOWLEDGE_MILVUS_URI"] =
                FirstNonBlank(Get(values, "rag.localKnowledge.databaseUrl"), Get(values, "rag.localKnowledge.milvusUri")),
            ["RAG_LOCAL_KNOWLEDGE_TOP_K"] = FirstNonBlank(Get(values, "rag.localKnowledge.defaultTopK"), "8"),
            ["RAG_GLM_WEB_SEARCH_BASE_URL"] = StripTrailingSlash(Get(values, "rag.glmWebSearch.baseUrl")),
            ["RAG_GLM_WEB_SEARCH_API_KEY"] = Get(values, "rag.glmWebSearch.apiKey") ?? "",
            ["RAG_GLM_WEB_SEARCH_TOP_K"] = FirstNonBlank(Get(values, "rag.glmWebSearch.defaultTopK"), "8"),
        };

        foreach (var (key, value) in ragValues)
        {
            environment[$"G9CLAW_{key}"] = value;
        }

        return environment
            .Where(item => !string.IsNullOrWhiteSpace(item.Value))
            .ToDictionary(
                item => item.Key,
                item => item.Value,
                OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
    }

    public static string? PluginRoot()
    {
        var explicitRoot = Environment.GetEnvironmentVariable("G9CLAW_PLUGIN_ROOT");
        if (HasSkills(explicitRoot)) return PathHelpers.NormalizeFullPath(explicitRoot!);

        var repoRoot = Environment.GetEnvironmentVariable("G9CLAW_REPO_ROOT");
        if (!string.IsNullOrWhiteSpace(repoRoot))
        {
            var candidate = Path.Combine(
                PathHelpers.ExpandHome(repoRoot),
                "apps",
                "macos-native",
                "G9Claw",
                "Assets",
                "g9claw-rag-plugin");
            if (HasSkills(candidate)) return PathHelpers.NormalizeFullPath(candidate);
        }

        foreach (var root in CandidateSearchRoots())
        {
            foreach (var candidate in CandidatePluginRoots(root))
            {
                if (HasSkills(candidate)) return PathHelpers.NormalizeFullPath(candidate);
            }
        }

        return null;
    }

    private static IEnumerable<string> CandidateSearchRoots()
    {
        yield return Directory.GetCurrentDirectory();
        yield return AppContext.BaseDirectory;
    }

    private static IEnumerable<string> CandidatePluginRoots(string start)
    {
        var directory = new DirectoryInfo(PathHelpers.ExpandHome(start));
        while (directory is not null)
        {
            yield return Path.Combine(directory.FullName, "Assets", "g9claw-rag-plugin");
            yield return Path.Combine(directory.FullName, "apps", "macos-native", "G9Claw", "Assets", "g9claw-rag-plugin");
            directory = directory.Parent;
        }
    }

    private static bool HasSkills(string? path)
    {
        return !string.IsNullOrWhiteSpace(path) &&
               Directory.Exists(Path.Combine(PathHelpers.ExpandHome(path), "skills"));
    }

    private static Dictionary<string, string> ProcessEnvironment()
    {
        var environment = new Dictionary<string, string>(
            OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            if (entry.Key is string key && entry.Value is string value)
            {
                environment[key] = value;
            }
        }

        return environment;
    }

    private static string? Get(IReadOnlyDictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : null;

    private static string BoolEnvironmentValue(string? rawValue, bool defaultValue)
    {
        var value = rawValue?.Trim();
        if (string.IsNullOrEmpty(value)) return defaultValue ? "1" : "0";
        return value.ToLowerInvariant() switch
        {
            "true" or "1" or "yes" or "on" => "1",
            "false" or "0" or "no" or "off" => "0",
            _ => defaultValue ? "1" : "0",
        };
    }

    private static string StripTrailingSlash(string? rawValue)
    {
        var value = rawValue?.Trim();
        if (string.IsNullOrEmpty(value)) return "";
        while (value.Length > 1 && (value.EndsWith("/", StringComparison.Ordinal) || value.EndsWith("\\", StringComparison.Ordinal)))
        {
            value = value[..^1];
        }

        return value;
    }

    private static string FirstNonBlank(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? "";
}
