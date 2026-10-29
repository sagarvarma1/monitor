import XCTest
@testable import SwitchboardCore

final class ReducerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ name: String, at offset: TimeInterval = 0, _ extra: [String: Any] = [:]) -> HookEvent {
        var raw: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/code/api", "hook_event_name": name]
        raw.merge(extra) { $1 }
        return HookEvent(raw: raw, receivedAt: t0.addingTimeInterval(offset))
    }

    @discardableResult
    func run(_ events: [HookEvent], from start: Session? = nil) -> (Session?, [Transition]) {
        var s = start
        var transitions: [Transition] = []
        for e in events {
            let t = Reducer.apply(e, to: s, branch: "main")
            transitions.append(t)
            switch t.change {
            case .upsert(let new): s = new
            case .remove: s = nil
            case .ignore: break
            }
        }
        return (s, transitions)
    }

    func testNotificationTurnsRedAndStartsTimer() {
        let (s, ts) = run([
            event("UserPromptSubmit", ["prompt": "fix the bug"]),
            event("Notification", at: 10, ["message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"]),
        ])
        XCTAssertEqual(s?.status, .blocked)
        XCTAssertEqual(s?.need, "Claude needs your permission to use Bash")
        XCTAssertEqual(s?.waitingSince, t0.addingTimeInterval(10))
        XCTAssertTrue(ts[1].becameBlocked)
        XCTAssertEqual(s?.name, "api")
        XCTAssertEqual(s?.displayName, "api · main")
    }

    func testStopTurnsYellowThenPromptClearsAndRecordsIdle() {
        let (s, ts) = run([
            event("UserPromptSubmit", ["prompt": "go"]),
            event("Stop", at: 5, ["last_assistant_message": "Done. Summary..."]),
            event("UserPromptSubmit", at: 65, ["prompt": "next"]),
        ])
        XCTAssertEqual(ts[1].change.session?.status, .review)
        XCTAssertEqual(ts[1].change.session?.need, "Finished, ready for review")
        XCTAssertEqual(ts[1].change.session?.detail, "Done. Summary...")
        XCTAssertEqual(s?.status, .working)
        XCTAssertNil(s?.waitingSince)
        XCTAssertEqual(ts[2].endedWait?.duration, 60)
    }

    func testPermissionRequestThenPostToolUseClears() {
        let (s, ts) = run([
            event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm run migrate"], "tool_use_id": "t1"]),
            event("PermissionRequest", at: 1, ["tool_name": "Bash", "tool_input": ["command": "npm run migrate"], "tool_use_id": "t1"]),
            event("Notification", at: 7, ["message": "Claude needs your permission", "notification_type": "permission_prompt"]),
        ])
        XCTAssertEqual(s?.status, .blocked)
        XCTAssertEqual(s?.need, "Allow Bash: npm run migrate?", "later generic notification keeps the specific line")
        XCTAssertEqual(s?.waitingSince, t0.addingTimeInterval(1))
        XCTAssertTrue(ts[1].becameBlocked)
        XCTAssertFalse(ts[2].becameBlocked, "already red: no second notification")

        // A parallel tool finishing must not clear the pending prompt.
        let (s2, _) = run([event("PostToolUse", at: 8, ["tool_name": "Read", "tool_use_id": "t0"])], from: s)
        XCTAssertEqual(s2?.status, .blocked)
        let (s3, ts3) = run([event("PostToolUse", at: 20, ["tool_name": "Bash", "tool_use_id": "t1"])], from: s2)
        XCTAssertEqual(s3?.status, .working)
        XCTAssertEqual(ts3[0].endedWait?.duration, 19)
    }

    func testAskUserQuestionIsRed() {
        let (s, _) = run([
            event("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": [
                "questions": [["question": "Which database should I use?", "options": [["label": "Postgres"], ["label": "SQLite"]]]],
            ]]),
        ])
        XCTAssertEqual(s?.status, .blocked)
        XCTAssertEqual(s?.need, "Question: Which database should I use?")
        XCTAssertTrue(s?.detail.contains("• SQLite") ?? false)
    }

    func testIdlePromptDoesNotEscalateYellow() {
        let (s, ts) = run([
            event("Stop"),
            event("Notification", at: 60, ["message": "Claude is waiting for your input", "notification_type": "idle_prompt"]),
        ])
        XCTAssertEqual(s?.status, .review)
        XCTAssertEqual(s?.need, "Finished, ready for review")
        XCTAssertEqual(s?.waitingSince, t0)
        XCTAssertFalse(ts[1].becameBlocked)
    }

    func testTimerKeepsRunningFromYellowToRed() {
        let (s, _) = run([
            event("SessionStart", ["source": "startup"]),
            event("Notification", at: 30, ["message": "Needs input", "notification_type": "elicitation_dialog"]),
        ])
        XCTAssertEqual(s?.status, .blocked)
        XCTAssertEqual(s?.waitingSince, t0)
    }

    func testSessionEndRemovesAndRecordsIdle() {
        let (s, ts) = run([event("Stop"), event("SessionEnd", at: 42, ["reason": "prompt_input_exit"])])
        XCTAssertNil(s)
        XCTAssertEqual(ts[1].endedWait?.duration, 42)
        guard case .remove("s1") = ts[1].change else { return XCTFail("expected remove") }
    }

    func testCompactSessionStartKeepsStatus() {
        let (s, _) = run([event("UserPromptSubmit", ["prompt": "x"]), event("SessionStart", at: 3, ["source": "compact"])])
        XCTAssertEqual(s?.status, .working)
    }

    func testSorting() {
        func mk(_ id: String, _ st: SessionStatus, _ wait: TimeInterval?) -> Session {
            Session(id: id, cwd: "/x/\(id)", status: st, waitingSince: wait.map { t0.addingTimeInterval($0) },
                    startedAt: t0, lastEventAt: t0)
        }
        let sorted = [mk("g", .working, nil), mk("y1", .review, 50), mk("r1", .blocked, 30),
                      mk("y2", .review, 10), mk("r2", .blocked, 5)].sortedForDisplay()
        XCTAssertEqual(sorted.map(\.id), ["r2", "r1", "y2", "y1", "g"])
    }
}

final class SupportTests: XCTestCase {
    func testSplitByDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = ISO8601DateFormatter().date(from: "2026-10-27T23:30:00Z")!
        let parts = IdleMath.splitByDay(DateInterval(start: start, duration: 3600), calendar: cal)
        XCTAssertEqual(parts.map(\.day), ["2026-10-27", "2026-10-28"])
        XCTAssertEqual(parts.map(\.seconds), [1800, 1800])
    }

    func testHTTPParse() {
        let body = #"{"session_id":"a"}"#
        let raw = "POST /event HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\nX-Claude-PID: 42\r\n\r\n\(body)"
        guard case .complete(let req) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/event")
        XCTAssertEqual(req.headers["x-claude-pid"], "42")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), body)
        guard case .incomplete = HTTPRequest.parse(Data(raw.utf8.dropLast(3))) else { return XCTFail() }
    }

    func testDatabaseRoundTrip() throws {
        let path = NSTemporaryDirectory() + "sb-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try Database(path: path)
        let s = Session(id: "x", cwd: "/a/b", status: .blocked, need: "n", waitingSince: Date(), startedAt: Date(), lastEventAt: Date())
        db.save(s)
        db.addIdle(DateInterval(start: Date().addingTimeInterval(-30), duration: 30))
        let reopened = try Database(path: path)
        XCTAssertEqual(reopened.loadSessions().first?.id, "x")
        XCTAssertEqual(reopened.loadSessions().first?.status, .blocked)
        XCTAssertGreaterThan(reopened.idleSeconds(day: IdleMath.dayKey(Date())), 0)
        reopened.deleteSession("x")
        XCTAssertTrue(reopened.loadSessions().isEmpty)
    }

}

extension Transition.Change {
    var session: Session? { if case .upsert(let s) = self { return s }; return nil }
}

extension ReducerTests {
    func testIdleCompactionOfUnknownSessionIsIdleNotWorking() {
        let (s, _) = run([event("SessionStart", ["source": "compact"])])
        XCTAssertEqual(s?.status, .review)
        XCTAssertNotNil(s?.waitingSince)
    }

    func testCompactionKeepsKnownSessionsState() {
        let (s, _) = run([event("UserPromptSubmit", ["prompt": "go"]), event("SessionStart", at: 5, ["source": "compact"])])
        XCTAssertEqual(s?.status, .working)
    }

    func testDecisionIDLivesOnlyWhileThePromptIsUp() {
        let ask = event("PermissionRequest", at: 1, ["tool_name": "Bash", "tool_input": ["command": "ls"],
                                                    PermissionDecision.requestIDKey: "r1"])
        let (blocked, _) = run([event("UserPromptSubmit", ["prompt": "go"]), ask])
        XCTAssertEqual(blocked?.decisionID, "r1")
        let (done, _) = run([event("PostToolUse", at: 2, ["tool_name": "Bash"])], from: blocked)
        XCTAssertNil(done?.decisionID)
        XCTAssertEqual(done?.status, .working)
    }

    func testQuestionsNeverGetADecisionID() {
        let (s, _) = run([event("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": [:],
                                                      PermissionDecision.requestIDKey: "r1"])])
        XCTAssertEqual(s?.status, .blocked)
        XCTAssertNil(s?.decisionID)
    }

    func testDecisionBodies() throws {
        func decision(_ d: PermissionDecision, _ suggestions: Any? = nil) throws -> [String: Any] {
            let obj = try JSONSerialization.jsonObject(with: d.responseBody(suggestions: suggestions)) as? [String: Any]
            let out = try XCTUnwrap(obj?["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
            return try XCTUnwrap(out["decision"] as? [String: Any])
        }
        XCTAssertEqual(try decision(.allow)["behavior"] as? String, "allow")
        XCTAssertEqual(try decision(.deny)["behavior"] as? String, "deny")
        let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings"]
        XCTAssertEqual((try decision(.allowAlways, [rule])["updatedPermissions"] as? [Any])?.count, 1)
        XCTAssertNil(try decision(.allow, [rule])["updatedPermissions"])
    }
}
