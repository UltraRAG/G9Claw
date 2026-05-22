using System.Text.Json;
using System.Text.Json.Serialization;

namespace G9Claw.Windows.Core;

public sealed class AppSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    static AppSettingsStore()
    {
        JsonOptions.Converters.Add(new JsonStringEnumConverter());
    }

    private readonly string _settingsFile;

    public AppSettingsStore(string? settingsFile = null)
    {
        _settingsFile = settingsFile ?? AppPaths.Current().SettingsFile;
    }

    public async Task<AppSettings?> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_settingsFile)) return null;
        await using var stream = File.OpenRead(_settingsFile);
        var settings = await JsonSerializer.DeserializeAsync<AppSettings>(stream, JsonOptions, cancellationToken);
        return settings is null ? null : AppState.NormalizeSettings(settings);
    }

    public async Task SaveAsync(AppSettings settings, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsFile)!);
        await using var stream = File.Create(_settingsFile);
        await JsonSerializer.SerializeAsync(stream, AppState.NormalizeSettings(settings), JsonOptions, cancellationToken);
    }
}
