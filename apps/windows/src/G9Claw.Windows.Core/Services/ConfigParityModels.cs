using System.Globalization;
using System.Text.Json;

namespace G9Claw.Windows.Core;

public sealed record CodeEditorPreferences(
    bool WordWrap,
    bool ShowMinimap,
    bool LineNumbers,
    int FontSize)
{
    public static CodeEditorPreferences Defaults => new(
        WordWrap: false,
        ShowMinimap: true,
        LineNumbers: true,
        FontSize: 14);
}

public static class PermissionsExportDefaults
{
    public const string Source = "g9claw";

    public static string Filename(DateTimeOffset date)
    {
        var utc = date.ToUniversalTime();
        return $"g9claw-permissions-{utc.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)}.json";
    }
}

public enum G9ClawConfigSection
{
    Runtime,
    Models,
    AlwaysOn,
    Memory,
    Rag,
    Router,
    Gateway,
    Raw,
}

public static class G9ClawConfigSectionExtensions
{
    public static string Id(this G9ClawConfigSection section) => section switch
    {
        G9ClawConfigSection.AlwaysOn => "alwaysOn",
        G9ClawConfigSection.Rag => "rag",
        _ => section.ToString()[..1].ToLowerInvariant() + section.ToString()[1..],
    };

    public static string Label(this G9ClawConfigSection section) => section switch
    {
        G9ClawConfigSection.Runtime => "Runtime",
        G9ClawConfigSection.Models => "Models",
        G9ClawConfigSection.AlwaysOn => "Always-On",
        G9ClawConfigSection.Memory => "Memory",
        G9ClawConfigSection.Rag => "RAG",
        G9ClawConfigSection.Router => "Router",
        G9ClawConfigSection.Gateway => "Gateway",
        G9ClawConfigSection.Raw => "Raw YAML",
        _ => section.ToString(),
    };
}

public sealed record WorkspaceContext(
    Guid? ProjectId,
    string ProjectName,
    string DisplayName,
    string RootPath,
    bool IsGeneral);

public static class ComposerPermissionModeStorage
{
    public const string DefaultKey = ComposerPermissionModeCatalog.DefaultStorageKey;
    public const string SessionKeyPrefix = ComposerPermissionModeCatalog.SessionStorageKeyPrefix;

    public static ComposerPermissionMode StoredMode(string? sessionId, IReadOnlyDictionary<string, string> values)
    {
        if (!string.IsNullOrWhiteSpace(sessionId) &&
            values.TryGetValue($"{SessionKeyPrefix}{sessionId}", out var sessionValue))
        {
            return ComposerPermissionModeCatalog.FromId(sessionValue);
        }

        return values.TryGetValue(DefaultKey, out var defaultValue)
            ? ComposerPermissionModeCatalog.FromId(defaultValue)
            : ComposerPermissionMode.Default;
    }

    public static Dictionary<string, string> Save(
        ComposerPermissionMode mode,
        string? sessionId,
        IReadOnlyDictionary<string, string>? existing = null)
    {
        var next = existing is null
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(existing, StringComparer.Ordinal);
        next[DefaultKey] = mode.Id();
        if (!string.IsNullOrWhiteSpace(sessionId))
        {
            next[$"{SessionKeyPrefix}{sessionId}"] = mode.Id();
        }

        return next;
    }
}

public static class NativeUIPreferencesStorage
{
    public const string StorageKey = "uiPreferences";

    public static NativeUIPreferences StoredPreferences(IReadOnlyDictionary<string, string> values)
    {
        if (values.TryGetValue(StorageKey, out var raw) && PreferencesFromJson(raw) is { } parsed)
        {
            return parsed;
        }

        var defaults = new NativeUIPreferences();
        return defaults with
        {
            AutoExpandTools = Bool(values.GetValueOrDefault("autoExpandTools"), defaults.AutoExpandTools),
            ShowRawParameters = Bool(values.GetValueOrDefault("showRawParameters"), defaults.ShowRawParameters),
            ShowThinking = Bool(values.GetValueOrDefault("showThinking"), defaults.ShowThinking),
            AutoScrollToBottom = Bool(values.GetValueOrDefault("autoScrollToBottom"), defaults.AutoScrollToBottom),
            SendByCtrlEnter = Bool(values.GetValueOrDefault("sendByCtrlEnter"), defaults.SendByCtrlEnter),
            SidebarVisible = Bool(values.GetValueOrDefault("sidebarVisible"), defaults.SidebarVisible),
        };
    }

    public static string Save(NativeUIPreferences preferences)
    {
        var values = new SortedDictionary<string, bool>
        {
            ["autoExpandTools"] = preferences.AutoExpandTools,
            ["showRawParameters"] = preferences.ShowRawParameters,
            ["showThinking"] = preferences.ShowThinking,
            ["autoScrollToBottom"] = preferences.AutoScrollToBottom,
            ["sendByCtrlEnter"] = preferences.SendByCtrlEnter,
            ["sidebarVisible"] = preferences.SidebarVisible,
        };
        return JsonSerializer.Serialize(values);
    }

    public static string SaveSidebarVisible(
        bool visible,
        IReadOnlyDictionary<string, string> values)
    {
        var preferences = StoredPreferences(values) with { SidebarVisible = visible };
        return Save(preferences);
    }

    private static NativeUIPreferences? PreferencesFromJson(string raw)
    {
        try
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(raw);
            if (values is null) return null;
            var defaults = new NativeUIPreferences();
            return defaults with
            {
                AutoExpandTools = Bool(values.GetValueOrDefault("autoExpandTools"), defaults.AutoExpandTools),
                ShowRawParameters = Bool(values.GetValueOrDefault("showRawParameters"), defaults.ShowRawParameters),
                ShowThinking = Bool(values.GetValueOrDefault("showThinking"), defaults.ShowThinking),
                AutoScrollToBottom = Bool(values.GetValueOrDefault("autoScrollToBottom"), defaults.AutoScrollToBottom),
                SendByCtrlEnter = Bool(values.GetValueOrDefault("sendByCtrlEnter"), defaults.SendByCtrlEnter),
                SidebarVisible = Bool(values.GetValueOrDefault("sidebarVisible"), defaults.SidebarVisible),
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool Bool(string? value, bool fallback) => value?.Trim().ToLowerInvariant() switch
    {
        "true" => true,
        "false" => false,
        _ => fallback,
    };

    private static bool Bool(JsonElement value, bool fallback) => value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.String => Bool(value.GetString(), fallback),
        _ => fallback,
    };
}
