namespace PilotDeck.Windows.Core;

public enum SettingsMainTab
{
    Appearance,
    Permissions,
    Config,
    Mcp,
}

public enum SettingsConfigSection
{
    Runtime,
    Models,
    Agents,
    AlwaysOn,
    Memory,
    Rag,
    Router,
    Gateway,
}

public enum SettingsConfigViewMode
{
    Form,
    RawYaml,
}

public sealed class SettingsOverlayViewModel
{
    public SettingsMainTab ActiveTab { get; set; } = SettingsMainTab.Appearance;
    public SettingsConfigSection ActiveConfigSection { get; set; } = SettingsConfigSection.Runtime;
    public SettingsConfigViewMode ConfigViewMode { get; set; } = SettingsConfigViewMode.Form;
    public NativeSettingsDraft Draft { get; set; }
    public string RawConfigText { get; set; }
    public List<string> ValidationErrors { get; } = [];
    public string Banner { get; set; } = "";
    public List<SettingsReloadSubsystemStatus> ReloadStatuses { get; set; } = SettingsReloadSubsystemStatus.Defaults();

    public SettingsOverlayViewModel(AppSettings settings, string apiKey)
    {
        Draft = NativeSettingsDraft.From(settings, apiKey);
        RawConfigText = string.IsNullOrWhiteSpace(settings.RawConfigDocument?.LastYaml)
            ? NativeConfigYamlCodec.ToYaml(settings)
            : settings.RawConfigDocument!.LastYaml;
    }
}

public sealed record SettingsReloadSubsystemStatus(string Id, string Label, string State, string Detail)
{
    public static List<SettingsReloadSubsystemStatus> Defaults() =>
    [
        new("settings", "Settings", "reloaded", "Local settings document refreshed."),
        new("workspace", "Workspace", "reloaded", "Workspace service will use the saved roots."),
        new("agent", "Agent runtime", "reloaded", "Provider, model, permissions, and runtime limits refreshed."),
        new("router", "Router", "reloaded", "Routing settings and cost estimates refreshed."),
        new("memory", "Memory", "reloaded", "Memory feature switch refreshed."),
        new("gateway", "Gateway", "reloaded", "Gateway switch refreshed; no localhost server is started."),
        new("server", "Server", "skipped", "Native Windows does not start an Express server."),
        new("proxy", "Proxy", "skipped", "Native Windows does not start a local proxy."),
    ];
}
