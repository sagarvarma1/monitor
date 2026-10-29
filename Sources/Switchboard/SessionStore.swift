import Foundation
import SwitchboardCore

/// Main-thread model: applies hook events, persists to SQLite, publishes to the UI.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var serverError: String?
    var onBecameBlocked: ((Session) -> Void)?
    /// Sends an Allow/Deny to the waiting hook with this request id.
    var onDecide: ((String, PermissionDecision) -> Void)?
    /// Request ids that still have a prompt up; the server lets go of any other waiting hooks.
    var onActiveDecisionsChanged: ((Set<String>) -> Void)?
    /// Called after every change, so the UI can react (e.g. end a peek once that session no longer needs you).
    var onUpdate: (() -> Void)?
    /// A session just turned red: worth a peek.
    var onPeek: ((Session) -> Void)?
    /// A session just finished its turn (working -> waiting for review).
    var onFinished: ((Session) -> Void)?

    private let db: Database?
    private var idleTodayClosed: TimeInterval = 0
    private var idleDay = IdleMath.dayKey(Date())

    init(databasePath: String = Database.defaultPath) {
        do {
            db = try Database(path: databasePath)
        } catch {
            NSLog("Switchboard: database unavailable: %@", error.localizedDescription)
            db = nil
        }
        // Waiting hooks don't survive a restart, so neither do their Allow/Deny buttons.
        sessions = (db?.loadSessions() ?? []).map { var s = $0; s.decisionID = nil; return s }.sortedForDisplay()
        idleTodayClosed = db?.idleSeconds(day: idleDay) ?? 0
        pruneDeadSessions()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.pruneDeadSessions() }
    }

    var waitingCount: Int { sessions.filter { $0.status.isWaiting }.count }
    var blockedCount: Int { sessions.filter { $0.status == .blocked }.count }

    func apply(_ event: HookEvent) {
        guard let id = event.sessionID else { return }
        let existing = sessions.first { $0.id == id }
        let cwd = event.cwd.isEmpty ? (existing?.cwd ?? "") : event.cwd
        let transition = Reducer.apply(event, to: existing, branch: GitInfo.branch(for: cwd))

        if let wait = transition.endedWait {
            db?.addIdle(wait)
            refreshIdleTotal()
        }
        switch transition.change {
        case .ignore:
            return
        case .remove(let id):
            sessions.removeAll { $0.id == id }
            db?.deleteSession(id)
        case .upsert(let session):
            if let i = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[i] = session
            } else {
                sessions.append(session)
            }
            db?.save(session)
            if transition.becameBlocked {
                onBecameBlocked?(session)
                onPeek?(session)
            } else if session.status == .review, existing?.status == .working,
                      event.name == "Stop" || event.name == "StopFailure" {
                onFinished?(session)
            }
        }
        sessions = sessions.sortedForDisplay()
        changed()
    }

    /// Answers a session's permission prompt from the pill. The UI updates right away; the hook events that
    /// follow (PostToolUse, or Claude carrying on after a deny) confirm it.
    func decide(_ sessionID: String, _ decision: PermissionDecision) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), let requestID = sessions[i].decisionID else { return }
        NSLog("Switchboard: %@ for %@", decision.rawValue, sessions[i].name)
        onDecide?(requestID, decision)
        var s = sessions[i]
        if let start = s.waitingSince, Date() > start {
            db?.addIdle(DateInterval(start: start, end: Date()))
            refreshIdleTotal()
        }
        s.status = .working
        s.waitingSince = nil
        s.pendingPermissions = []
        s.decisionID = nil
        s.need = decision == .deny ? "Denied from Switchboard" : "Approved from Switchboard"
        s.detail = ""
        sessions[i] = s
        db?.save(s)
        sessions = sessions.sortedForDisplay()
        changed()
    }

    /// The waiting hook went away (answered in the terminal); the session stays red until its next event says otherwise.
    func requestGone(_ requestID: String) {
        guard let i = sessions.firstIndex(where: { $0.decisionID == requestID }) else { return }
        sessions[i].decisionID = nil
        db?.save(sessions[i])
        changed()
    }

    /// Drops sessions whose Claude Code process exited without a SessionEnd (closed terminal, crash, reboot).
    func pruneDeadSessions() {
        for s in sessions {
            if let pid = s.pid, !TerminalFocus.isAlive(pid, startedBy: s.lastEventAt) { dismiss(s.id) }
        }
    }

    private func changed() {
        onActiveDecisionsChanged?(Set(sessions.compactMap(\.decisionID)))
        onUpdate?()
    }

    /// Manually remove a row (e.g. a session killed without a SessionEnd hook).
    func dismiss(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let start = session.waitingSince, Date() > start {
            db?.addIdle(DateInterval(start: start, end: Date()))
            refreshIdleTotal()
        }
        sessions.removeAll { $0.id == id }
        db?.deleteSession(id)
        changed()
    }

    /// Idle seconds today: finished waits from the DB plus the live part of ongoing waits.
    func idleToday(now: Date = Date()) -> TimeInterval {
        if IdleMath.dayKey(now) != idleDay { refreshIdleTotal() }
        let ongoing = sessions.compactMap(\.waitingSince).reduce(0) { $0 + IdleMath.secondsToday(since: $1, now: now) }
        return idleTodayClosed + ongoing
    }

    private func refreshIdleTotal() {
        idleDay = IdleMath.dayKey(Date())
        idleTodayClosed = db?.idleSeconds(day: idleDay) ?? 0
    }

    func snapshotJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        struct Snapshot: Encodable { let sessions: [Session]; let idleTodaySeconds: Double }
        return (try? encoder.encode(Snapshot(sessions: sessions, idleTodaySeconds: idleToday().rounded()))) ?? Data("{}".utf8)
    }
}
