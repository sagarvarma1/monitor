import Foundation

/// One line of a session's activity feed.
public struct ActivityItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case prompt
        case reply
        case tool(String)
    }

    public var id: String
    public var kind: Kind
    /// One line for the feed.
    public var title: String
    /// The full text: your prompt, Claude's Markdown reply, or the tool's input.
    public var detail: String
    public var time: Date?
    /// The tool call came back with an error.
    public var failed = false
}

public struct TodoItem: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    public var id: String
    public var text: String
    public var status: Status
}

public struct FileTouch: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var edits: Int
    /// Lines added and removed by the edits that succeeded. A Write counts the whole file as added.
    public var added = 0
    public var removed = 0
}

public struct ToolStat: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var calls: Int
    public var failed: Int
}

/// What a transcript says about its session.
public struct TranscriptSummary: Equatable, Sendable {
    /// Oldest first; capped at the most recent `TranscriptReader.maxItems`.
    public var items: [ActivityItem] = []
    public var todos: [TodoItem] = []
    /// Most recently touched first.
    public var files: [FileTouch] = []
    public var prompts = 0
    public var toolCalls = 0
    public var failedToolCalls = 0
    /// Size of the context on the latest request (input + cache tokens).
    public var contextTokens = 0
    public var outputTokens = 0
    /// Totals across every request: tokens sent fresh, read from the prompt cache, and written to it.
    public var inputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var requests = 0
    /// Estimated at API rates; see ModelPrice.
    public var cost = CostSplit()
    /// Most expensive first.
    public var costByModel: [ModelCost] = []
    /// In prompt order.
    public var turns: [TurnCost] = []
    /// Requests from models missing from the price table, left out of `cost`.
    public var unpricedRequests = 0
    /// The model on the latest request.
    public var model: String?
    /// Most used first.
    public var tools: [ToolStat] = []
    public var linesAdded = 0
    public var linesRemoved = 0
    public var startedAt: Date?
    /// Time the transcript was moving: gaps longer than `TranscriptReader.idleGap` count as idle, not work.
    public var activeSeconds: TimeInterval = 0

    public init() {}
}

/// Reads a Claude Code transcript (JSONL) incrementally: each `update()` only parses lines appended since the
/// last one, so it stays cheap on a 20 MB transcript refreshed every second. Not thread-safe; use one queue.
public final class TranscriptReader {
    public static let maxItems = 400
    public static let idleGap: TimeInterval = 300
    public let path: String

    private var offset: UInt64 = 0
    private var partial = Data()
    private var summary = TranscriptSummary()
    private var toolIndex: [String: Int] = [:]          // tool_use id -> items index
    private var pendingTaskCreates: [String: Int] = [:] // tool_use id -> todos index, until the result names it
    private var countedMessages: Set<String> = []
    private var fileOrder: [String] = []
    private var fileEdits: [String: Int] = [:]
    private var fileLines: [String: (added: Int, removed: Int)] = [:]
    private var toolNames: [String: String] = [:]       // tool_use id -> tool name
    private var toolCalls: [String: Int] = [:]
    private var toolFailures: [String: Int] = [:]
    private var pendingLines: [String: (path: String, added: Int, removed: Int)] = [:] // until the result says it worked
    private var lastEntryTime: Date?
    private var modelCosts: [String: ModelCost] = [:]

    public init(path: String) {
        self.path = path
    }

    /// Where Claude Code keeps a session's transcript, for sessions whose hooks didn't say.
    public static func defaultPath(cwd: String, sessionID: String) -> String {
        let folder = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return NSHomeDirectory() + "/.claude/projects/\(folder)/\(sessionID).jsonl"
    }

    public func update() -> TranscriptSummary {
        guard let handle = FileHandle(forReadingAtPath: path) else { return summary }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { reset() }  // rewritten or truncated: start over
        guard size > offset else { return summary }
        try? handle.seek(toOffset: offset)
        var data = partial + ((try? handle.readToEnd()) ?? Data())
        offset = size
        // Keep an unterminated last line for next time.
        if let lastNewline = data.lastIndex(of: 0x0A) {
            partial = data[data.index(after: lastNewline)...]
            data = data[..<lastNewline]
        } else {
            partial = data
            return summary
        }
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { ingest(obj) }
        }
        trim()
        summary.files = fileOrder.reversed().map {
            FileTouch(path: $0, edits: fileEdits[$0] ?? 0, added: fileLines[$0]?.added ?? 0, removed: fileLines[$0]?.removed ?? 0)
        }
        summary.costByModel = modelCosts.values.sorted { $0.cost > $1.cost }
        summary.tools = toolCalls.map { ToolStat(name: $0.key, calls: $0.value, failed: toolFailures[$0.key] ?? 0) }
            .sorted { ($0.calls, $1.name) > ($1.calls, $0.name) }
        return summary
    }

    private func reset() {
        offset = 0
        partial = Data()
        summary = TranscriptSummary()
        toolIndex = [:]
        pendingTaskCreates = [:]
        countedMessages = []
        fileOrder = []
        fileEdits = [:]
        fileLines = [:]
        toolNames = [:]
        toolCalls = [:]
        toolFailures = [:]
        pendingLines = [:]
        lastEntryTime = nil
        modelCosts = [:]
    }

    // MARK: Parsing

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func ingest(_ entry: [String: Any]) {
        // Counted before the sidechain filter: a session waiting on its subagents is still working.
        if let time = (entry["timestamp"] as? String).flatMap({ Self.iso.date(from: $0) }) {
            if let last = lastEntryTime, time > last, time.timeIntervalSince(last) <= Self.idleGap {
                summary.activeSeconds += time.timeIntervalSince(last)
            }
            lastEntryTime = max(time, lastEntryTime ?? time)
        }
        // Subagent work happens on a sidechain; the feed follows the main conversation.
        guard entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return }
        let time = (entry["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
        if summary.startedAt == nil { summary.startedAt = time }

        switch entry["type"] as? String {
        case "user":
            if let text = message["content"] as? String {
                addPrompt(text, time: time, id: entry["uuid"] as? String)
            } else if let blocks = message["content"] as? [[String: Any]] {
                let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                if !texts.isEmpty { addPrompt(texts.joined(separator: "\n"), time: time, id: entry["uuid"] as? String) }
                for block in blocks where block["type"] as? String == "tool_result" { toolResult(block) }
            }
        case "assistant":
            countUsage(message)
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        append(ActivityItem(id: UUID().uuidString, kind: .reply,
                                            title: Summarizer.oneLine(Summarizer.plainText(text), max: 140),
                                            detail: text, time: time))
                    }
                case "tool_use":
                    toolUse(block, time: time)
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private func addPrompt(_ text: String, time: Date?, id: String?) {
        let trimmed = ChatMessage.reply(inTranscriptText: text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash-command plumbing, hook output and reminders arrive as tagged "user" text; they aren't you.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return }
        summary.prompts += 1
        summary.turns.append(TurnCost(id: summary.turns.count, prompt: Summarizer.oneLine(trimmed, max: 80), cost: 0, requests: 0))
        append(ActivityItem(id: id ?? UUID().uuidString, kind: .prompt, title: Summarizer.oneLine(trimmed, max: 140),
                            detail: trimmed, time: time))
    }

    private func toolUse(_ block: [String: Any], time: Date?) {
        let name = block["name"] as? String ?? "Tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let id = block["id"] as? String ?? UUID().uuidString
        summary.toolCalls += 1
        toolCalls[name, default: 0] += 1
        toolNames[id] = name
        toolIndex[id] = summary.items.count
        append(ActivityItem(id: id, kind: .tool(name), title: Summarizer.toolCall(name, input),
                            detail: Summarizer.prettyJSON(input), time: time))

        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                touch(path)
                let change = Self.lineChange(name, input)
                pendingLines[id] = (path, change.added, change.removed)
                addLines(path, change.added, change.removed)
            }
        case "TodoWrite":
            summary.todos = (input["todos"] as? [[String: Any]] ?? []).enumerated().map { i, t in
                TodoItem(id: t["id"] as? String ?? "\(i)", text: t["content"] as? String ?? t["subject"] as? String ?? "",
                         status: TodoItem.Status(rawValue: t["status"] as? String ?? "") ?? .pending)
            }
        case "TaskCreate":
            let text = input["subject"] as? String ?? input["content"] as? String ?? input["description"] as? String ?? ""
            pendingTaskCreates[id] = summary.todos.count
            summary.todos.append(TodoItem(id: "pending-\(id)", text: text, status: .pending))
        case "TaskUpdate":
            let taskID = (input["taskId"] ?? input["id"]).map { "\($0)" } ?? ""
            guard let i = summary.todos.firstIndex(where: { $0.id == taskID }) else { break }
            if input["status"] as? String == "deleted" {
                summary.todos.remove(at: i)
            } else {
                if let status = (input["status"] as? String).flatMap(TodoItem.Status.init(rawValue:)) { summary.todos[i].status = status }
                if let subject = input["subject"] as? String { summary.todos[i].text = subject }
            }
        default:
            break
        }
    }

    private func toolResult(_ block: [String: Any]) {
        guard let id = block["tool_use_id"] as? String else { return }
        let lines = pendingLines.removeValue(forKey: id)
        if block["is_error"] as? Bool == true {
            summary.failedToolCalls += 1
            if let name = toolNames[id] { toolFailures[name, default: 0] += 1 }
            if let lines { addLines(lines.path, -lines.added, -lines.removed) }
            if let i = toolIndex[id], summary.items.indices.contains(i), summary.items[i].id == id {
                summary.items[i].failed = true
            }
        }
        // TaskCreate's result names the new task ("Task #3 created…"); later TaskUpdates refer to it by that id.
        if let todo = pendingTaskCreates.removeValue(forKey: id), summary.todos.indices.contains(todo) {
            let text = (block["content"] as? String)
                ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
            if let match = text.range(of: #"#(\d+)"#, options: .regularExpression) {
                summary.todos[todo].id = String(text[match].dropFirst())
            } else {
                summary.todos[todo].id = "\(todo + 1)"
            }
        }
    }

    /// Context = everything sent on the latest request; output is summed once per API message (a message's
    /// content blocks arrive as separate entries that repeat its usage).
    private func countUsage(_ message: [String: Any]) {
        guard let usage = message["usage"] as? [String: Any] else { return }
        let n = { (key: String) in usage[key] as? Int ?? 0 }
        summary.contextTokens = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
        if let model = message["model"] as? String, !model.hasPrefix("<") { summary.model = model }
        if let id = message["id"] as? String, countedMessages.insert(id).inserted {
            summary.outputTokens += n("output_tokens")
            summary.inputTokens += n("input_tokens")
            summary.cacheReadTokens += n("cache_read_input_tokens")
            summary.cacheWriteTokens += n("cache_creation_input_tokens")
            summary.requests += 1
            addCost(model: message["model"] as? String ?? "", usage: usage)
        }
    }

    private func addCost(model: String, usage: [String: Any]) {
        guard !model.hasPrefix("<") else { return }  // Claude Code's own placeholder messages cost nothing
        guard let split = CostSplit.of(model: model, usage: usage) else {
            summary.unpricedRequests += 1
            return
        }
        summary.cost.add(split)
        modelCosts[model, default: ModelCost(model: model, cost: 0, requests: 0)].cost += split.total
        modelCosts[model, default: ModelCost(model: model, cost: 0, requests: 0)].requests += 1
        if summary.turns.isEmpty { summary.turns.append(TurnCost(id: 0, prompt: "Before your first prompt", cost: 0, requests: 0)) }
        summary.turns[summary.turns.count - 1].cost += split.total
        summary.turns[summary.turns.count - 1].requests += 1
    }

    private func addLines(_ path: String, _ added: Int, _ removed: Int) {
        fileLines[path, default: (0, 0)].added += added
        fileLines[path, default: (0, 0)].removed += removed
        summary.linesAdded += added
        summary.linesRemoved += removed
    }

    /// What an edit tool's input says it changes. An Edit with replace_all counts one replacement.
    static func lineChange(_ tool: String, _ input: [String: Any]) -> (added: Int, removed: Int) {
        func text(_ key: String, in dict: [String: Any]) -> String { dict[key] as? String ?? "" }
        switch tool {
        case "Write":
            return (lines(text("content", in: input)).count, 0)
        case "MultiEdit":
            return (input["edits"] as? [[String: Any]] ?? []).reduce(into: (added: 0, removed: 0)) { total, edit in
                let change = diff(text("old_string", in: edit), text("new_string", in: edit))
                total.added += change.added
                total.removed += change.removed
            }
        case "Edit":
            return diff(text("old_string", in: input), text("new_string", in: input))
        default:
            return (0, 0)
        }
    }

    private static func lines(_ text: String) -> [Substring] {
        var out = text.split(separator: "\n", omittingEmptySubsequences: false)
        if out.last == "" { out.removeLast() }
        return out
    }

    /// Ignores the unchanged lines an edit quotes around its change.
    private static func diff(_ old: String, _ new: String) -> (added: Int, removed: Int) {
        var a = lines(old)[...], b = lines(new)[...]
        while let x = a.first, x == b.first { a.removeFirst(); b.removeFirst() }
        while let x = a.last, x == b.last { a.removeLast(); b.removeLast() }
        return (b.count, a.count)
    }

    private func touch(_ path: String) {
        fileEdits[path, default: 0] += 1
        fileOrder.removeAll { $0 == path }
        fileOrder.append(path)
    }

    private func append(_ item: ActivityItem) {
        summary.items.append(item)
    }

    /// Drops the oldest feed items past the cap, keeping tool-result lookups pointing at the right rows.
    private func trim() {
        let excess = summary.items.count - Self.maxItems
        guard excess > 0 else { return }
        summary.items.removeFirst(excess)
        toolIndex = toolIndex.compactMapValues { $0 >= excess ? $0 - excess : nil }
    }
}
