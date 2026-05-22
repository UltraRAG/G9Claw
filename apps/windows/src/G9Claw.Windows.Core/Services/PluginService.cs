using System.Text.Json;

namespace G9Claw.Windows.Core;

public sealed record PluginManifest(
    string Id,
    string Name,
    string Version,
    string Directory,
    bool Enabled,
    IReadOnlyList<string> Tabs,
    IReadOnlyList<string> Assets);

public sealed class PluginService
{
    private readonly string _pluginDirectory;

    public PluginService(string? pluginDirectory = null)
    {
        _pluginDirectory = pluginDirectory ?? AppPaths.Current().PluginsDirectory;
    }

    public IReadOnlyList<PluginManifest> Load()
    {
        if (!Directory.Exists(_pluginDirectory)) return [];
        return Directory.EnumerateFiles(_pluginDirectory, "plugin.json", SearchOption.AllDirectories)
            .Select(ReadManifest)
            .OrderBy(plugin => plugin.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public void SetEnabled(string pluginId, bool enabled)
    {
        var manifestPath = ManifestPath(pluginId);
        using var doc = JsonDocument.Parse(File.ReadAllText(manifestPath));
        var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(doc.RootElement.GetRawText()) ?? [];
        values["enabled"] = enabled;
        File.WriteAllText(manifestPath, JsonSerializer.Serialize(values, new JsonSerializerOptions { WriteIndented = true }));
    }

    public void Delete(string pluginId)
    {
        var manifestPath = ManifestPath(pluginId);
        Directory.Delete(Path.GetDirectoryName(manifestPath)!, recursive: true);
    }

    private string ManifestPath(string pluginId)
    {
        var manifest = Load().FirstOrDefault(plugin => plugin.Id == pluginId)
                       ?? throw new InvalidOperationException($"Plugin not found: {pluginId}");
        return Path.Combine(manifest.Directory, "plugin.json");
    }

    private static PluginManifest ReadManifest(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        var directory = Path.GetDirectoryName(path)!;
        var id = StringProperty(root, "id") ?? Path.GetFileName(directory);
        var tabs = ArrayProperty(root, "tabs");
        var assets = Directory.Exists(Path.Combine(directory, "assets"))
            ? Directory.EnumerateFiles(Path.Combine(directory, "assets"), "*", SearchOption.AllDirectories)
                .Select(asset => Path.GetRelativePath(directory, asset))
                .ToList()
            : [];

        return new PluginManifest(
            id,
            StringProperty(root, "name") ?? id,
            StringProperty(root, "version") ?? "0.0.0",
            directory,
            BoolProperty(root, "enabled") ?? true,
            tabs,
            assets);
    }

    private static string? StringProperty(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool? BoolProperty(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) ? value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        } : null;

    private static IReadOnlyList<string> ArrayProperty(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array) return [];
        return value.EnumerateArray().Select(item => item.ToString()).Where(item => !string.IsNullOrWhiteSpace(item)).ToList();
    }
}
