using System;
using System.IO;

namespace PilotDeck.Windows.Core;

public static class ProjectCreationWizardMetrics
{
    public const double MaxWidth = 612;
    public const double FormMaxWidth = 520;
    public const double HeaderHeight = 58;
    public const double ContentMinHeight = 268;
    public const double ContentPadding = 24;
    public const double FooterHeight = 54;
    public const double FieldHeight = 36;
    public const double BrowseButtonWidth = 44;
    public const double TypeCardMinHeight = 104;
}

public enum ProjectCreationMode
{
    Existing,
    New,
}

public sealed record ProjectCreationValidation(bool Valid, string? ResolvedPath, string? Error);

public static class ProjectCreationWizardPolicy
{
    public static ProjectCreationValidation ValidateWorkspace(
        WorkspaceService workspaceService,
        ProjectCreationMode mode,
        string requestedPath,
        Func<string, bool>? directoryExists = null)
    {
        var validation = workspaceService.ValidateWorkspacePath(requestedPath);
        if (!validation.Valid || validation.ResolvedPath is null)
        {
            return new ProjectCreationValidation(false, null, validation.Error);
        }

        var exists = directoryExists ?? Directory.Exists;
        if (mode == ProjectCreationMode.Existing && !exists(validation.ResolvedPath))
        {
            return new ProjectCreationValidation(false, validation.ResolvedPath, "Selected existing project folder does not exist.");
        }

        return new ProjectCreationValidation(true, validation.ResolvedPath, null);
    }

    public static string DisplayNameOrFolder(string? displayName, string resolvedPath)
    {
        if (!string.IsNullOrWhiteSpace(displayName))
        {
            return displayName.Trim();
        }

        var folder = Path.GetFileName(resolvedPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        return string.IsNullOrWhiteSpace(folder) ? "workspace" : folder;
    }

    public static void EnsureDirectory(ProjectCreationMode mode, string resolvedPath)
    {
        if (mode == ProjectCreationMode.New)
        {
            Directory.CreateDirectory(resolvedPath);
        }
    }
}

public static class PlanConfirmationCardMetrics
{
    public const double PlanMinHeight = 220;
    public const double PlanMaxHeight = 460;
    public const double PlanViewportReserve = 420;
    public const double PlanBadgeTopPadding = 42;
    public const string ActionLayout = "execute-feedback-footer";
    public const double ActionRowHeight = 38;
    public const int FooterButtonCount = 2;
    public const string EmptyPlanFallbackZH = "\u8ba1\u5212\u4ecd\u5728\u540c\u6b65\uff0c\u8bf7\u7a0d\u5019\u3002";
    public const string EmptyPlanFallbackEN = "The plan is still syncing. Please wait.";

    public static double MaxPlanHeightForViewport(double viewportHeight) =>
        Math.Clamp(Math.Max(PlanMinHeight, viewportHeight - PlanViewportReserve), PlanMinHeight, PlanMaxHeight);
}

public static class EditorHeaderToolbarMetrics
{
    public const double IconButtonSize = 28;
    public const double IconFontSize = 13.5;
    public const bool UsesProminentSaveButton = false;
}

public static class InteractiveCardMetrics
{
    public const bool UsesOpaqueV2Surface = true;
    public const double SpinnerHostSize = 18;
    public const double SpinnerRingSize = 12;
    public const double PermissionActionMinWidth = 92;
}

public sealed record ComposerSendEligibility(
    bool CanSubmit,
    bool CanRunAgent,
    string Reason)
{
    public bool OpensLocalConfigurationError => CanSubmit && !CanRunAgent;
}

public static class ComposerSendEligibilityPolicy
{
    public const string Ready = "ready";
    public const string ProviderNotConfigured = "provider-not-configured";
    public const string Busy = "busy";
    public const string ReadOnly = "read-only";
    public const string Empty = "empty";
    public const string NoProject = "no-project";

    public static ComposerSendEligibility Evaluate(
        ProjectSession? selectedSession,
        bool hasSelectedProject,
        string? composerText,
        int attachmentCount,
        bool isAgentBusy,
        bool isAgentModelConfigured)
    {
        if (isAgentBusy) return new ComposerSendEligibility(false, false, Busy);
        if (AppState.IsReadOnlyBackgroundSession(selectedSession)) return new ComposerSendEligibility(false, false, ReadOnly);
        if (string.IsNullOrWhiteSpace(composerText) && attachmentCount <= 0) return new ComposerSendEligibility(false, false, Empty);
        if (!hasSelectedProject) return new ComposerSendEligibility(false, false, NoProject);

        return new ComposerSendEligibility(
            true,
            isAgentModelConfigured,
            isAgentModelConfigured ? Ready : ProviderNotConfigured);
    }
}

public enum MacStyleWindowCommand
{
    Close,
    Minimize,
    ToggleMaximize,
}

public enum WindowControlCommand
{
    Minimize,
    ToggleMaximize,
    Close,
}

public static class WindowControlMetrics
{
    public const double IconSize = 13;
    public const double HitSize = 28;
    public const double LeadingMargin = 12;
    public const double TopMargin = 10;
    public const double ButtonGap = 8;
    public static readonly IReadOnlyList<WindowControlCommand> CommandOrder =
    [
        WindowControlCommand.Minimize,
        WindowControlCommand.ToggleMaximize,
        WindowControlCommand.Close,
    ];

    public static bool IsWithinControls(double x, double y)
    {
        var width = HitSize * 3 + ButtonGap * 2;
        return x >= LeadingMargin &&
            x <= LeadingMargin + width &&
            y >= TopMargin &&
            y <= TopMargin + HitSize;
    }
}

public static class MacStyleWindowControlMetrics
{
    public const double ButtonSize = WindowControlMetrics.IconSize;
    public const double HitSize = WindowControlMetrics.HitSize;
    public const double LeadingMargin = WindowControlMetrics.LeadingMargin;
    public const double TopMargin = WindowControlMetrics.TopMargin;
    public const double ButtonGap = WindowControlMetrics.ButtonGap;

    public static bool IsWithinControls(double x, double y) =>
        WindowControlMetrics.IsWithinControls(x, y);
}

public sealed record SettingsWindowMetrics(double AvailableWidth, double AvailableHeight)
{
    public const double DefaultWidth = 920;
    public const double DefaultHeight = 720;
    public const double MinWidth = 760;
    public const double MinHeight = 560;
    public const double MaxWidth = 1040;

    public double Width => Math.Clamp(DefaultWidth, MinWidth, Math.Max(MinWidth, AvailableWidth));
    public double Height => Math.Clamp(DefaultHeight, MinHeight, Math.Max(MinHeight, AvailableHeight));
    public double ContentWidth => Math.Min(MaxWidth, Math.Max(0, Width));
    public double SideInset => Math.Min(40, Math.Max(24, Width * 0.045));
}
