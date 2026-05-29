using System.Text;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace G9Claw.Windows.Core;

public enum AttachmentDiagnosticSeverity
{
    Info,
    Warning,
}

public sealed record AttachmentDiagnostic(AttachmentDiagnosticSeverity Severity, string Message);

public static class NativeAttachmentResolver
{
    public const long MaxTextBytes = 1_000_000;
    public const long MaxImageBytes = 8_000_000;
    public const int MaxTextCharacters = 30_000;
    public const int MaxPdfPages = 10;

    public static (List<Dictionary<string, object?>> Parts, List<AttachmentDiagnostic> Diagnostics) OpenAIContentParts(
        IReadOnlyList<FileAttachment> attachments)
    {
        var parts = new List<Dictionary<string, object?>>();
        var diagnostics = new List<AttachmentDiagnostic>();

        foreach (var attachment in attachments)
        {
            var resolved = Resolve(attachment);
            diagnostics.AddRange(resolved.Diagnostics);
            foreach (var block in resolved.Blocks)
            {
                parts.Add(block);
            }
        }

        var warnings = diagnostics.Where(item => item.Severity != AttachmentDiagnosticSeverity.Info).ToList();
        if (warnings.Count > 0)
        {
            parts.Add(TextPart("[Attachment diagnostics]\n" + string.Join('\n', warnings.Select(item => $"- {item.Message}"))));
        }

        return (parts, diagnostics);
    }

    public static string PromptWithAttachments(string prompt, IReadOnlyList<FileAttachment> attachments)
    {
        var trimmedPrompt = (prompt ?? "").Trim();
        if (attachments.Count == 0)
        {
            return string.IsNullOrWhiteSpace(trimmedPrompt) ? "Review the attached files." : trimmedPrompt;
        }

        var lines = new List<string>
        {
            string.IsNullOrWhiteSpace(trimmedPrompt) ? "Review the attached files." : trimmedPrompt,
            "",
            "Attached files:",
        };

        foreach (var attachment in attachments)
        {
            var mime = string.IsNullOrWhiteSpace(attachment.MimeType) ? "unknown" : attachment.MimeType!;
            lines.Add($"- {attachment.FileName} ({mime}): {attachment.Path}");
            if (attachment.IsImage)
            {
                lines.Add("  Image attachment is included as model input when the provider supports vision.");
            }
            else if (AttachmentTextExcerpt(attachment) is { } excerpt)
            {
                lines.Add("  Excerpt:");
                lines.Add(string.Join('\n', excerpt.Split('\n').Select(line => $"    {line}")));
            }
        }

        return string.Join('\n', lines);
    }

    private static string? AttachmentTextExcerpt(FileAttachment attachment)
    {
        if (!attachment.IsTextLike || !File.Exists(attachment.Path)) return null;

        try
        {
            var size = new FileInfo(attachment.Path).Length;
            if (size > 512_000) return null;

            var text = File.ReadAllText(attachment.Path, new UTF8Encoding(false, true)).Trim();
            if (string.IsNullOrWhiteSpace(text)) return null;
            return text[..Math.Min(text.Length, 8_000)];
        }
        catch
        {
            return null;
        }
    }

    private static (List<Dictionary<string, object?>> Blocks, List<AttachmentDiagnostic> Diagnostics) Resolve(FileAttachment attachment)
    {
        var fileExists = File.Exists(attachment.Path);
        var directoryExists = Directory.Exists(attachment.Path);
        if (!fileExists && !directoryExists)
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Attachment not found: {attachment.Path}.")]);
        }

        if (directoryExists && !fileExists)
        {
            return UnsupportedAttachment(attachment);
        }

        if (attachment.IsImage) return ResolveImage(attachment);
        if (attachment.IsPdf) return ResolvePdf(attachment);
        if (attachment.IsTextLike) return ResolveText(attachment);

        return UnsupportedAttachment(attachment);
    }

    private static (List<Dictionary<string, object?>> Blocks, List<AttachmentDiagnostic> Diagnostics) UnsupportedAttachment(FileAttachment attachment)
    {
        var extension = string.IsNullOrWhiteSpace(attachment.Extension) ? "(none)" : attachment.Extension;
        return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Info, $"Attachment {attachment.FileName} has unsupported extension {extension}; skipped.")]);
    }

    private static (List<Dictionary<string, object?>> Blocks, List<AttachmentDiagnostic> Diagnostics) ResolveImage(FileAttachment attachment)
    {
        long size;
        try
        {
            size = new FileInfo(attachment.Path).Length;
        }
        catch
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Unable to read image attachment metadata: {attachment.FileName}.")]);
        }

        if (size > MaxImageBytes)
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Image {attachment.FileName} is {size} bytes; limit is {MaxImageBytes}.")]);
        }

        try
        {
            var bytes = File.ReadAllBytes(attachment.Path);
            if (bytes.Length == 0)
            {
                return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Unable to read image attachment: {attachment.FileName}.")]);
            }

            var mimeType = string.IsNullOrWhiteSpace(attachment.MimeType) ? GuessImageMimeType(attachment) : attachment.MimeType!;
            return (
                [
                    new Dictionary<string, object?>
                    {
                        ["type"] = "image_url",
                        ["image_url"] = new Dictionary<string, object?>
                        {
                            ["url"] = $"data:{mimeType};base64,{Convert.ToBase64String(bytes)}",
                        },
                    },
                ],
                [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Info, $"Image attachment forwarded as multimodal input: {attachment.FileName}.")]);
        }
        catch
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Unable to read image attachment: {attachment.FileName}.")]);
        }
    }

    private static (List<Dictionary<string, object?>> Blocks, List<AttachmentDiagnostic> Diagnostics) ResolveText(FileAttachment attachment)
    {
        long size;
        try
        {
            size = new FileInfo(attachment.Path).Length;
        }
        catch
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Unable to read text attachment metadata: {attachment.FileName}.")]);
        }

        if (size > MaxTextBytes)
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Attachment {attachment.FileName} is {size} bytes; limit is {MaxTextBytes}.")]);
        }

        try
        {
            var text = File.ReadAllText(attachment.Path, new UTF8Encoding(false, true)).Trim();
            if (string.IsNullOrWhiteSpace(text))
            {
                return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Info, $"Attachment {attachment.FileName} is empty; skipped.")]);
            }

            var truncated = text.Length > MaxTextCharacters;
            var output = text[..Math.Min(text.Length, MaxTextCharacters)] + (truncated ? "\n...[truncated]" : "");
            var diagnostics = truncated
                ? new List<AttachmentDiagnostic> { new(AttachmentDiagnosticSeverity.Warning, $"Attachment {attachment.FileName} was truncated to {MaxTextCharacters} characters.") }
                : [];
            return ([TextAttachmentPart(attachment.Path, output)], diagnostics);
        }
        catch (DecoderFallbackException)
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Attachment {attachment.FileName} is not valid UTF-8 text.")]);
        }
        catch
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Unable to read text attachment: {attachment.FileName}.")]);
        }
    }

    private static (List<Dictionary<string, object?>> Blocks, List<AttachmentDiagnostic> Diagnostics) ResolvePdf(FileAttachment attachment)
    {
        try
        {
            using var document = PdfDocument.Open(attachment.Path);
            var count = Math.Min(document.NumberOfPages, MaxPdfPages);
            var builder = new StringBuilder();
            for (var pageNumber = 1; pageNumber <= count; pageNumber++)
            {
                if (builder.Length > 0) builder.AppendLine().AppendLine();
                var page = document.GetPage(pageNumber);
                var pageText = ContentOrderTextExtractor.GetText(page).Trim();
                builder.Append("## Page ").Append(pageNumber).AppendLine();
                builder.Append(string.IsNullOrWhiteSpace(pageText) ? "(no extractable text)" : pageText);
            }

            var diagnostics = new List<AttachmentDiagnostic>
            {
                new(AttachmentDiagnosticSeverity.Info, $"PDF {attachment.FileName} resolved as text from {count} page(s)."),
            };
            if (document.NumberOfPages > MaxPdfPages)
            {
                diagnostics.Add(new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"PDF {attachment.FileName} has {document.NumberOfPages} pages; only first {MaxPdfPages} pages were included."));
            }

            return ([TextAttachmentPart(attachment.Path, builder.ToString())], diagnostics);
        }
        catch
        {
            return ([], [new AttachmentDiagnostic(AttachmentDiagnosticSeverity.Warning, $"Unable to parse PDF attachment: {attachment.FileName}.")]);
        }
    }

    private static Dictionary<string, object?> TextAttachmentPart(string path, string text) =>
        TextPart($"<attachment path=\"{path}\">\n{text}\n</attachment>");

    private static Dictionary<string, object?> TextPart(string text) => new()
    {
        ["type"] = "text",
        ["text"] = text,
    };

    private static string GuessImageMimeType(FileAttachment attachment) => attachment.Extension switch
    {
        "jpg" or "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "tiff" or "tif" => "image/tiff",
        "bmp" => "image/bmp",
        _ => "image/png",
    };
}
