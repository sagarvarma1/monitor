import XCTest
@testable import SwitchboardCore

final class TranscriptTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func write(_ entries: [[String: Any]], partialTail: String = "") throws {
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        for e in entries { handle.write(try JSONSerialization.data(withJSONObject: e) + Data("\n".utf8)) }
        handle.write(Data(partialTail.utf8))
        try handle.close()
    }

    func user(_ content: Any, ts: String = "2026-10-28T23:29:04.907Z") -> [String: Any] {
        ["type": "user", "timestamp": ts, "uuid": UUID().uuidString, "message": ["role": "user", "content": content]]
    }

    func assistant(_ blocks: [[String: Any]], id: String = "m1", out: Int = 10) -> [String: Any] {
        ["type": "assistant", "timestamp": "2026-10-28T23:29:08.000Z",
         "message": ["id": id, "role": "assistant", "content": blocks,
                     "usage": ["input_tokens": 2, "output_tokens": out, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 50]]]
    }

    func testFeedTodosFilesAndUsage() throws {
        try write([
            user("Add Stripe webhooks"),
            user("<command-name>/clear</command-name>"),
            assistant([["type": "text", "text": "## Plan\n- **First** step"]], id: "m1", out: 5),
            assistant([["type": "tool_use", "id": "t1", "name": "Edit", "input": ["file_path": "/r/api.ts", "old_string": "a", "new_string": "b"]]], id: "m1", out: 5),
            user([["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "no match"]]),
            assistant([["type": "tool_use", "id": "t2", "name": "TaskCreate", "input": ["subject": "Write tests"]]], id: "m2", out: 7),
            user([["type": "tool_result", "tool_use_id": "t2", "content": "Task #4 created successfully"]]),
            assistant([["type": "tool_use", "id": "t3", "name": "TaskUpdate", "input": ["taskId": "4", "status": "in_progress"]]], id: "m3"),
            assistant([["type": "tool_use", "id": "t4", "name": "Write", "input": ["file_path": "/r/new.ts", "content": "x"]]], id: "m4"),
            assistant([["type": "tool_use", "id": "t5", "name": "Edit", "input": ["file_path": "/r/api.ts", "old_string": "a", "new_string": "c"]]], id: "m5"),
        ])
        let s = TranscriptReader(path: url.path).update()
        XCTAssertEqual(s.prompts, 1, "tagged plumbing isn't a prompt")
        XCTAssertEqual(s.items.map(\.kind), [.prompt, .reply, .tool("Edit"), .tool("TaskCreate"), .tool("TaskUpdate"), .tool("Write"), .tool("Edit")])
        XCTAssertEqual(s.items[1].title, "Plan")
        XCTAssertTrue(s.items[2].failed)
        XCTAssertEqual(s.failedToolCalls, 1)
        XCTAssertEqual(s.todos, [TodoItem(id: "4", text: "Write tests", status: .inProgress)])
        XCTAssertEqual(s.files, [FileTouch(path: "/r/api.ts", edits: 2, added: 1, removed: 1), FileTouch(path: "/r/new.ts", edits: 1, added: 1, removed: 0)])
        XCTAssertEqual((s.linesAdded, s.linesRemoved).0, 2, "the failed edit doesn't count")
        XCTAssertEqual(s.linesRemoved, 1)
        XCTAssertEqual(s.tools.first, ToolStat(name: "Edit", calls: 2, failed: 1))
        XCTAssertEqual(s.tools.map(\.calls).reduce(0, +), s.toolCalls)
        XCTAssertEqual(s.requests, 5, "m1 counted once")
        XCTAssertEqual(s.inputTokens, 10)
        XCTAssertEqual(s.cacheReadTokens, 5000)
        XCTAssertEqual(s.cacheWriteTokens, 250)
        XCTAssertEqual(s.contextTokens, 1052)
        XCTAssertEqual(s.outputTokens, 5 + 7 + 10 + 10 + 10, "m1's usage counted once")
        XCTAssertEqual(s.toolCalls, 5)
    }

    /// The shapes Claude Code 2.1.316 records for a message sent through the reply hook.
    func testMessagesSentFromTheAppAppearInTheFeed() throws {
        let wrap = "<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command \"Stop\": The user replied from Switchboard. Treat this as their next message:\n\n"
        try write([user(wrap + "Say only KIWI\n\n</system-reminder>"),
                   user(wrap + "see it live\n\n&lt;/system-reminder&gt;\n</system-reminder>"),
                   user("<task-notification>\n<summary>Other</summary>\n</task-notification>")])
        let s = TranscriptReader(path: url.path).update()
        XCTAssertEqual(s.items.map(\.title), ["Say only KIWI", "see it live"])
        XCTAssertEqual(s.prompts, 2)
    }

    func testCostBreakdownByTypeModelAndPrompt() throws {
        func a(_ id: String, _ model: String, _ usage: [String: Any]) -> [String: Any] {
            ["type": "assistant", "timestamp": "2026-10-28T23:29:08.000Z",
             "message": ["id": id, "model": model, "role": "assistant", "content": [["type": "text", "text": "x"]], "usage": usage]]
        }
        let million = 1_000_000
        try write([
            a("m0", "<synthetic>", ["output_tokens": million]),
            user("first"),
            a("m1", "claude-opus-5-5", ["input_tokens": million, "output_tokens": million, "cache_read_input_tokens": million,
                                        "cache_creation_input_tokens": 2 * million,
                                        "cache_creation": ["ephemeral_5m_input_tokens": million, "ephemeral_1h_input_tokens": million]]),
            a("m1", "claude-opus-5-5", ["input_tokens": million, "output_tokens": million]),
            user("second"),
            a("m2", "claude-sonnet-5-5", ["output_tokens": million]),
            a("m3", "gpt-unknown", ["output_tokens": million]),
        ])
        let s = TranscriptReader(path: url.path).update()
        XCTAssertEqual(s.cost.input, 4, accuracy: 0.0001)
        XCTAssertEqual(s.cost.output, 30, accuracy: 0.0001)
        XCTAssertEqual(s.cost.cacheRead, 0.2, accuracy: 0.0001)
        XCTAssertEqual(s.cost.cacheWrite, 5 + 8, accuracy: 0.0001, "1.25x and 2x of $4")
        XCTAssertEqual(s.costByModel.map(\.model), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(s.turns.map(\.prompt), ["first", "second"])
        XCTAssertEqual(s.turns[1].cost, 10, accuracy: 0.0001)
        XCTAssertEqual(s.unpricedRequests, 1)
    }

    func testPriceLookupPrefersTheLongestName() {
        XCTAssertEqual(ModelPrice.lookup("claude-opus-5-5[1m]")?.input, 4)
        XCTAssertEqual(ModelPrice.lookup("claude-opus-5-20261001")?.input, 5)
        XCTAssertNil(ModelPrice.lookup("something-else"))
    }

    func testANSIParsing() {
        let runs = TerminalText.parseANSI("a\u{1B}[1;31mred\u{1B}[0m b\u{1B}[38;5;208mo\u{1B}[38;2;1;2;3mr\u{1B}[2Kz")
        XCTAssertEqual(runs, [TerminalRun(text: "a"), TerminalRun(text: "red", color: .indexed(1), bold: true), TerminalRun(text: " b"),
                              TerminalRun(text: "o", color: .indexed(208)), TerminalRun(text: "rz", color: .rgb(1, 2, 3))])
    }

    func testHighlightKeepsTheTextExactly() {
        let plain = "⏺ PONG\n  ⎿  done\n\n  12 + added\n  13 - gone\n✻ Thinking… (2s)\n❯ "
        let runs = TerminalText.highlightClaudeCode(plain)
        XCTAssertEqual(runs.map(\.text).joined(), plain)
        XCTAssertEqual(runs[0].color, .indexed(10))
        XCTAssertEqual(runs[3].color, .indexed(2))
        XCTAssertEqual(runs[4].color, .indexed(1))
    }

    func testLineChangeIgnoresQuotedContext() {
        let edit = TranscriptReader.lineChange("Edit", ["old_string": "keep\nold\nend\n", "new_string": "keep\nnew\nnewer\nend\n"])
        XCTAssertEqual(edit.added, 2)
        XCTAssertEqual(edit.removed, 1)
        XCTAssertEqual(TranscriptReader.lineChange("Write", ["content": "a\nb\n"]).added, 2)
        let multi = TranscriptReader.lineChange("MultiEdit", ["edits": [["old_string": "a", "new_string": "b"], ["old_string": "", "new_string": "c"]]])
        XCTAssertEqual(multi.added, 2)
        XCTAssertEqual(multi.removed, 1)
    }

    func testActiveTimeSkipsIdleGaps() throws {
        try write([user("one", ts: "2026-10-28T10:00:00.000Z"), user("two", ts: "2026-10-28T10:02:00.000Z"),
                   user("three", ts: "2026-10-28T18:00:00.000Z"), user("four", ts: "2026-10-28T18:01:00.000Z")])
        XCTAssertEqual(TranscriptReader(path: url.path).update().activeSeconds, 180)
    }

    func testIncrementalReadsAndPartialLines() throws {
        let reader = TranscriptReader(path: url.path)
        try write([user("one")], partialTail: "{\"type\":\"user\",\"message\":{\"content\":\"tw")
        XCTAssertEqual(reader.update().prompts, 1)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("o\"}}\n".utf8))
        try handle.close()
        let s = reader.update()
        XCTAssertEqual(s.items.map(\.title), ["one", "two"])
    }

    func testTodoWriteReplacesTheList() throws {
        try write([assistant([["type": "tool_use", "id": "t", "name": "TodoWrite", "input": ["todos": [
            ["content": "Read code", "status": "completed", "activeForm": "Reading"],
            ["content": "Fix bug", "status": "in_progress", "activeForm": "Fixing"],
        ]]]])])
        XCTAssertEqual(TranscriptReader(path: url.path).update().todos.map(\.status), [.completed, .inProgress])
    }

    func testDefaultPathMatchesClaudeCodesFolderNames() {
        XCTAssertTrue(TranscriptReader.defaultPath(cwd: "/Users/me/Desktop/switch_board.v2", sessionID: "abc")
            .hasSuffix("/.claude/projects/-Users-me-Desktop-switch-board-v2/abc.jsonl"))
    }

    /// Against a real transcript on this machine, if there is one: parses without choking and finds activity.
    func testRealTranscriptIfPresent() throws {
        let projects = NSHomeDirectory() + "/.claude/projects"
        guard let folder = try? FileManager.default.contentsOfDirectory(atPath: projects).first,
              let file = try? FileManager.default.contentsOfDirectory(atPath: projects + "/" + folder)
                .first(where: { $0.hasSuffix(".jsonl") }) else { throw XCTSkip("no transcripts here") }
        let s = TranscriptReader(path: "\(projects)/\(folder)/\(file)").update()
        XCTAssertLessThanOrEqual(s.items.count, TranscriptReader.maxItems)
    }
}
