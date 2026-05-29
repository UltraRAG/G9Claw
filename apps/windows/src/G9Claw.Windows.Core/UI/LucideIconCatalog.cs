namespace G9Claw.Windows.Core;

public static class LucideIconCatalog
{
    public static IReadOnlySet<string> RequiredKeys { get; } = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "ArrowUp",
        "AtSign",
        "BarChart3",
        "Bot",
        "ChevronDown",
        "ChevronRight",
        "ChevronUp",
        "Chevrons",
        "CircleGauge",
        "Code",
        "Command",
        "Copy",
        "Database",
        "Document",
        "Download",
        "Edit",
        "Eye",
        "FileCog",
        "Folder",
        "FolderPlus",
        "GitBranch",
        "Hand",
        "LayoutList",
        "ListChecks",
        "MessageSquarePlus",
        "Palette",
        "PanelLeftClose",
        "PanelLeftOpen",
        "Paperclip",
        "Play",
        "Plus",
        "Radio",
        "Refresh",
        "Save",
        "Settings",
        "Shield",
        "Sparkles",
        "Square",
        "Terminal",
        "Trash",
        "Upload",
        "X",
    };

    public static IReadOnlySet<string> KnownKeys { get; } = new HashSet<string>(
        RequiredKeys.Concat(new[]
        {
            "AlertCircle",
            "BarChart",
            "CheckCircle",
            "doc.richtext",
            "File",
            "Gear",
            "globe",
            "Info",
            "Hammer",
            "Image",
            "pencil",
            "Stop",
            "XCircle",
            "checklist",
            "eye",
            "terminal",
        }),
        StringComparer.OrdinalIgnoreCase);

    public static bool HasIcon(string key) => KnownKeys.Contains(key);
}
