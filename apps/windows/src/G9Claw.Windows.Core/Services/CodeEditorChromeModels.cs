namespace G9Claw.Windows.Core;

public sealed record EditorTextInset(double Width, double Height);

public static class CodeLineNumberMetrics
{
    public static readonly EditorTextInset EditorTextInset = new(14, 14);
    public const double EditorTextInsetAfterLineNumberGutter = 12;

    public static int LineCount(string text) => Math.Max(1, text.Split('\n').Length);

    public static double RulerWidth(int lineCount, double digitWidth = 7)
    {
        var digits = Math.Max(2, Math.Max(1, lineCount).ToString().Length);
        return Math.Max(48, digits * digitWidth + 28);
    }

    public static IReadOnlyList<int> LineStarts(string text)
    {
        if (text.Length == 0)
        {
            return [0];
        }

        var starts = new List<int> { 0 };
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '\n')
            {
                starts.Add(i + 1);
            }
        }

        return starts;
    }

    public static int LineNumber(int characterIndex, IReadOnlyList<int> lineStarts)
    {
        if (lineStarts.Count == 0)
        {
            return 1;
        }

        var target = Math.Max(0, characterIndex);
        var lower = 0;
        var upper = lineStarts.Count;
        while (lower < upper)
        {
            var mid = (lower + upper) / 2;
            if (lineStarts[mid] <= target)
            {
                lower = mid + 1;
            }
            else
            {
                upper = mid;
            }
        }

        return Math.Max(1, lower);
    }

    public static EditorTextInset TextInset(bool lineNumbersVisible, int lineCount = 1) =>
        lineNumbersVisible
            ? new EditorTextInset(
                RulerWidth(lineCount) + EditorTextInsetAfterLineNumberGutter,
                EditorTextInset.Height)
            : EditorTextInset;
}

public sealed record CodeMinimapLine(int IndentLevel, double WidthFraction, double Intensity, bool IsBlank);

public sealed record CodeMinimapSnapshot(
    int TotalLines,
    IReadOnlyList<CodeMinimapLine> Lines,
    int SampleStride,
    string Signature)
{
    public static CodeMinimapSnapshot Empty { get; } = FromText("");

    public static CodeMinimapSnapshot FromText(string text, int maxLines = 900)
    {
        var rawLines = text.Split('\n');
        var totalLines = Math.Max(1, rawLines.Length);
        var sampleStride = Math.Max(1, (int)Math.Ceiling(totalLines / (double)Math.Max(1, maxLines)));
        var sampled = new List<CodeMinimapLine>();
        for (var index = 0; index < rawLines.Length; index += sampleStride)
        {
            var upper = Math.Min(rawLines.Length, index + sampleStride);
            var representative = rawLines[index..upper]
                .OrderByDescending(line => line.Trim().Length)
                .FirstOrDefault() ?? "";
            sampled.Add(FromLine(representative));
        }

        if (sampled.Count == 0)
        {
            sampled.Add(FromLine(""));
        }

        return new CodeMinimapSnapshot(totalLines, sampled, sampleStride, SignatureFor(text));
    }

    public static string SignatureFor(string text) => $"{text.Length}:{text.GetHashCode()}";

    private static CodeMinimapLine FromLine(string rawLine)
    {
        var trimmed = rawLine.Trim();
        var indent = rawLine.TakeWhile(character => character is ' ' or '\t')
            .Sum(character => character == '\t' ? 4 : 1);
        var width = trimmed.Length == 0 ? 0.18 : Math.Min(1, Math.Max(0.22, trimmed.Length / 96.0));
        var intensity = trimmed.Length == 0 ? 0.10 : Math.Min(0.66, 0.20 + trimmed.Length / 150.0);
        return new CodeMinimapLine(Math.Min(24, indent), width, intensity, trimmed.Length == 0);
    }
}

public sealed record CodeMinimapModel(
    int TotalLines,
    IReadOnlyList<CodeMinimapLine> Lines,
    double ViewportStartFraction,
    double ViewportHeightFraction,
    int SampleStride)
{
    public const double Width = 64;

    public static CodeMinimapModel FromText(string text, Range? visibleLineRange = null, int maxLines = 900) =>
        FromSnapshot(CodeMinimapSnapshot.FromText(text, maxLines), visibleLineRange);

    public static CodeMinimapModel FromSnapshot(CodeMinimapSnapshot snapshot, Range? visibleLineRange = null)
    {
        var fallbackUpper = Math.Min(snapshot.TotalLines + 1, 32);
        var lowerBound = visibleLineRange?.Start.Value ?? 1;
        var upperBound = visibleLineRange?.End.Value ?? Math.Max(2, fallbackUpper);
        var lower = Math.Max(1, Math.Min(snapshot.TotalLines, lowerBound));
        var upper = Math.Max(lower + 1, Math.Min(snapshot.TotalLines + 1, upperBound));
        return new CodeMinimapModel(
            snapshot.TotalLines,
            snapshot.Lines,
            Math.Min(1, Math.Max(0, (lower - 1) / (double)Math.Max(1, snapshot.TotalLines))),
            Math.Min(1, Math.Max(0.035, (upper - lower) / (double)Math.Max(1, snapshot.TotalLines))),
            snapshot.SampleStride);
    }

    public int LineNumberAt(double y, double height)
    {
        if (height <= 0)
        {
            return 1;
        }

        var fraction = Math.Min(1, Math.Max(0, y / height));
        return Math.Min(TotalLines, Math.Max(1, (int)Math.Floor(fraction * TotalLines) + 1));
    }
}

public static class CodeEditorScrollStabilityMetrics
{
    public static readonly TimeSpan VisibleRangePublishInterval = TimeSpan.FromMilliseconds(120);
    public const bool PreservesScrollOriginOnUpdate = true;
    public const bool MinimapAllowsHitTesting = true;
    public const bool EditorBodyClipsRulerToContent = true;
    public const double MinimapViewportMinHeight = 18;

    public static double HorizontalOrigin(double proposed, bool wordWrap, double maxX) =>
        wordWrap ? 0 : Math.Min(Math.Max(0, proposed), Math.Max(0, maxX));
}
