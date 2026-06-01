namespace PilotDeck.Windows.Core;

public static class V2LayoutMetrics
{
    public const double MinimumWindowWidth = 980;
    public const double MinimumWindowHeight = 640;
    public const double DefaultWindowWidth = 1280;
    public const double DefaultWindowHeight = 840;
    public const double SidebarWidth = 248;
    public const double SidebarMinWidth = 200;
    public const double SidebarMaxWidth = 320;
    public const double SidebarHeaderHeight = 52;
    public const double SidebarSegmentHeight = 28;
    public const double SidebarProjectRowHeight = 32;
    public const double SidebarFooterHeight = 54;
    public const double HeaderHeight = 44;
    public const double HeaderHorizontalPadding = 18;
    public const double HeaderTabsHeight = 32;
    public const double HeaderTabHeight = 28;
    public const double ChatColumnMaxWidth = 824;
    public const double ChatColumnHorizontalPadding = 20;
    public const double ComposerMaxWidth = 688;
    public const double ComposerMinHeight = 98;
    public const double ComposerTextBoxMinHeight = 54;
    public const double ComposerTextBoxMaxHeight = 180;
    public const double ComposerBottomPadding = 22;
    public const double ToolbarHeight = 54;
    public const double SettingsMaxWidth = 1080;
    public const double SettingsMaxHeightRatio = 0.90;
    public const double SettingsMinimumHeight = 420;
    public const double SettingsOuterMargin = 16;
    public const double SettingsHorizontalPadding = 40;
    public const double SettingsHeaderHeight = 56;
    public const double SettingsFooterHeight = 56;
    public const double SettingsSidebarWidth = 224;
}

public sealed record SettingsOverlayMetrics(double WindowWidth, double WindowHeight)
{
    public double ColumnWidth => Math.Max(0, WindowWidth);

    public double Width => ColumnWidth;

    public double SideInset => Math.Min(
        V2LayoutMetrics.SettingsHorizontalPadding,
        Math.Max(0, WindowWidth / 2));

    public double ContentWidth => Math.Max(0, ColumnWidth - SideInset * 2);

    public double Height
    {
        get
        {
            var available = Math.Max(0, WindowHeight - V2LayoutMetrics.SettingsOuterMargin * 2);
            if (available <= 0) return 0;
            return Math.Max(
                Math.Min(V2LayoutMetrics.SettingsMinimumHeight, available),
                Math.Min(WindowHeight * V2LayoutMetrics.SettingsMaxHeightRatio, available));
        }
    }
}

public static class RoutingDashboardLayoutMetrics
{
    public const bool RootStretchesToWindow = true;
    public const double MaxContentWidth = 1320;

    public static double ContentWidth(double availableWidth) =>
        Math.Min(MaxContentWidth, Math.Max(0, availableWidth));

    public static double SideInset(double availableWidth) =>
        Math.Max(0, (Math.Max(0, availableWidth) - ContentWidth(availableWidth)) / 2);
}

public enum SidebarToggleButtonDock
{
    SidebarHeaderRight,
    MainHeaderLeft,
}

public static class SidebarAnimationMetrics
{
    public const int DurationMs = 180;
    public const double CollapsedWidth = 0;

    public static double WidthAt(double startWidth, double endWidth, double progress)
    {
        var clamped = Math.Clamp(progress, 0, 1);
        var eased = 1 - Math.Pow(1 - clamped, 3);
        return startWidth + (endWidth - startWidth) * eased;
    }

    public static SidebarToggleButtonDock ToggleButtonDock(bool sidebarVisible) =>
        sidebarVisible ? SidebarToggleButtonDock.SidebarHeaderRight : SidebarToggleButtonDock.MainHeaderLeft;
}
