namespace G9Claw.Windows.Core;

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
}
