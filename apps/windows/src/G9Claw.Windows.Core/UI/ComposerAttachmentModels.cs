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

public static class ComposerPasteTextPolicy
{
    public sealed record PlainPathAttachmentInfo(
        string Path,
        bool IsDirectory,
        long Bytes,
        string? MimeType);

    public static string? TextPayload(string? value, IReadOnlyList<FileAttachment> attachments)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;

        var attachmentValues = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var attachment in attachments)
        {
            foreach (var candidate in AttachmentTextValues(attachment))
            {
                var trimmed = candidate.Trim();
                if (!string.IsNullOrWhiteSpace(trimmed))
                {
                    attachmentValues.Add(trimmed);
                }
            }
        }

        var lines = SplitNonEmptyLines(value);

        if (attachmentValues.Count > 0 &&
            lines.Count > 0 &&
            lines.All(line => attachmentValues.Contains(line)))
        {
            return null;
        }

        return value;
    }

    public static List<FileAttachment> AttachmentsFromPlainFilePathText(
        string? value,
        Func<string, PlainPathAttachmentInfo?> resolvePath)
    {
        if (string.IsNullOrWhiteSpace(value)) return [];

        var lines = SplitNonEmptyLines(value);
        if (lines.Count == 0 || lines.Any(line => line.Contains("://", StringComparison.Ordinal)))
        {
            return [];
        }

        var attachments = new List<FileAttachment>();
        foreach (var line in lines)
        {
            var info = resolvePath(line);
            if (info is null)
            {
                return [];
            }

            var fileName = Path.GetFileName(info.Path);
            attachments.Add(new FileAttachment(
                info.Path,
                string.IsNullOrWhiteSpace(fileName) ? info.Path : fileName,
                info.IsDirectory ? "inode/directory" : info.MimeType,
                info.Bytes,
                AttachmentSourceKind.ClipboardFile));
        }

        return ComposerAttachmentDeduper.Merged([], attachments);
    }

    public static string AppendText(string existing, string text)
    {
        if (string.IsNullOrEmpty(text)) return existing;
        if (string.IsNullOrEmpty(existing)) return text;
        return char.IsWhiteSpace(existing[^1]) ? existing + text : existing + Environment.NewLine + text;
    }

    private static List<string> SplitNonEmptyLines(string value) =>
        value
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .ToList();

    private static IEnumerable<string> AttachmentTextValues(FileAttachment attachment)
    {
        yield return attachment.Path;
        yield return ComposerAttachmentDeduper.StablePathKey(attachment);
        yield return attachment.FileName;
        yield return Path.GetFileName(attachment.Path);

        var fullPath = ComposerAttachmentDeduper.StablePathKey(attachment);
        if (Path.IsPathFullyQualified(fullPath))
        {
            yield return new Uri(fullPath, UriKind.Absolute).AbsoluteUri;
        }
    }
}
