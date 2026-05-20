import Foundation
import HighlightSwift
import SwiftUI

enum CodeSyntaxHighlightingService {
    static let maxHighlightedCharacters = 180_000
    static let highlightDebounceInterval: TimeInterval = 0.18

    static func languageAlias(forFileName fileName: String) -> String? {
        let lowercased = fileName.lowercased()
        let ext = (lowercased as NSString).pathExtension
        let baseName = (lowercased as NSString).lastPathComponent

        switch baseName {
        case "dockerfile":
            return "dockerfile"
        case "makefile":
            return "makefile"
        default:
            break
        }

        switch ext {
        case "html", "htm":
            return "html"
        case "css":
            return "css"
        case "scss":
            return "scss"
        case "js", "mjs", "cjs":
            return "javascript"
        case "ts", "tsx":
            return "typescript"
        case "jsx":
            return "javascript"
        case "py", "pyw":
            return "python"
        case "swift":
            return "swift"
        case "json", "jsonc":
            return "json"
        case "yml", "yaml":
            return "yaml"
        case "md", "markdown":
            return "markdown"
        case "sh", "bash", "zsh":
            return "bash"
        case "toml":
            return "toml"
        case "xml":
            return "xml"
        case "sql":
            return "sql"
        case "rs":
            return "rust"
        case "go":
            return "go"
        case "java":
            return "java"
        case "c":
            return "c"
        case "cc", "cpp", "cxx", "hpp", "hh":
            return "cpp"
        default:
            return nil
        }
    }

    static func shouldHighlight(_ text: String, languageAlias: String?) -> Bool {
        languageAlias != nil && !text.isEmpty && text.count <= maxHighlightedCharacters
    }

    static func themeName(isDarkMode: Bool) -> String {
        isDarkMode ? "tokyoNight" : "xcode"
    }

    static func colors(isDarkMode: Bool) -> HighlightColors {
        isDarkMode ? .dark(.tokyoNight) : .light(.xcode)
    }

    static func highlightedText(
        _ text: String,
        languageAlias: String,
        isDarkMode: Bool
    ) async throws -> AttributedString {
        try await Highlight().attributedText(
            text,
            language: languageAlias,
            colors: colors(isDarkMode: isDarkMode)
        )
    }
}
