import Foundation

/// Makes text that's about to be approved show what it really contains. Control characters, terminal escapes,
/// bidi overrides and zero-width characters can make a command read differently from what runs ("Trojan Source"),
/// or hide part of it entirely, so each one is replaced by a visible stand-in and counted.
public enum SafeText {
    public struct Revealed: Equatable, Sendable {
        public let text: String
        /// How many characters were hidden or could reorder text. Non-zero means "warn before Allow".
        public let hiddenCount: Int
    }

    public static func reveal(_ source: String) -> Revealed {
        let scalars = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var hidden = 0
        for (i, u) in scalars.enumerated() {
            let prev = i > 0 ? scalars[i - 1] : nil
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if let stand = standIn(u, prev: prev, next: next) {
                out.append(contentsOf: stand.unicodeScalars)
                hidden += 1
            } else {
                out.append(u)
            }
        }
        return Revealed(text: String(out), hiddenCount: hidden)
    }

    static func standIn(_ u: Unicode.Scalar, prev: Unicode.Scalar?, next: Unicode.Scalar?) -> String? {
        let v = u.value
        switch v {
        case 0x09, 0x0A:
            return nil
        case 0x0D:
            return next == "\n" ? nil : "␍"  // CRLF line endings are ordinary; a lone CR can overwrite a line
        case 0x00...0x1F:
            return String(Unicode.Scalar(0x2400 + v)!)  // control pictures: ␀ … ␛ (ESC) … ␟
        case 0x7F:
            return "␡"
        case 0x200D, 0xFE0E, 0xFE0F:
            // Joiners and variation selectors are part of normal emoji (👩‍💻, ❤️); anywhere else they hide.
            return prev?.properties.isEmoji == true ? nil : code(v)
        case 0x80...0x9F,                          // C1 controls
             0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F,
             0x200B...0x200F,                      // zero-width space/joiners, LRM/RLM
             0x2028, 0x2029,                       // line/paragraph separators
             0x202A...0x202E,                      // bidi embeddings and overrides
             0x2060...0x206F,                      // word joiner, invisible operators, bidi isolates
             0x3164, 0xFEFF, 0xFFA0, 0xFFF9...0xFFFB,
             0xFE00...0xFE0D,                      // variation selectors
             0xE0000...0xE007F,                    // tag characters ("ASCII smuggling")
             0xE0100...0xE01EF:                    // more variation selectors
            return code(v)
        default:
            return nil
        }
    }

    private static func code(_ v: UInt32) -> String { "⟨U+\(String(format: "%04X", v))⟩" }
}

/// Process-tree checks for hook connections.
public enum ProcessTree {
    /// True if `ancestor` is `pid` itself or one of its parents, within `depth` steps. `parent` returns a pid's
    /// parent pid, or nil if it can't be read.
    public static func isAncestor(_ ancestor: Int32, of pid: Int32, depth: Int = 16, parent: (Int32) -> Int32?) -> Bool {
        guard ancestor > 1, pid > 1 else { return false }
        var current = pid
        for _ in 0...depth {
            if current == ancestor { return true }
            guard let next = parent(current), next > 1, next != current else { return false }
            current = next
        }
        return false
    }
}

/// Which Claude Code process each session belongs to. Hooks run as children of their session's process, so once a
/// session is tied to a live process, a different process can't send events, permission prompts or reply hooks in
/// its name. That stops one session (say, one that read a prompt-injected web page) from impersonating another or
/// intercepting the messages you send to it. The tie moves on only when the old process has exited.
public struct SessionOwnership {
    private var owners: [String: (pid: Int32, since: Date)] = [:]
    private let isAlive: (Int32, Date) -> Bool

    /// `isAlive(pid, since)`: the process is running and started no later than `since` (so a recycled pid fails).
    public init(isAlive: @escaping (Int32, Date) -> Bool) {
        self.isAlive = isAlive
    }

    /// Whether an event for `session` from Claude Code process `pid` (nil: unverified) should be accepted.
    public mutating func admit(session: String, pid: Int32?, now: Date = Date()) -> Bool {
        if let owner = owners[session], owner.pid != pid, isAlive(owner.pid, owner.since) { return false }
        if let pid, owners[session]?.pid != pid {
            owners[session] = (pid, now)
            if owners.count > 2000 { owners = owners.filter { isAlive($0.value.pid, $0.value.since) } }
        }
        return true
    }
}

/// Files the app reads because a hook payload named them.
public enum PathPolicy {
    /// Transcripts are only read from Claude Code's and Codex's own folders, so a forged event can't point the
    /// Dashboard at some other file.
    public static func isAllowedTranscript(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix("/"), let resolved = canonical(path) else { return false }
        let roots = [home + "/.claude/projects", home + "/.codex/sessions"].compactMap { canonical($0).map { $0 + "/" } }
        return roots.contains { resolved.hasPrefix($0) }
    }

    /// The real path with every symlink and ".." resolved. The file itself may not exist yet (Claude Code writes a
    /// transcript after its first hooks), but its folder must.
    static func canonical(_ path: String) -> String? {
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        if let full = real(path) { return full }
        let name = (path as NSString).lastPathComponent
        guard name != "..", name != ".", let folder = real((path as NSString).deletingLastPathComponent) else { return nil }
        return folder + "/" + name
    }

    /// Opens `path` for reading only if it's a regular file: a FIFO or device named by a payload would otherwise
    /// block or never end.
    public static func openRegularFile(_ path: String) -> FileHandle? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// A small text file (like .git/HEAD), or nil if it isn't a regular file or is bigger than `limit`.
    public static func readSmallText(_ path: String, limit: Int = 64 * 1024) -> String? {
        guard let handle = openRegularFile(path), let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension PermissionDecision {
    /// What "Always" would add, in words, from a request's `permission_suggestions`; nil if it would add nothing
    /// (then Always is the same as Allow).
    public static func describeAlways(_ suggestions: Any?) -> String? {
        guard let list = suggestions as? [[String: Any]], !list.isEmpty else { return nil }
        var parts: [String] = []
        for s in list {
            let place = (s["destination"] as? String).map(destination) ?? ""
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let behavior = (s["behavior"] as? String) ?? "allow"
                let rules = (s["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
                    guard let tool = rule["toolName"] as? String else { return nil }
                    if let content = rule["ruleContent"] as? String, !content.isEmpty { return "\(tool)(\(content))" }
                    return tool
                }
                if !rules.isEmpty { parts.append("\(behavior.capitalized) \(rules.joined(separator: ", "))\(place)") }
            case "addDirectories":
                let dirs = (s["directories"] as? [String] ?? []).joined(separator: ", ")
                if !dirs.isEmpty { parts.append("Allow access to \(dirs)\(place)") }
            case "setMode":
                if let mode = s["mode"] as? String { parts.append("Switch to \(mode) mode\(place)") }
            default:
                parts.append("Apply Claude Code's suggested permission change\(place)")
            }
        }
        return parts.isEmpty ? nil : SafeText.reveal(parts.joined(separator: "; ")).text
    }

    private static func destination(_ d: String) -> String {
        switch d {
        case "localSettings": return " (this project, just you)"
        case "projectSettings": return " (this project, shared)"
        case "userSettings": return " (all your projects)"
        case "session": return " (this session)"
        default: return " (\(d))"
        }
    }
}
