import Foundation

public struct TerminalRun: Equatable, Sendable {
    public enum Color: Equatable, Sendable {
        case indexed(Int)
        case rgb(Int, Int, Int)
    }
    public var text: String
    public var color: Color?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false

    public init(text: String, color: Color? = nil, bold: Bool = false, dim: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.text = text
        self.color = color
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
    }
}

public enum TerminalText {
    /// Splits text with ANSI escape codes into styled runs. Sequences that aren't colors or styles are dropped.
    public static func parseANSI(_ source: String) -> [TerminalRun] {
        var runs: [TerminalRun] = []
        var style = TerminalRun(text: "")
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            var run = style
            run.text = text
            runs.append(run)
            text = ""
        }
        let chars = Array(source.unicodeScalars)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\u{1B}" else {
                text.unicodeScalars.append(chars[i])
                i += 1
                continue
            }
            guard i + 1 < chars.count, chars[i + 1] == "[" else {
                i += 2  // a two-character escape
                continue
            }
            var end = i + 2
            while end < chars.count, !(0x40...0x7E).contains(chars[end].value) { end += 1 }
            guard end < chars.count else { break }
            if chars[end] == "m" {
                var params = ""
                params.unicodeScalars.append(contentsOf: chars[(i + 2)..<end])
                flush()
                apply(params, to: &style)
            }
            i = end + 1
        }
        flush()
        return runs
    }

    private static func apply(_ params: String, to style: inout TerminalRun) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: style = TerminalRun(text: "")
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.color = .indexed(code - 30)
            case 39: style.color = nil
            case 90...97: style.color = .indexed(code - 90 + 8)
            case 38, 48:  // extended foreground or background; backgrounds are skipped
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    if code == 38 { style.color = .indexed(codes[i + 2]) }
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    if code == 38 { style.color = .rgb(codes[i + 2], codes[i + 3], codes[i + 4]) }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    /// Terminal and iTerm2 only hand over plain text, so this colors Claude Code's recognisable lines. It approximates
    /// the terminal's colors rather than reproducing them.
    public static func highlightClaudeCode(_ plain: String) -> [TerminalRun] {
        var runs: [TerminalRun] = []
        let lines = plain.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var run = TerminalRun(text: line)
            if trimmed.hasPrefix("⏺") {
                run.color = .indexed(10)
            } else if trimmed.hasPrefix("❯") || trimmed.hasPrefix(">") {
                run.bold = true
            } else if trimmed.hasPrefix("⎿") || trimmed.allSatisfy({ "─━═│╭╮╰╯ ".contains($0) }) {
                run.dim = true
            } else if line.range(of: #"^\s*\d+\s*\+"#, options: .regularExpression) != nil {
                run.color = .indexed(2)
            } else if line.range(of: #"^\s*\d+\s*-"#, options: .regularExpression) != nil {
                run.color = .indexed(1)
            } else if let first = trimmed.unicodeScalars.first, "✻✽✶✳✢·".unicodeScalars.contains(first), trimmed.contains("…") {
                run.color = .rgb(215, 119, 87)
            } else if trimmed.hasPrefix("⏵") || trimmed.hasPrefix("⧉") {
                run.dim = true
            }
            if index < lines.count - 1 { run.text += "\n" }
            runs.append(run)
        }
        return runs
    }
}
