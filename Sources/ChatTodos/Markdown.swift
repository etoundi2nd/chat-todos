import SwiftUI

enum ListMarker: Equatable {
    case bullet
    case ordered(String)
    case task(done: Bool)
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(level: Int, marker: ListMarker, text: String)
    case code(String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])

    /// Rough number of rendered lines, used to decide where to cut a collapsed item.
    var weight: Int {
        switch self {
        case .paragraph(let t), .listItem(_, _, let t), .quote(let t):
            t.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + 1 + $1.count / 70 }
        case .code(let t): t.split(separator: "\n", omittingEmptySubsequences: false).count
        case .heading, .rule: 1
        case .table(_, let rows): rows.count + 1
        }
    }
}

/// A small line-based Markdown parser for the blocks AI chats produce. Unlike CommonMark,
/// single line breaks are kept: captured text uses them deliberately.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listIndents: [Int] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = indentation(line)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(String(lines[i].dropFirst(min(indent, indentation(lines[i])))))
                    i += 1
                }
                i += 1 // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if let (level, text) = heading(trimmed), indent < 4 {
                flushParagraph()
                listIndents = []
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                listIndents = []
                blocks.append(.rule)
                i += 1
                continue
            }

            // Table: a row of pipes followed by a |---|---| separator.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoted.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let (marker, text) = listItem(trimmed) {
                flushParagraph()
                while let last = listIndents.last, indent < last { listIndents.removeLast() }
                if listIndents.last.map({ indent > $0 }) ?? true { listIndents.append(indent) }
                var content = [text]
                i += 1
                // Indented lines that aren't list items belong to this item.
                while i < lines.count {
                    let next = lines[i]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty, indentation(next) > indent,
                          listItem(nextTrimmed) == nil, !nextTrimmed.hasPrefix("```")
                    else { break }
                    content.append(nextTrimmed)
                    i += 1
                }
                blocks.append(.listItem(level: listIndents.count - 1, marker: marker, text: content.joined(separator: "\n")))
                continue
            }

            if indent == 0 { listIndents = [] }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var t = Substring(row)
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") { t = t.dropLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> (ListMarker, String)? {
        if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
            let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
                return (.task(done: done), String(text.dropFirst(prefix.count)))
            }
            return (.bullet, text)
        }
        let digits = line.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, ".)".contains(delimiter), rest.dropFirst().first == " " else { return nil }
        return (.ordered("\(digits)\(delimiter)"), String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
}

/// Renders Markdown blocks. `collapsed` cuts long content to roughly `lineBudget` lines.
struct MarkdownText: View {
    let text: String
    var done = false
    var collapsed = false
    var lineBudget = 8

    private static let cache = NSCache<NSString, BlocksBox>()

    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private var blocks: [MarkdownBlock] {
        if let cached = Self.cache.object(forKey: text as NSString) { return cached.blocks }
        let parsed = MarkdownParser.parse(text)
        Self.cache.setObject(BlocksBox(parsed), forKey: text as NSString)
        return parsed
    }

    var body: some View {
        let all = blocks
        let shown = collapsed ? Self.truncate(all, budget: lineBudget) : all
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
            if shown.count < all.count {
                Text("⋯").foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(done ? .secondary : .primary)
    }

    static func truncate(_ blocks: [MarkdownBlock], budget: Int) -> [MarkdownBlock] {
        var used = 0
        var result: [MarkdownBlock] = []
        for block in blocks {
            if used >= budget { break }
            result.append(block)
            used += block.weight
        }
        return result
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let t):
            inline(t)
        case .heading(let level, let t):
            inline(t)
                .font(.system(size: level == 1 ? 16 : level == 2 ? 14.5 : 13.5, weight: .semibold))
                .padding(.top, 2)
        case .listItem(let level, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                markerView(marker, level: level)
                inline(t)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .code(let t):
            Text(t)
                .font(.system(size: 12, design: .monospaced))
                .strikethrough(done)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        case .quote(let t):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                inline(t).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 3)
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, c in inline(c).fontWeight(.semibold) } }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, c in inline(c) } }
                }
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder private func markerView(_ marker: ListMarker, level: Int) -> some View {
        switch marker {
        case .bullet:
            Text(["•", "◦", "▪︎"][level % 3]).foregroundStyle(.secondary).frame(width: 10)
        case .ordered(let label):
            Text(label).monospacedDigit().foregroundStyle(.secondary)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary).font(.system(size: 11))
        }
    }

    private func inline(_ text: String) -> some View {
        Text(Self.inlineAttributed(text))
            .strikethrough(done)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func inlineAttributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
