import XCTest
@testable import SwitchboardCore

/// Random and malformed input for every parser that sees data from hooks, transcripts or terminals. Each must
/// return (no crash, no hang) on anything. Seeded, so a failure reproduces; bump `iterations` to search harder.
final class FuzzTests: XCTestCase {
    let iterations = 3000

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    var rng = SplitMix(state: 0x5157_4348_424F_4152)

    /// Bytes biased toward the characters each parser cares about, so the fuzz reaches past the first branch.
    func bytes(_ max: Int, alphabet: [UInt8]) -> Data {
        let count = Int.random(in: 0...max, using: &rng)
        return Data((0..<count).map { _ in
            Bool.random(using: &rng) ? alphabet.randomElement(using: &rng)! : UInt8.random(in: 0...255, using: &rng)
        })
    }

    func text(_ max: Int, alphabet: String) -> String {
        let pieces: [String] = alphabet.unicodeScalars.map { String($0) } + ["\u{202E}", "\u{200D}", "\u{1B}", "\u{0}", "\u{FE0F}", "\u{E0041}", "🧑‍💻", "\r"]
        let count = Int.random(in: 0...max, using: &rng)
        var out = String.UnicodeScalarView()
        for _ in 0..<count {
            if Int.random(in: 0..<4, using: &rng) == 0, let u = Unicode.Scalar(UInt32.random(in: 0...0x10FFFF, using: &rng)) {
                out.append(u)
            } else {
                out.append(contentsOf: pieces.randomElement(using: &rng)!.unicodeScalars)
            }
        }
        return String(out)
    }

    func testHTTPRequestParser() {
        let alphabet = Array("POST /event HTTP/1.1\r\nContent-Length: 12\r\n\r\n{}:-0123456789".utf8)
        for _ in 0..<iterations {
            _ = HTTPRequest.parse(bytes(600, alphabet: alphabet))
            // Valid head, hostile lengths and bodies.
            let length = ["0", "-1", "99999999999999999999", "2097153", "5", "abc", ""].randomElement(using: &rng)!
            let head = "POST /permission HTTP/1.1\r\nContent-Length: \(length)\r\nX-Claude-PID: \(Int.random(in: -5...99999, using: &rng))\r\n\r\n"
            _ = HTTPRequest.parse(Data(head.utf8) + bytes(64, alphabet: alphabet))
        }
    }

    func testOversizedHeaderIsRejectedNotBuffered() {
        if case .incomplete = HTTPRequest.parse(Data(repeating: 0x41, count: 70_000)) { XCTFail("should give up on a 70 KB header") }
    }

    func testANSIParser() {
        for _ in 0..<iterations {
            let runs = TerminalText.parseANSI(text(300, alphabet: "\u{1B}[0;1;3;4;38;5;255;48;2;1;2;3;m;0123456789 ab"))
            _ = runs.count
            _ = TerminalText.highlightClaudeCode(text(300, alphabet: "⏺⎿✻>│╭╰ \n abc"))
        }
    }

    func testMarkdownParser() {
        for _ in 0..<iterations {
            _ = MarkdownBlock.parse(text(400, alphabet: "#*_`[]()>-|\n 1.abc```~"))
        }
    }

    func testSafeTextNeverLosesVisibleText() {
        for _ in 0..<iterations {
            let input = text(200, alphabet: "abc 123\n\t")
            let r = SafeText.reveal(input)
            XCTAssertEqual(SafeText.reveal(r.text).hiddenCount, 0, "revealed text must itself be clean")
        }
    }

    func testHookEventsThroughTheReducer() {
        let names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                     "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd", "SubagentStart", "Bogus"]
        func value(_ depth: Int) -> Any {
            switch Int.random(in: 0..<(depth > 2 ? 4 : 6), using: &rng) {
            case 0: return text(40, alphabet: "abc/.\n")
            case 1: return Int.random(in: Int.min...Int.max, using: &rng)
            case 2: return Double.random(in: -1e300...1e300, using: &rng)
            case 3: return NSNull()
            case 4: return (0..<Int.random(in: 0...4, using: &rng)).map { _ in value(depth + 1) }
            default:
                var d: [String: Any] = [:]
                for key in ["command", "file_path", "questions", "options", "label", "message", "rules", "type", "x"].shuffled(using: &rng).prefix(3) {
                    d[key] = value(depth + 1)
                }
                return d
            }
        }
        var session: Session?
        for _ in 0..<iterations {
            var raw: [String: Any] = ["session_id": "s1", "hook_event_name": names.randomElement(using: &rng)!]
            for key in ["cwd", "tool_name", "tool_input", "prompt", "message", "transcript_path", "source",
                        "permission_suggestions", "last_assistant_message", "notification_type", "tool_use_id"] where Bool.random(using: &rng) {
                raw[key] = value(0)
            }
            if Bool.random(using: &rng) { raw["tool_name"] = ["Bash", "AskUserQuestion", "ExitPlanMode", "Edit"].randomElement(using: &rng)! }
            switch Reducer.apply(HookEvent(raw: raw), to: session, branch: nil).change {
            case .upsert(let s): session = s
            case .remove: session = nil
            case .ignore: break
            }
            _ = PermissionDecision.describeAlways(raw["permission_suggestions"])
        }
        // And raw bytes as JSON.
        for _ in 0..<iterations { _ = HookEvent(json: bytes(200, alphabet: Array("{}[]\":,0truefalsnul".utf8))) }
    }

    func testTranscriptReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = TranscriptReader(path: url.path)
        let handle = try FileHandle(forWritingTo: url)
        let templates = [
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/a","old_string":"x","new_string":"y\nz"}}],"usage":{"input_tokens":-5,"output_tokens":1e308}}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":null}]}}"#,
            #"{"type":"user","timestamp":"not a date","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"content":"not an array","model":7}}"#,
        ]
        for i in 0..<400 {
            var line = Data(templates.randomElement(using: &rng)!.utf8)
            if Bool.random(using: &rng) { line = bytes(120, alphabet: Array("{}[]\":,\n".utf8)) }
            handle.write(line + Data((i % 7 == 0 ? "" : "\n").utf8))
            if i % 20 == 0 { _ = reader.update() }
        }
        try handle.truncate(atOffset: 10)  // a rewritten file starts over
        _ = reader.update()
        try handle.close()
    }
}
