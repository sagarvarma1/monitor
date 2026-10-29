import Foundation

/// Raw values double as sort order: red first, then yellow, then green.
public enum SessionStatus: Int, Codable, Comparable, Sendable {
    case blocked = 0   // red: permission prompt or question
    case review = 1    // yellow: turn finished, waiting for you
    case working = 2   // green

    public static func < (a: SessionStatus, b: SessionStatus) -> Bool { a.rawValue < b.rawValue }

    public var isWaiting: Bool { self != .working }
}

public struct Session: Equatable, Codable, Identifiable, Sendable {
    public var id: String
    public var cwd: String
    public var branch: String?
    public var status: SessionStatus
    /// One short line: what the session needs (or what it's doing, when green).
    public var need: String
    /// Full message shown when the row is expanded.
    public var detail: String
    /// When the session started waiting on the user. nil while working.
    public var waitingSince: Date?
    public var startedAt: Date
    public var lastEventAt: Date
    public var lastEvent: String
    /// pid of the Claude Code process (from the hook's $PPID), used to find its terminal.
    public var pid: Int32?
    /// Outstanding permission requests (tool_use_id, or "name:<tool>" when no id was sent).
    public var pendingPermissions: [String]
    /// Set while a PermissionRequest hook is waiting on Switchboard for an answer (Allow/Deny from the pill).
    public var decisionID: String?

    public init(id: String, cwd: String, branch: String? = nil, status: SessionStatus = .working,
                need: String = "", detail: String = "", waitingSince: Date? = nil,
                startedAt: Date, lastEventAt: Date, lastEvent: String = "",
                pid: Int32? = nil, pendingPermissions: [String] = [], decisionID: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.branch = branch
        self.status = status
        self.need = need
        self.detail = detail
        self.waitingSince = waitingSince
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.lastEvent = lastEvent
        self.pid = pid
        self.pendingPermissions = pendingPermissions
        self.decisionID = decisionID
    }

    public var name: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    public var displayName: String {
        if let branch, !branch.isEmpty { return "\(name) · \(branch)" }
        return name
    }
}

public extension Array where Element == Session {
    /// Red, then yellow, then green; within a color, longest idle first.
    func sortedForDisplay() -> [Session] {
        sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            switch (a.waitingSince, b.waitingSince) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.status == .working, a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
                return a.displayName < b.displayName
            }
        }
    }
}
