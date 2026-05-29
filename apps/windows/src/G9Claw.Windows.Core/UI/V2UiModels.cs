namespace G9Claw.Windows.Core;

public enum SidebarSection
{
    Projects,
    General,
}

public sealed record V2UiSettings(
    double SidebarWidth,
    SidebarSection SidebarSection,
    List<string> ExpandedProjectNames,
    List<string> CollapsedSessionProjectNames,
    string LastProjectId = "")
{
    public const double SidebarMinWidth = V2LayoutMetrics.SidebarMinWidth;
    public const double SidebarDefaultWidth = V2LayoutMetrics.SidebarWidth;
    public const double SidebarMaxWidth = V2LayoutMetrics.SidebarMaxWidth;
    public const double HeaderHeight = V2LayoutMetrics.HeaderHeight;

    public static V2UiSettings Defaults => new(
        SidebarDefaultWidth,
        SidebarSection.Projects,
        [],
        []);

    public V2UiSettings Normalize() => this with
    {
        SidebarWidth = Math.Clamp(SidebarWidth, SidebarMinWidth, SidebarMaxWidth),
        ExpandedProjectNames = ExpandedProjectNames ?? [],
        CollapsedSessionProjectNames = CollapsedSessionProjectNames ?? [],
        LastProjectId = LastProjectId ?? "",
    };

    public V2UiSettings NormalizeForStartup()
    {
        var normalized = Normalize();
        return normalized.SidebarWidth > 360
            ? normalized with { SidebarWidth = SidebarDefaultWidth }
            : normalized;
    }
}

public sealed record V2TabDescriptor(AppTab Tab, string Id, string Label, string IconKey);

public static class AppTabCatalog
{
    public static readonly IReadOnlyList<AppTab> PrimaryTabs =
    [
        AppTab.Chat,
        AppTab.Files,
        AppTab.Skills,
        AppTab.Dashboard,
        AppTab.Memory,
        AppTab.AlwaysOn,
    ];

    public static readonly IReadOnlyList<V2TabDescriptor> PrimaryTabDescriptors =
    [
        new(AppTab.Chat, "chat", "Agent", "Bot"),
        new(AppTab.Files, "files", "Files", "Folder"),
        new(AppTab.Skills, "skills", "Skills", "Sparkles"),
        new(AppTab.Dashboard, "dashboard", "Routing", "BarChart3"),
        new(AppTab.Memory, "memory", "Memory", "Database"),
        new(AppTab.AlwaysOn, "always-on", "Always-on", "Radio"),
    ];

    public static string Label(AppTab tab) => tab switch
    {
        AppTab.Chat => "Agent",
        AppTab.Files => "Files",
        AppTab.Skills => "Skills",
        AppTab.Dashboard => "Routing",
        AppTab.Memory => "Memory",
        AppTab.AlwaysOn => "Always-on",
        AppTab.Shell => "Shell",
        AppTab.Git => "Git",
        AppTab.Tasks => "Tasks",
        AppTab.Preview => "Preview",
        _ => tab.ToString(),
    };

    public static bool IsPrimary(AppTab tab) => PrimaryTabs.Contains(tab);
}

public sealed record MainHeaderToolSwitcherLayout(
    IReadOnlyList<AppTab> VisibleTabs,
    IReadOnlyList<AppTab> OverflowTabs,
    bool IconOnly,
    double EstimatedWidth)
{
    public const double ItemSpacing = 2;
    public const double ContainerPadding = 3;
    public const double ContainerVerticalPadding = 2;
    public const double ContainerHeight = V2LayoutMetrics.HeaderTabsHeight;
    public const double ContainerCornerRadius = ContainerHeight / 2;
    public const double ButtonHeight = 28;
    private const double RegularButtonWidth = 82;
    private const double IconButtonWidth = 36;

    public static MainHeaderToolSwitcherLayout Resolve(
        double availableWidth,
        AppTab activeTab,
        IEnumerable<AppTab>? tabs = null)
    {
        _ = activeTab;
        var allTabs = UniqueTabs(tabs ?? AppTabCatalog.PrimaryTabs);
        if (allTabs.Count == 0)
        {
            return new MainHeaderToolSwitcherLayout([], [], false, 0);
        }

        var fullWidth = EstimatedWidthFor(allTabs, [], iconOnly: false);
        var compactWidth = EstimatedWidthFor(allTabs, [], iconOnly: true);
        var iconOnly = availableWidth < fullWidth + 160;

        return new MainHeaderToolSwitcherLayout(
            allTabs,
            [],
            iconOnly,
            iconOnly ? compactWidth : fullWidth);
    }

    public static double ButtonWidth(AppTab tab, bool iconOnly)
    {
        if (iconOnly) return IconButtonWidth;
        return tab == AppTab.AlwaysOn ? 118 : RegularButtonWidth;
    }

    private static double EstimatedWidthFor(IReadOnlyList<AppTab> visible, IReadOnlyList<AppTab> overflow, bool iconOnly)
    {
        var buttonWidth = visible.Sum(tab => ButtonWidth(tab, iconOnly));
        var itemCount = visible.Count + (overflow.Count == 0 ? 0 : 1);
        var spacing = Math.Max(0, itemCount - 1) * ItemSpacing;
        const double overflowWidth = 0;
        return ContainerPadding * 2 + buttonWidth + overflowWidth + spacing;
    }

    private static IReadOnlyList<AppTab> UniqueTabs(IEnumerable<AppTab> tabs)
    {
        var seen = new HashSet<AppTab>();
        return tabs
            .Where(tab => seen.Add(tab))
            .ToList();
    }
}

public enum NativeAppearanceSection
{
    ColorScheme,
    Language,
    ToolDisplay,
    ViewOptions,
    InputSettings,
    ProjectSorting,
    CodeEditor,
}

public static class NativeAppearanceSettingsLayout
{
    public static readonly IReadOnlyList<NativeAppearanceSection> SectionOrder =
    [
        NativeAppearanceSection.ColorScheme,
        NativeAppearanceSection.Language,
        NativeAppearanceSection.ToolDisplay,
        NativeAppearanceSection.ViewOptions,
        NativeAppearanceSection.InputSettings,
        NativeAppearanceSection.ProjectSorting,
        NativeAppearanceSection.CodeEditor,
    ];

    public const bool UsesDarkModeToggle = false;
    public const bool UsesThemePicker = true;
    public const double ColorSchemePickerWidth = 160;
    public const double LanguagePickerWidth = 160;
    public const double ProjectSortingPickerWidth = 160;
    public static readonly IReadOnlyList<int> FontSizeOptions = [10, 11, 12, 13, 14, 15, 16, 18, 20];
}

public sealed record SidebarSessionRow(
    WorkspaceProject Project,
    ProjectSession Session,
    SessionProvider Provider,
    DateTimeOffset ActivityDate);

public static class V2SidebarProjection
{
    public static bool IsGeneralProject(WorkspaceProject project) =>
        string.Equals(project.Name, "general", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(project.DisplayName, "general", StringComparison.OrdinalIgnoreCase);

    public static WorkspaceProject? GeneralProject(IEnumerable<WorkspaceProject> projects) =>
        projects.FirstOrDefault(IsGeneralProject);

    public static IReadOnlyList<WorkspaceProject> ProjectSection(
        IEnumerable<WorkspaceProject> projects,
        ProjectSortOrder sortOrder)
    {
        var all = projects.ToList();
        var general = GeneralProject(all);
        var nonGeneral = general is null ? all : all.Where(project => !ReferenceEquals(project, general));
        return WorkspaceService.SortedProjects(nonGeneral, sortOrder);
    }

    public static IReadOnlyList<SidebarSessionRow> SessionRows(WorkspaceProject project) =>
        project.AllSessions
            .Select(session => new SidebarSessionRow(project, session, session.Provider, session.ActivityDate))
            .OrderByDescending(row => row.ActivityDate)
            .ToList();

    public static SessionState SessionIndicatorState(ProjectSession session, ISet<string> processingSessionIds, ISet<string> unreadSessionIds)
    {
        if (processingSessionIds.Contains(session.Id)) return SessionState.Processing;
        if (unreadSessionIds.Contains(session.Id)) return SessionState.Unread;
        return session.State;
    }
}

public static class SidebarProjectRestorationPolicy
{
    public static WorkspaceProject? PreferredProject(
        IEnumerable<WorkspaceProject> projects,
        string? lastProjectIdRaw)
    {
        var projectList = projects.ToList();
        if (Guid.TryParse(lastProjectIdRaw, out var lastProjectId))
        {
            var remembered = projectList.FirstOrDefault(project => project.Id == lastProjectId);
            if (remembered is not null) return remembered;
        }

        return projectList.FirstOrDefault();
    }
}

public static class ChatEmptyStatePresentation
{
    public const string DefaultTitleKey = "chat.empty.title";
    public const string ProjectTitleKey = "chat.empty.projectTitle";

    public static string TitleKey(WorkspaceProject? selectedProject) =>
        selectedProject is not null && !V2SidebarProjection.IsGeneralProject(selectedProject)
            ? ProjectTitleKey
            : DefaultTitleKey;
}

public static class GeneralProjectEntryPresentation
{
    public static bool ShouldRender(WorkspaceProject? selectedProject) =>
        selectedProject is not null && V2SidebarProjection.IsGeneralProject(selectedProject);

    public static IReadOnlyList<WorkspaceProject> Projects(
        IEnumerable<WorkspaceProject> projects,
        ProjectSortOrder sortOrder) =>
        V2SidebarProjection.ProjectSection(projects, sortOrder);

    public static IReadOnlyList<WorkspaceProject> FilteredProjects(
        IEnumerable<WorkspaceProject> projects,
        string? query)
    {
        var projectList = projects.ToList();
        var trimmed = query?.Trim() ?? "";
        if (trimmed.Length == 0) return projectList;
        return projectList
            .Where(project =>
                project.DisplayName.Contains(trimmed, StringComparison.OrdinalIgnoreCase) ||
                project.RootPath.Contains(trimmed, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }
}
