import SwiftUI

struct NativeMarkdownView: View {
    var text: String
    var fontSize: CGFloat = 15
    var lineSpacing: CGFloat = 7

    private var blocks: [NativeMarkdownBlock] {
        NativeMarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: NativeMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let value):
            MarkdownInlineText(value, size: headingSize(level), weight: .semibold)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let value):
            MarkdownInlineText(value, size: fontSize, lineSpacing: lineSpacing)
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(DesignTokens.separator)
                    .frame(width: 3)
                MarkdownInlineText(value, size: fontSize, lineSpacing: lineSpacing)
                    .foregroundStyle(DesignTokens.secondaryText)
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(checked ? DesignTokens.success : DesignTokens.tertiaryText)
                        } else {
                            Text(ordered ? "\(index + 1)." : "•")
                                .font(.system(size: fontSize, weight: .medium))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(width: ordered ? 22 : 12, alignment: .trailing)
                        }
                        MarkdownInlineText(item.text, size: fontSize, lineSpacing: lineSpacing)
                    }
                }
            }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(value)
                        .font(.system(size: max(12, fontSize - 2), design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .fill(DesignTokens.neutral50)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                            .stroke(DesignTokens.separator, lineWidth: 1)
                    )
            )
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(header, isHeader: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        tableRow(row, isHeader: false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
            }
        case .divider:
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                MarkdownInlineText(cell, size: max(12, fontSize - 1), weight: isHeader ? .semibold : .regular)
                    .lineLimit(nil)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(minWidth: 128, maxWidth: 240, alignment: .leading)
                    .background(isHeader ? DesignTokens.neutral50 : DesignTokens.background)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(DesignTokens.separator).frame(width: 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.separator).frame(height: 1)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: fontSize + 7
        case 2: fontSize + 5
        case 3: fontSize + 3
        default: fontSize + 1
        }
    }
}

struct MarkdownInlineText: View {
    var value: String
    var size: CGFloat
    var weight: Font.Weight
    var lineSpacing: CGFloat

    init(_ value: String, size: CGFloat, weight: Font.Weight = .regular, lineSpacing: CGFloat = 6) {
        self.value = value
        self.size = size
        self.weight = weight
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: value) {
                Text(attributed)
            } else {
                Text(value)
            }
        }
        .font(.system(size: size, weight: weight))
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum NativeMarkdownBlock: Hashable {
    case heading(level: Int, String)
    case paragraph(String)
    case quote(String)
    case list(ordered: Bool, [NativeMarkdownListItem])
    case code(language: String?, String)
    case table(header: [String], rows: [[String]])
    case divider
}

struct NativeMarkdownListItem: Hashable {
    var text: String
    var checked: Bool?
}

enum NativeMarkdownParser {
    static func parse(_ text: String) -> [NativeMarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [NativeMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isPureFenceSeparator(trimmed) {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if next.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                result.append(.code(language: language.isEmpty ? nil : language, codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(from: trimmed) {
                result.append(.heading(level: heading.level, heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                result.append(.divider)
                index += 1
                continue
            }

            if isTableStart(lines, index: index) {
                let header = tableCells(lines[index])
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index]
                    if row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !row.contains("|") {
                        break
                    }
                    rows.append(tableCells(row))
                    index += 1
                }
                result.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard next.hasPrefix(">") else { break }
                    quoteLines.append(String(next.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
                    index += 1
                }
                result.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let first = listItem(from: trimmed) {
                let ordered = first.ordered
                var items = [first.item]
                index += 1
                while index < lines.count, let next = listItem(from: lines[index].trimmingCharacters(in: .whitespacesAndNewlines)), next.ordered == ordered {
                    items.append(next.item)
                    index += 1
                }
                result.append(.list(ordered: ordered, items))
                continue
            }

            var paragraphLines = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.isEmpty || isBlockStart(lines, index: index) { break }
                paragraphLines.append(next)
                index += 1
            }
            let paragraph = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph))
            }
        }

        return result
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func listItem(from line: String) -> (ordered: Bool, item: NativeMarkdownListItem)? {
        let unorderedPrefixes = ["- ", "* ", "+ "]
        for prefix in unorderedPrefixes where line.hasPrefix(prefix) {
            return (false, normalizedListText(String(line.dropFirst(prefix.count))))
        }
        if let dot = line.firstIndex(of: ".") {
            let prefix = line[..<dot]
            let restIndex = line.index(after: dot)
            if !prefix.isEmpty, prefix.allSatisfy(\.isNumber), restIndex < line.endIndex, line[restIndex] == " " {
                return (true, normalizedListText(String(line[line.index(after: restIndex)...])))
            }
        }
        return nil
    }

    private static func normalizedListText(_ raw: String) -> NativeMarkdownListItem {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("[x] ") {
            return NativeMarkdownListItem(text: String(trimmed.dropFirst(4)), checked: true)
        }
        if lowered.hasPrefix("[ ] ") {
            return NativeMarkdownListItem(text: String(trimmed.dropFirst(4)), checked: false)
        }
        return NativeMarkdownListItem(text: trimmed, checked: nil)
    }

    private static func isBlockStart(_ lines: [String], index: Int) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("```") ||
            line.hasPrefix("~~~") ||
            heading(from: line) != nil ||
            isDivider(line) ||
            line.hasPrefix(">") ||
            listItem(from: line) != nil ||
            isTableStart(lines, index: index)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && Set(compact).isSubset(of: Set<Character>(["-", "*", "_"]))
    }

    private static func isPureFenceSeparator(_ line: String) -> Bool {
        line == "---" || line == "----"
    }

    private static func isTableStart(_ lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        return isTableSeparator(lines[index + 1])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            return compact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cell.contains("-")
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|")
        if parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            parts.removeFirst()
        }
        if parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            parts.removeLast()
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
