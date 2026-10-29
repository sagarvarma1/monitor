import Foundation

/// What the iPhone shows: a small, push-sized summary of the sessions. Used as the Live Activity's content state,
/// so it travels in APNs payloads (4 KB max) and is decoded by ActivityKit with a default JSONDecoder; times are
/// plain epoch seconds to avoid any date-strategy mismatch.
public struct LiveSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var branch: String?
    /// `SessionStatus.rawValue`: 0 blocked, 1 review, 2 working.
    public var status: Int
    public var need: String
    public var waitingSince: Double?
    /// Set while a permission prompt can be answered (from the pill or the phone).
    public var decisionID: String?
    public var canReply: Bool

    public init(id: String, name: String, branch: String?, status: Int, need: String,
                waitingSince: Double?, decisionID: String?, canReply: Bool) {
        self.id = id
        self.name = name
        self.branch = branch
        self.status = status
        self.need = need
        self.waitingSince = waitingSince
        self.decisionID = decisionID
        self.canReply = canReply
    }

    public var sessionStatus: SessionStatus { SessionStatus(rawValue: status) ?? .working }
}

public struct LiveState: Codable, Hashable, Sendable {
    /// Most urgent first, at most `LiveState.limit`.
    public var sessions: [LiveSession]
    public var blocked: Int
    public var review: Int
    public var working: Int

    public static let limit = 4

    public init(sessions: [LiveSession], blocked: Int, review: Int, working: Int) {
        self.sessions = sessions
        self.blocked = blocked
        self.review = review
        self.working = working
    }

    public static func make(from sessions: [Session], replyable: Set<String>) -> LiveState {
        let sorted = sessions.sortedForDisplay()
        let live = sorted.prefix(limit).map { s in
            LiveSession(id: s.id, name: s.name, branch: s.branch, status: s.status.rawValue,
                        need: Summarizer.oneLine(s.need, max: 80),
                        waitingSince: s.waitingSince?.timeIntervalSince1970,
                        decisionID: s.decisionID, canReply: replyable.contains(s.id))
        }
        return LiveState(sessions: Array(live),
                         blocked: sorted.filter { $0.status == .blocked }.count,
                         review: sorted.filter { $0.status == .review }.count,
                         working: sorted.filter { $0.status == .working }.count)
    }

    public var isEmpty: Bool { blocked + review + working == 0 }

    /// The pill's label: the most urgent color wins.
    public var headline: String {
        if blocked > 0 { return "\(blocked) need\(blocked == 1 ? "s" : "") you" }
        if review > 0 { return "\(review) to review" }
        if working > 0 { return "\(working) working" }
        return "No sessions"
    }

    public var worst: SessionStatus? { sessions.first?.sessionStatus }
}

/// Names shared by the Mac and the phone for the iCloud (CloudKit) records they exchange.
public enum CloudSchema {
    public static let container = "iCloud.com.sagarvarma.switchboard"
    public static let zone = "Switchboard"

    /// Mac -> phone: one per session, record name = session id.
    public static let sessionType = "SBSession"
    /// Mac -> phone: record name "mac", `lastSeen` refreshed while the Mac app runs.
    public static let macType = "SBMac"
    /// Phone -> Mac: Allow/Deny/reply, deleted by the Mac once applied.
    public static let commandType = "SBCommand"
    /// Phone -> Mac: one per phone, its Live Activity push tokens.
    public static let deviceType = "SBDevice"
}

/// A phone's request, as stored in an SBCommand record.
public struct PhoneCommand: Equatable, Sendable {
    public enum Kind: String, Sendable { case allow, allowAlways, deny, reply }
    public var kind: Kind
    public var sessionID: String
    public var decisionID: String?
    public var text: String?

    public init(kind: Kind, sessionID: String, decisionID: String? = nil, text: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.decisionID = decisionID
        self.text = text
    }

    public var decision: PermissionDecision? {
        switch kind {
        case .allow: return .allow
        case .allowAlways: return .allowAlways
        case .deny: return .deny
        case .reply: return nil
        }
    }
}
