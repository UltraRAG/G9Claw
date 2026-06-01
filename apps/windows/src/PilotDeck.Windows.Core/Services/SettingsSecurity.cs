namespace PilotDeck.Windows.Core;

public static class SettingsSecurity
{
    public static string MaskSecret(string? secret)
    {
        if (string.IsNullOrWhiteSpace(secret)) return "";
        var trimmed = secret.Trim();
        if (trimmed.Length <= 8) return new string('*', trimmed.Length);
        return $"{trimmed[..4]}...{trimmed[^4..]}";
    }

    public static AppSettings MergeLegacyConfig(AppSettings current, NativeConfigSnapshot nativeConfig)
    {
        return AppState.NormalizeSettings(current with
        {
            ProviderConfig = nativeConfig.ProviderConfig,
            WorkspacesRoot = nativeConfig.WorkspacesRoot ?? current.WorkspacesRoot,
            GeneralWorkspacePath = nativeConfig.GeneralWorkspacePath ?? current.GeneralWorkspacePath,
            ApiTimeoutMs = nativeConfig.ApiTimeoutMs,
            ContextWindow = nativeConfig.ContextWindow,
            Providers = [NativeProviderEntry.FromProviderConfig(nativeConfig.ProviderConfig)],
            ModelEntries = [NativeModelEntry.FromProviderConfig(nativeConfig.ProviderConfig)],
            AgentSettings = NativeAgentSettings.Defaults,
            RuntimeSettings = new NativeRuntimeSettings(
                nativeConfig.WorkspacesRoot ?? current.WorkspacesRoot,
                nativeConfig.GeneralWorkspacePath ?? current.GeneralWorkspacePath,
                nativeConfig.ApiTimeoutMs,
                nativeConfig.ContextWindow,
                current.RuntimeSettings?.DatabasePath ?? NativeRuntimeSettings.Defaults(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).DatabasePath),
        });
    }
}
