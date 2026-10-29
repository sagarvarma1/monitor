import Foundation

/// Adds and removes Switchboard's hooks in Claude Code's settings.json, the same way install-hooks.sh does:
/// other hooks are left alone, and our entries are recognised by the trailing "# switchboard" marker.
public enum HookInstaller {
    public enum Status: Equatable {
        case installed
        /// Some of our entries exist but don't match this version (different port or event list).
        case outdated
        case notInstalled
        case invalidSettings(String)
    }

    /// Kept in sync with install-hooks.sh.
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                                "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]
    public static let marker = "# switchboard"

    public static var defaultSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    /// Byte-for-byte the commands install-hooks.sh writes, so the script and the app recognise each other's entries.
    /// Fire-and-forget: a 0.5s cap, so a closed or hung app never slows Claude Code down.
    public static func command(port: Int) -> String {
        "curl -s -o /dev/null --connect-timeout 0.2 -m 0.5 -X POST -H \"Content-Type: application/json\" "
            + "-H \"X-Claude-PID: $PPID\" --data-binary @- http://127.0.0.1:\(port)/event >/dev/null 2>&1 || true \(marker)"
    }

    /// PermissionRequest waits for an Allow/Deny from the pill and prints it as the hook's decision. Claude Code shows
    /// its own prompt meanwhile, and whichever answer comes first wins. If the app isn't running, curl fails at once
    /// and prints nothing, which leaves the normal prompt in charge.
    public static func permissionCommand(port: Int) -> String {
        "curl -s --connect-timeout 0.2 -m \(permissionTimeout - 10) -X POST -H \"Content-Type: application/json\" "
            + "-H \"X-Claude-PID: $PPID\" --data-binary @- http://127.0.0.1:\(port)/permission 2>/dev/null || true \(marker)"
    }

    public static let permissionTimeout = 600

    /// A second Stop handler that runs in the background (`asyncRewake`), so the turn ends normally. It waits for a
    /// reply typed into the pill; if one comes, it prints it to stderr and exits 2, which wakes Claude with it.
    /// Typing in the terminal instead makes the app release it with an empty reply (exit 0, nothing happens).
    public static func replyCommand(port: Int) -> String {
        "r=$(curl -s --connect-timeout 0.2 -m \(replyTimeout - 10) -X POST -H \"Content-Type: application/json\" "
            + "-H \"X-Claude-PID: $PPID\" --data-binary @- http://127.0.0.1:\(port)/reply 2>/dev/null); "
            + "[ -n \"$r\" ] && { printf \"%s\\n\" \"$r\" >&2; exit 2; }; exit 0 \(marker)"
    }

    /// How long after a turn ends you can still reply from the pill.
    public static let replyTimeout = 7200

    static func handlers(event: String, port: Int) -> [[String: Any]] {
        switch event {
        case "PermissionRequest":
            return [["type": "command", "command": permissionCommand(port: port), "timeout": permissionTimeout]]
        case "Stop":
            return [["type": "command", "command": command(port: port), "timeout": 2],
                    ["type": "command", "command": replyCommand(port: port), "timeout": replyTimeout, "asyncRewake": true]]
        default:
            return [["type": "command", "command": command(port: port), "timeout": 2]]
        }
    }

    private static func expectedCommands(port: Int) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: events.map { event in
            (event, Set(handlers(event: event, port: port).compactMap { $0["command"] as? String }))
        })
    }

    // MARK: Pure transforms

    public static func status(of settings: [String: Any], port: Int) -> Status {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let expected = expectedCommands(port: port)
        var found: [String: [String]] = [:]
        for (event, value) in hooks {
            let ours = ourCommands(in: value)
            if !ours.isEmpty { found[event] = ours }
        }
        if found.isEmpty { return .notInstalled }
        // Exactly the expected commands per event, each once: anything else is a previous version or a mangled copy.
        let exact = found.count == expected.count && expected.allSatisfy { event, commands in
            let have = found[event] ?? []
            return have.count == commands.count && Set(have) == commands
        }
        return exact ? .installed : .outdated
    }

    public static func installing(into settings: [String: Any], port: Int) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            hooks[event] = (hooks[event] as? [Any] ?? []) + [["hooks": handlers(event: event, port: port)]]
        }
        settings["hooks"] = hooks
        return settings
    }

    public static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let matchers = value as? [Any] else { continue }
            let kept: [Any] = matchers.compactMap { matcher in
                guard var m = matcher as? [String: Any], let handlers = m["hooks"] as? [Any] else { return matcher }
                let others = handlers.filter { !isOurs($0) }
                if others.count == handlers.count { return matcher }
                if others.isEmpty { return nil }
                m["hooks"] = others
                return m
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private static func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.hasSuffix(marker) == true
    }

    private static func ourCommands(in eventValue: Any) -> [String] {
        (eventValue as? [Any] ?? []).flatMap { matcher -> [String] in
            ((matcher as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { handler in
                isOurs(handler) ? (handler as? [String: Any])?["command"] as? String : nil
            }
        }
    }

    // MARK: Files

    public static func status(settingsURL: URL = defaultSettingsURL, port: Int) -> Status {
        do { return status(of: try read(settingsURL), port: port) } catch { return .invalidSettings(error.localizedDescription) }
    }

    /// Installs (or updates) our hooks. Backs the file up first; does nothing if already installed.
    @discardableResult
    public static func install(settingsURL: URL = defaultSettingsURL, port: Int) throws -> Bool {
        let settings = try read(settingsURL)
        guard status(of: settings, port: port) != .installed else { return false }
        try write(installing(into: settings, port: port), to: settingsURL)
        return true
    }

    public static func uninstall(settingsURL: URL = defaultSettingsURL) throws {
        let settings = try read(settingsURL)
        guard status(of: settings, port: 0) != .notInstalled else { return }
        try write(removing(from: settings), to: settingsURL)
    }

    /// A missing or empty file reads as {}; anything that isn't a JSON object is an error, and we never touch it.
    static func read(_ url: URL) throws -> [String: Any] {
        let path = url.resolvingSymlinksInPath().path
        guard let data = FileManager.default.contents(atPath: path), !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) else {
            return [:]
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Switchboard.HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not valid JSON; not touching it."])
        }
        return obj
    }

    static func write(_ settings: [String: Any], to url: URL) throws {
        let target = url.resolvingSymlinksInPath()  // write through a symlinked settings file, not over it
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                    formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            var backup = target.path + ".switchboard-backup-\(stamp)"
            if fm.fileExists(atPath: backup) { backup += "-\(getpid())" }
            try fm.copyItem(atPath: target.path, toPath: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        // In place (not atomic) so the file keeps its permissions, like the shell script.
        try data.write(to: target)
    }
}
