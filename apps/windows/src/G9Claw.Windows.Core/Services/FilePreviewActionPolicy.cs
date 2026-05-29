namespace G9Claw.Windows.Core;

public static class FilePreviewActionPolicy
{
    public static string? TreePreviewIcon(WorkspaceFile file) => file.IsHtml ? "globe" : null;

    public static bool EditorShowsHtmlPreview(WorkspaceFile file) => false;

    public static string? EditorPreviewToggleIcon(WorkspaceFile file, bool isPreviewing)
    {
        if (!file.IsMarkdown)
        {
            return null;
        }

        return isPreviewing ? "pencil" : "doc.richtext";
    }

    public static bool UsesNativePdfPreview(WorkspaceFile file) => file.IsPdf;
}
