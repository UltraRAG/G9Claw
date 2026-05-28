namespace G9Claw.Windows.Core;

public static class ComposerAttachmentDeduper
{
    public static List<FileAttachment> Merged(
        IEnumerable<FileAttachment> existing,
        IEnumerable<FileAttachment> incoming)
    {
        var result = existing.ToList();
        var seen = new HashSet<string>(
            result.Select(StablePathKey),
            StringComparer.OrdinalIgnoreCase);

        foreach (var attachment in incoming)
        {
            if (!seen.Add(StablePathKey(attachment))) continue;
            result.Add(attachment);
        }

        return result;
    }

    public static string StablePathKey(FileAttachment attachment)
    {
        try
        {
            return Path.GetFullPath(attachment.Path)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch (Exception)
        {
            return attachment.Path.Trim();
        }
    }
}

public sealed record ComposerAttachmentPreviewModel(
    bool IsImage,
    string TypeLabel,
    string SystemImage,
    string AccentKind)
{
    public static ComposerAttachmentPreviewModel Make(FileAttachment attachment)
    {
        var extension = Path.GetExtension(attachment.Path).TrimStart('.').ToUpperInvariant();
        var typeLabel = !string.IsNullOrWhiteSpace(extension)
            ? extension
            : MimeTypeSuffix(attachment.MimeType) ?? "FILE";
        var lower = typeLabel.ToLowerInvariant();

        if (attachment.IsImage)
        {
            return new ComposerAttachmentPreviewModel(true, typeLabel, "photo", "image");
        }

        return lower switch
        {
            "pdf" => new ComposerAttachmentPreviewModel(false, typeLabel, "doc.richtext", "pdf"),
            "doc" or "docx" or "rtf" => new ComposerAttachmentPreviewModel(false, typeLabel, "doc.text", "document"),
            "xls" or "xlsx" or "csv" => new ComposerAttachmentPreviewModel(false, typeLabel, "tablecells", "spreadsheet"),
            "ppt" or "pptx" => new ComposerAttachmentPreviewModel(false, typeLabel, "rectangle.on.rectangle", "presentation"),
            "swift" or "js" or "ts" or "tsx" or "jsx" or "json" or "yaml" or "yml" or "py" or "rb" or "go" or "rs" or "html" or "css" or "xml"
                => new ComposerAttachmentPreviewModel(false, typeLabel, "chevron.left.forwardslash.chevron.right", "code"),
            _ => new ComposerAttachmentPreviewModel(false, typeLabel, "doc", "file"),
        };
    }

    private static string? MimeTypeSuffix(string? mimeType)
    {
        if (string.IsNullOrWhiteSpace(mimeType)) return null;
        var slash = mimeType.LastIndexOf('/');
        if (slash < 0 || slash == mimeType.Length - 1) return null;
        return mimeType[(slash + 1)..].ToUpperInvariant();
    }
}
