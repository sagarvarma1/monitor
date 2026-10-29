import Foundation

public enum IdleMath {
    /// "2026-10-28" in the local time zone.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Splits an interval at local midnights so each day gets its own share.
    public static func splitByDay(_ interval: DateInterval, calendar: Calendar = .current) -> [(day: String, seconds: TimeInterval)] {
        var out: [(String, TimeInterval)] = []
        var cursor = interval.start
        while cursor < interval.end {
            let nextMidnight = calendar.startOfDay(for: cursor).addingTimeInterval(86_400)
            let end = min(nextMidnight, interval.end)
            out.append((dayKey(cursor, calendar: calendar), end.timeIntervalSince(cursor)))
            cursor = end
        }
        return out
    }

    /// Seconds of an ongoing wait that fall within today.
    public static func secondsToday(since start: Date, now: Date, calendar: Calendar = .current) -> TimeInterval {
        max(0, now.timeIntervalSince(max(start, calendar.startOfDay(for: now))))
    }

    /// "12s", "4m", "1h 05m"
    public static func format(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

public enum GitInfo {
    /// Current branch for a working directory, read straight from .git/HEAD (no git process).
    public static func branch(for cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: cwd)
        let fm = FileManager.default
        for _ in 0..<40 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // Worktree or submodule: ".git" is a file containing "gitdir: <path>".
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
                return trimmed.isEmpty ? nil : String(trimmed.prefix(7))  // detached HEAD
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
