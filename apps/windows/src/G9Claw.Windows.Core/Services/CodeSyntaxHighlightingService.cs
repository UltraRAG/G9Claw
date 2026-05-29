namespace G9Claw.Windows.Core;

public enum CodeHighlightTokenKind
{
    Plain,
    Keyword,
    String,
    Number,
    Comment,
    Punctuation,
}

public sealed record CodeHighlightSpan(string Text, CodeHighlightTokenKind Kind);

public static class CodeSyntaxHighlightingService
{
    public const int MaxHighlightedCharacters = 180_000;
    public static readonly TimeSpan HighlightDebounceInterval = TimeSpan.FromMilliseconds(180);

    public static string? LanguageAliasForFileName(string fileName)
    {
        var lower = fileName.Trim().ToLowerInvariant();
        var baseName = Path.GetFileName(lower);
        var extension = Path.GetExtension(lower).TrimStart('.');

        switch (baseName)
        {
            case "dockerfile":
                return "dockerfile";
            case "makefile":
                return "makefile";
        }

        return extension switch
        {
            "html" or "htm" => "html",
            "css" => "css",
            "scss" => "scss",
            "js" or "mjs" or "cjs" or "jsx" => "javascript",
            "ts" or "tsx" => "typescript",
            "py" or "pyw" => "python",
            "swift" => "swift",
            "json" or "jsonc" => "json",
            "yml" or "yaml" => "yaml",
            "md" or "markdown" => "markdown",
            "sh" or "bash" or "zsh" => "bash",
            "toml" => "toml",
            "xml" => "xml",
            "sql" => "sql",
            "rs" => "rust",
            "go" => "go",
            "java" => "java",
            "c" => "c",
            "cc" or "cpp" or "cxx" or "hpp" or "hh" => "cpp",
            _ => null,
        };
    }

    public static bool ShouldHighlight(string text, string? languageAlias) =>
        !string.IsNullOrWhiteSpace(languageAlias) &&
        text.Length > 0 &&
        text.Length <= MaxHighlightedCharacters;

    public static string ThemeName(bool isDarkMode) => isDarkMode ? "tokyoNight" : "xcode";

    public static string ColorHex(CodeHighlightTokenKind kind, bool isDarkMode) => (kind, isDarkMode) switch
    {
        (CodeHighlightTokenKind.Keyword, true) => "#7AA2F7",
        (CodeHighlightTokenKind.String, true) => "#9ECE6A",
        (CodeHighlightTokenKind.Number, true) => "#FF9E64",
        (CodeHighlightTokenKind.Comment, true) => "#565F89",
        (CodeHighlightTokenKind.Punctuation, true) => "#C0CAF5",
        (CodeHighlightTokenKind.Keyword, false) => "#AD3DA4",
        (CodeHighlightTokenKind.String, false) => "#C41A16",
        (CodeHighlightTokenKind.Number, false) => "#1C00CF",
        (CodeHighlightTokenKind.Comment, false) => "#5D6C79",
        (CodeHighlightTokenKind.Punctuation, false) => "#343434",
        (_, true) => "#F5F5F5",
        _ => "#171717",
    };

    public static IReadOnlyList<CodeHighlightSpan> HighlightedSpans(string text, string? languageAlias)
    {
        if (!ShouldHighlight(text, languageAlias) || languageAlias is null)
        {
            return [new CodeHighlightSpan(text, CodeHighlightTokenKind.Plain)];
        }

        var keywords = KeywordsFor(languageAlias);
        var spans = new List<CodeHighlightSpan>();
        var i = 0;
        while (i < text.Length)
        {
            if (TryConsumeComment(text, languageAlias, i, out var commentLength))
            {
                Add(spans, text.Substring(i, commentLength), CodeHighlightTokenKind.Comment);
                i += commentLength;
                continue;
            }

            var c = text[i];
            if (c is '"' or '\'' or '`')
            {
                var length = ConsumeQuotedString(text, i, c);
                Add(spans, text.Substring(i, length), CodeHighlightTokenKind.String);
                i += length;
                continue;
            }

            if (char.IsDigit(c))
            {
                var length = ConsumeNumber(text, i);
                Add(spans, text.Substring(i, length), CodeHighlightTokenKind.Number);
                i += length;
                continue;
            }

            if (IsIdentifierStart(c))
            {
                var length = ConsumeIdentifier(text, i);
                var value = text.Substring(i, length);
                Add(spans, value, keywords.Contains(value) ? CodeHighlightTokenKind.Keyword : CodeHighlightTokenKind.Plain);
                i += length;
                continue;
            }

            if (IsPunctuation(c))
            {
                Add(spans, c.ToString(), CodeHighlightTokenKind.Punctuation);
                i++;
                continue;
            }

            var plainStart = i;
            i++;
            while (i < text.Length &&
                   !char.IsDigit(text[i]) &&
                   !IsIdentifierStart(text[i]) &&
                   !IsPunctuation(text[i]) &&
                   text[i] is not '"' and not '\'' and not '`' &&
                   !TryConsumeComment(text, languageAlias, i, out _))
            {
                i++;
            }
            Add(spans, text[plainStart..i], CodeHighlightTokenKind.Plain);
        }

        return spans;
    }

    private static void Add(List<CodeHighlightSpan> spans, string text, CodeHighlightTokenKind kind)
    {
        if (text.Length == 0) return;
        if (spans.Count > 0 && spans[^1].Kind == kind)
        {
            spans[^1] = spans[^1] with { Text = spans[^1].Text + text };
            return;
        }

        spans.Add(new CodeHighlightSpan(text, kind));
    }

    private static bool TryConsumeComment(string text, string languageAlias, int index, out int length)
    {
        length = 0;
        if (languageAlias == "html" && text.AsSpan(index).StartsWith("<!--", StringComparison.Ordinal))
        {
            length = ConsumeUntil(text, index, "-->", includeTerminator: true);
            return true;
        }

        if (SupportsSlashComments(languageAlias) && text.AsSpan(index).StartsWith("//", StringComparison.Ordinal))
        {
            length = ConsumeUntilLineEnd(text, index);
            return true;
        }

        if (SupportsSlashComments(languageAlias) && text.AsSpan(index).StartsWith("/*", StringComparison.Ordinal))
        {
            length = ConsumeUntil(text, index, "*/", includeTerminator: true);
            return true;
        }

        if (SupportsHashComments(languageAlias) && text[index] == '#')
        {
            length = ConsumeUntilLineEnd(text, index);
            return true;
        }

        if (languageAlias == "sql" && text.AsSpan(index).StartsWith("--", StringComparison.Ordinal))
        {
            length = ConsumeUntilLineEnd(text, index);
            return true;
        }

        return false;
    }

    private static int ConsumeQuotedString(string text, int start, char quote)
    {
        var i = start + 1;
        while (i < text.Length)
        {
            if (text[i] == '\\')
            {
                i = Math.Min(text.Length, i + 2);
                continue;
            }

            i++;
            if (text[i - 1] == quote)
            {
                break;
            }
        }

        return i - start;
    }

    private static int ConsumeNumber(string text, int start)
    {
        var i = start + 1;
        while (i < text.Length && (char.IsLetterOrDigit(text[i]) || text[i] is '.' or '_' or '+' or '-'))
        {
            i++;
        }

        return i - start;
    }

    private static int ConsumeIdentifier(string text, int start)
    {
        var i = start + 1;
        while (i < text.Length && (char.IsLetterOrDigit(text[i]) || text[i] is '_' or '-'))
        {
            i++;
        }

        return i - start;
    }

    private static int ConsumeUntilLineEnd(string text, int start)
    {
        var newline = text.IndexOf('\n', start);
        return newline < 0 ? text.Length - start : newline - start;
    }

    private static int ConsumeUntil(string text, int start, string terminator, bool includeTerminator)
    {
        var end = text.IndexOf(terminator, start + terminator.Length, StringComparison.Ordinal);
        if (end < 0)
        {
            return text.Length - start;
        }

        return end - start + (includeTerminator ? terminator.Length : 0);
    }

    private static bool IsIdentifierStart(char c) => char.IsLetter(c) || c == '_';

    private static bool IsPunctuation(char c) => "{}[]()<>:;,.=+-*/%!&|?@".Contains(c);

    private static bool SupportsSlashComments(string languageAlias) =>
        languageAlias is "javascript" or "typescript" or "swift" or "rust" or "go" or "java" or "c" or "cpp" or "css" or "scss" or "json";

    private static bool SupportsHashComments(string languageAlias) =>
        languageAlias is "python" or "bash" or "yaml" or "toml" or "makefile" or "dockerfile";

    private static HashSet<string> KeywordsFor(string languageAlias)
    {
        string[] values = languageAlias switch
        {
            "html" => ["html", "head", "body", "main", "section", "div", "span", "style", "script", "link", "meta", "title", "doctype", "color"],
            "css" or "scss" => ["body", "color", "display", "grid", "flex", "position", "background", "font", "margin", "padding", "border"],
            "javascript" or "typescript" => ["await", "break", "case", "catch", "class", "const", "else", "export", "false", "for", "function", "if", "import", "interface", "let", "new", "null", "return", "true", "type", "var"],
            "python" => ["as", "class", "def", "elif", "else", "False", "for", "from", "if", "import", "in", "None", "return", "True", "with"],
            "swift" => ["class", "enum", "false", "func", "guard", "if", "import", "let", "nil", "return", "struct", "true", "var"],
            "json" => ["false", "null", "true"],
            "yaml" => ["false", "null", "true"],
            "bash" => ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then"],
            "sql" => ["and", "as", "by", "from", "group", "insert", "join", "limit", "order", "select", "table", "update", "where"],
            "rust" => ["enum", "false", "fn", "impl", "let", "match", "mod", "pub", "return", "struct", "true", "use"],
            "go" => ["defer", "else", "false", "func", "if", "import", "nil", "package", "return", "struct", "true", "type", "var"],
            "java" or "c" or "cpp" => ["class", "const", "else", "false", "for", "if", "include", "new", "null", "public", "return", "static", "true", "void"],
            _ => [],
        };
        return new HashSet<string>(values, StringComparer.OrdinalIgnoreCase);
    }
}
