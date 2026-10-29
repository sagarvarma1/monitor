import Foundation

/// Turns hook payloads into one short line for the row and a longer text for the expanded view.
public enum Summarizer {
    public static func oneLine(_ text: String, max: Int = 90) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = firstLine.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= max { return collapsed }
        return String(collapsed.prefix(max - 1)) + "…"
    }

    /// The most informative argument of a tool call, e.g. the Bash command or the edited file.
    public static func toolArgument(_ tool: String, _ input: [String: Any]) -> String? {
        let keys = ["command", "file_path", "notebook_path", "url", "pattern", "query", "path", "description", "prompt"]
        for key in keys {
            guard let value = input[key] as? String, !value.isEmpty else { continue }
            if key.hasSuffix("path"), tool != "Bash" {
                return (value as NSString).lastPathComponent
            }
            return value
        }
        return nil
    }

    public static func toolCall(_ tool: String, _ input: [String: Any]) -> String {
        guard let arg = toolArgument(tool, input) else { return tool }
        return "\(tool): \(oneLine(arg, max: 70))"
    }

    public static func prettyJSON(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(obj)" }
        return s
    }

    /// AskUserQuestion: the first question, plus all questions and options for the detail view.
    public static func question(_ input: [String: Any]) -> (line: String, detail: String) {
        let questions = input["questions"] as? [[String: Any]] ?? []
        var detail: [String] = []
        for q in questions {
            if let text = q["question"] as? String { detail.append(text) }
            for opt in q["options"] as? [[String: Any]] ?? [] {
                if let label = opt["label"] as? String { detail.append("  • \(label)") }
            }
        }
        let first = questions.first?["question"] as? String ?? input["question"] as? String ?? "Claude has a question"
        return (oneLine(first), detail.isEmpty ? first : detail.joined(separator: "\n"))
    }
}
