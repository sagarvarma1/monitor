import XCTest
@testable import SwitchboardCore

/// The guarantees SECURITY.md promises, one test each where code can show it.
final class SecurityTests: XCTestCase {

    // MARK: SafeText

    func testBidiOverrideIsRevealedAndCounted() {
        // "Trojan Source": U+202E makes "rm -rf ~ #txt.etad" display as "rm -rf ~ #date.txt"-ish.
        let r = SafeText.reveal("ls \u{202E}txt.hs\u{202C} file")
        XCTAssertEqual(r.hiddenCount, 2)
        XCTAssertEqual(r.text, "ls ⟨U+202E⟩txt.hs⟨U+202C⟩ file")
    }

    func testZeroWidthAndTagCharactersAreRevealed() {
        XCTAssertEqual(SafeText.reveal("cu\u{200B}rl").text, "cu⟨U+200B⟩rl")
        XCTAssertEqual(SafeText.reveal("a\u{E0041}\u{E0042}").hiddenCount, 2)  // invisible "AB" in tag characters
        XCTAssertEqual(SafeText.reveal("\u{FEFF}x").hiddenCount, 1)
    }

    func testTerminalEscapesAndControlsAreRevealed() {
        let r = SafeText.reveal("echo hi\u{1B}[2K\rrm -rf /\u{7}")
        XCTAssertEqual(r.text, "echo hi␛[2K␍rm -rf /␇")
        XCTAssertEqual(r.hiddenCount, 3)
    }

    func testOrdinaryTextIsUntouched() {
        let text = "git commit -m \"Fix 🐛 in café ❤️ 👩‍💻\"\n\tnext line\r\nwindows line"
        let r = SafeText.reveal(text)
        XCTAssertEqual(r.hiddenCount, 0)
        XCTAssertEqual(r.text, text)
    }

    func testJoinerOutsideEmojiIsRevealed() {
        XCTAssertEqual(SafeText.reveal("ab\u{200D}c").hiddenCount, 1)
        XCTAssertEqual(SafeText.reveal("ab\u{FE0F}c").hiddenCount, 1)
    }

    func testPermissionNeedLineIsRevealed() {
        let raw: [String: Any] = ["session_id": "s1", "cwd": "/tmp/p", "hook_event_name": "PermissionRequest",
                                  "tool_name": "Bash", "tool_input": ["command": "ls\u{202E}x"]]
        guard case .upsert(let s) = Reducer.apply(HookEvent(raw: raw), to: nil, branch: nil).change else { return XCTFail() }
        XCTAssertTrue(s.need.contains("⟨U+202E⟩"), s.need)
    }

    // MARK: Who's connecting

    func testClaimedPIDMustBeAnAncestor() {
        // claude 100 -> sh 200 -> curl 300; another process 900 -> 1
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 1, 900: 1]
        let parent: (Int32) -> Int32? = { pid in parents[pid] }
        XCTAssertTrue(ProcessTree.isAncestor(100, of: 300, parent: parent))
        XCTAssertTrue(ProcessTree.isAncestor(300, of: 300, parent: parent))
        XCTAssertFalse(ProcessTree.isAncestor(900, of: 300, parent: parent))
        XCTAssertFalse(ProcessTree.isAncestor(1, of: 300, parent: parent))
        XCTAssertFalse(ProcessTree.isAncestor(100, of: 0, parent: parent))
    }

    func testAncestorWalkStopsOnCycles() {
        XCTAssertFalse(ProcessTree.isAncestor(5, of: 10, parent: { $0 == 10 ? 11 : 10 }))
    }

    func testSessionBelongsToItsLiveProcess() {
        var alive: Set<Int32> = [100, 200]
        var owners = SessionOwnership(isAlive: { pid, _ in alive.contains(pid) })
        XCTAssertTrue(owners.admit(session: "s1", pid: 100))
        XCTAssertTrue(owners.admit(session: "s1", pid: 100))
        XCTAssertFalse(owners.admit(session: "s1", pid: 200), "another live session can't speak for s1")
        XCTAssertFalse(owners.admit(session: "s1", pid: nil), "an unverified sender can't either")
        XCTAssertTrue(owners.admit(session: "s2", pid: 200))
        alive.remove(100)  // s1's process exited; a resumed session takes over
        XCTAssertTrue(owners.admit(session: "s1", pid: 300))
        alive.insert(300)
        XCTAssertFalse(owners.admit(session: "s1", pid: 100))
    }

    func testUnboundSessionsAcceptUnverifiedEvents() {
        var owners = SessionOwnership(isAlive: { _, _ in true })
        XCTAssertTrue(owners.admit(session: "demo", pid: nil))
    }

    // MARK: Files a payload can name

    func testTranscriptPathsAreConfinedToAgentFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.claude/projects/p", withIntermediateDirectories: true)
        XCTAssertTrue(PathPolicy.isAllowedTranscript(home + "/.claude/projects/p/s.jsonl", home: home))
        try FileManager.default.createDirectory(atPath: home + "/.codex/sessions/2026", withIntermediateDirectories: true)
        XCTAssertTrue(PathPolicy.isAllowedTranscript(home + "/.codex/sessions/2026/rollout-1.jsonl", home: home))
        XCTAssertFalse(PathPolicy.isAllowedTranscript(home + "/.codex/sessions/missing/rollout-1.jsonl", home: home))
        XCTAssertFalse(PathPolicy.isAllowedTranscript(home + "/.claude/projects/../../.ssh/id.jsonl", home: home))
        XCTAssertFalse(PathPolicy.isAllowedTranscript(home + "/.ssh/id_rsa", home: home))
        XCTAssertFalse(PathPolicy.isAllowedTranscript("relative/.claude/projects/x.jsonl", home: home))
        // A symlink inside the folder that points out of it doesn't count either.
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/projects/p/out.jsonl", withDestinationPath: "/etc/hosts")
        XCTAssertFalse(PathPolicy.isAllowedTranscript(home + "/.claude/projects/p/out.jsonl", home: home))
    }

    func testDefaultTranscriptPathCantEscapeWithTheSessionID() {
        let path = TranscriptReader.defaultPath(cwd: "/x", sessionID: "../../../.ssh/id")
        XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory() + "/.claude/projects/"))
    }

    func testReducerIgnoresTranscriptPathsOutsideAgentFolders() {
        let raw: [String: Any] = ["session_id": "s1", "cwd": "/tmp/p", "hook_event_name": "UserPromptSubmit",
                                  "prompt": "hi", "transcript_path": "/etc/passwd.jsonl"]
        guard case .upsert(let s) = Reducer.apply(HookEvent(raw: raw), to: nil, branch: nil).change else { return XCTFail() }
        XCTAssertNil(s.transcriptPath)
    }

    func testOnlyRegularFilesAreOpened() throws {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("fifo-\(UUID().uuidString)").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        defer { unlink(fifo) }
        XCTAssertNil(PathPolicy.openRegularFile(fifo), "a FIFO would block the reader forever")
        XCTAssertNil(PathPolicy.openRegularFile("/dev/zero"))
        XCTAssertNil(PathPolicy.readSmallText("/dev/urandom"))
    }

    // MARK: Always Allow

    func testAlwaysRuleIsDescribed() {
        let suggestions: [[String: Any]] = [
            ["type": "addRules", "behavior": "allow", "destination": "localSettings",
             "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]],
            ["type": "addDirectories", "directories": ["/tmp/x"], "destination": "session"],
        ]
        XCTAssertEqual(PermissionDecision.describeAlways(suggestions),
                       "Allow Bash(npm test:*) (this project, just you); Allow access to /tmp/x (this session)")
        XCTAssertNil(PermissionDecision.describeAlways(nil))
        XCTAssertNil(PermissionDecision.describeAlways([] as [Any]))
    }

    func testAlwaysRuleRevealsHiddenCharacters() {
        let suggestions: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "ls\u{202E}:*"]]]]
        XCTAssertTrue(PermissionDecision.describeAlways(suggestions)?.contains("⟨U+202E⟩") == true)
    }

    // MARK: Hooks posing as Switchboard

    func testForeignCommandsUsingTheSocketAreFound() {
        var settings = HookInstaller.installing(into: [:])
        var hooks = settings["hooks"] as! [String: Any]
        hooks["PreToolUse"] = (hooks["PreToolUse"] as! [Any]) + [["hooks": [
            ["type": "command", "command": "curl --unix-socket \"$HOME/Library/Application Support/Switchboard/hook.sock\" http://x/permission"],
            ["type": "command", "command": "echo unrelated"],
        ]]]
        settings["hooks"] = hooks
        XCTAssertEqual(HookInstaller.foreignSocketCommands(in: settings).count, 1)
        XCTAssertEqual(HookInstaller.foreignSocketCommands(in: HookInstaller.installing(into: [:])), [])
    }
}
