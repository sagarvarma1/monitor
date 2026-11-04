import XCTest
@testable import SwitchboardCore

final class HookInstallerTests: XCTestCase {
    let userHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo mine"]]]

    func testInstallAddsEveryEventAndKeepsOtherSettings() {
        let before: [String: Any] = ["model": "opus", "hooks": ["PreToolUse": [userHook]]]
        let after = HookInstaller.installing(into: before)
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertEqual(HookInstaller.status(of: after), .installed)
        let pre = (after["hooks"] as? [String: Any])?["PreToolUse"] as? [Any]
        XCTAssertEqual(pre?.count, 2, "user's matcher kept, ours appended")
    }

    func testReinstallIsIdempotent() {
        let once = HookInstaller.installing(into: [:])
        let twice = HookInstaller.installing(into: once)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice))
    }

    func testSocketChangeIsOutdatedThenFixedByInstall() {
        let old = HookInstaller.installing(into: [:])
        XCTAssertEqual(HookInstaller.status(of: old, socket: #""/tmp/other.sock""#), .outdated)
        XCTAssertEqual(HookInstaller.status(of: HookInstaller.installing(into: old, socket: #""/tmp/other.sock""#), socket: #""/tmp/other.sock""#), .installed)
    }

    func testRemoveLeavesOnlyUserHooks() {
        let installed = HookInstaller.installing(into: ["hooks": ["PreToolUse": [userHook]]])
        let removed = HookInstaller.removing(from: installed)
        let hooks = removed["hooks"] as? [String: Any]
        XCTAssertEqual(hooks?.keys.sorted(), ["PreToolUse"])
        XCTAssertEqual(HookInstaller.status(of: removed), .notInstalled)
    }

    func testRemoveDropsEmptyHooksKey() {
        let removed = HookInstaller.removing(from: HookInstaller.installing(into: [:]))
        XCTAssertNil(removed["hooks"])
    }

    /// Our handler sharing a matcher with a user's handler: only ours goes.
    func testRemoveFromSharedMatcher() {
        let shared: [String: Any] = ["hooks": [["type": "command", "command": "echo mine"],
                                               ["type": "command", "command": HookInstaller.command()]]]
        let removed = HookInstaller.removing(from: ["hooks": ["Stop": [shared]]])
        let stop = (removed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual((stop?.first?["hooks"] as? [Any])?.count, 1)
    }

    func testCommandsMatchShellScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install-hooks.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        func scriptCommand(_ variable: String) throws -> String {
            let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("\(variable)=") })
            return String(line.dropFirst("\(variable)='".count).dropLast())
        }
        XCTAssertEqual(try scriptCommand("CMD"), HookInstaller.command())
        XCTAssertEqual(try scriptCommand("PERM_CMD"), HookInstaller.permissionCommand())
        XCTAssertEqual(try scriptCommand("REPLY_CMD"), HookInstaller.replyCommand())
    }

    func testStopGetsABackgroundReplyHandler() {
        let hooks = HookInstaller.installing(into: [:])["hooks"] as? [String: Any]
        let handlers = (hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(handlers?.count, 2)
        XCTAssertEqual(handlers?.last?["asyncRewake"] as? Bool, true)
        XCTAssertEqual(handlers?.last?["command"] as? String, HookInstaller.replyCommand())
    }

    /// The reply command really does what the hook contract needs: exit 2 + reply on stderr, or exit 0 silently.
    func testReplyCommandShellBehaviour() throws {
        func run(_ body: String) throws -> (Int32, String) {
            // Stand-in for curl that prints a canned body.
            let cmd = HookInstaller.replyCommand()
                .replacingOccurrences(of: #"curl -s --connect-timeout 0.2 -m 7190 -X POST -H "Content-Type: application/json" -H "X-Claude-PID: $PPID" --data-binary @- --unix-socket "$HOME/Library/Application Support/Switchboard/hook.sock" http://localhost/reply"#,
                                      with: "printf '%s' '\(body)'")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let replied = try run("also add tests")
        XCTAssertEqual(replied.0, 2)
        XCTAssertEqual(replied.1, "also add tests\n")
        XCTAssertEqual(try run("").0, 0)
    }

    func testPermissionRequestGetsTheWaitingCommand() {
        let hooks = HookInstaller.installing(into: [:])["hooks"] as? [String: Any]
        let handler = ((hooks?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(handler?["command"] as? String, HookInstaller.permissionCommand())
        XCTAssertEqual(handler?["timeout"] as? Int, 600)
    }

    /// Entries written by the previous version (fire-and-forget PermissionRequest) get upgraded on next launch.
    func testPreviousVersionIsOutdated() {
        var hooks: [String: Any] = [:]
        for event in HookInstaller.events {
            let command = event == "PermissionRequest" ? HookInstaller.permissionCommand() : HookInstaller.command()
            hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": 2]]]]
        }
        XCTAssertEqual(HookInstaller.status(of: ["hooks": hooks]), .outdated, "no reply handler yet")
    }

    func testOldPermissionHookIsOutdated() {
        var hooks: [String: Any] = [:]
        for event in HookInstaller.events {
            hooks[event] = [["hooks": [["type": "command", "command": HookInstaller.command(), "timeout": 2]]]]
        }
        XCTAssertEqual(HookInstaller.status(of: ["hooks": hooks]), .outdated)
    }

    func testFileRoundTripBacksUpAndRefusesInvalidJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")

        try Data("{\"theme\": \"dark\"}".utf8).write(to: url)
        XCTAssertTrue(try HookInstaller.install(settingsURL: url))
        XCTAssertFalse(try HookInstaller.install(settingsURL: url), "no-op when already installed")
        XCTAssertEqual(HookInstaller.status(settingsURL: url), .installed)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("switchboard-backup") }
        XCTAssertEqual(backups.count, 1)

        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try HookInstaller.install(settingsURL: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }
}
