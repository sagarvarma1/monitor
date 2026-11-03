import Foundation

/// The block structure of Claude's Markdown replies, enough to lay them out: headings, (nested) list items, code
/// blocks, rules and paragraphs. Inline styling (bold, `code`, links) is left in the text for AttributedString.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    /// `marker` is "•" for bullets, or the number as written ("1.") for ordered lists.
    case listItem(depth: Int, marker: String, text: String)
    case code(String)
    case rule
    case paragraph(String)

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = trimmed.firstMatch(#"^(#{1,6})\s+(.+)$"#) {
                flushParagraph()
                blocks.append(.heading(level: heading[1].count, text: heading[2]))
                continue
            }
            if trimmed.firstMatch(#"^([-*_])(\s*\1){2,}$"#) != nil {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let item = line.firstMatch(#"^(\s*)([-*+]|\d+[.)])\s+(.+)$"#) {
                flushParagraph()
                let marker = item[2].first.map { "-*+".contains($0) } == true ? "•" : item[2]
                blocks.append(.listItem(depth: item[1].count / 2, marker: marker, text: item[3]))
                continue
            }
            // Tables keep their columns only in a fixed-width font, so they're shown like code.
            if trimmed.hasPrefix("|") {
                flushParagraph()
                if case .code(let previous)? = blocks.last, previous.hasPrefix("|") {
                    blocks[blocks.count - 1] = .code(previous + "\n" + trimmed)
                } else {
                    blocks.append(.code(trimmed))
                }
                continue
            }
            // A wrapped continuation of the list item above stays with it.
            if case .listItem(let depth, let marker, let text)? = blocks.last, paragraph.isEmpty, raw.hasPrefix("  ") {
                blocks[blocks.count - 1] = .listItem(depth: depth, marker: marker, text: text + " " + trimmed)
                continue
            }
            paragraph.append(trimmed)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}

public extension Summarizer {
    /// Markdown flattened to readable plain text (for notification banners and other places that can't style it).
    static func plainText(_ markdown: String) -> String {
        MarkdownBlock.parse(markdown).map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text): return stripInline(text)
            case .listItem(_, let marker, let text): return "\(marker) \(stripInline(text))"
            case .code(let text): return text
            case .rule: return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    static func stripInline(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(attributed.characters)
    }
}

private extension String {
    /// Capture groups of the first match (index 0 is the whole match), or nil.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
