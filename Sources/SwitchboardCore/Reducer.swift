import Foundation

/// The result of applying one hook event to a session.
public struct Transition {
    public enum Change { case upsert(Session), remove(String), ignore }
    public var change: Change
    /// True when the session just turned red (and wasn't red before): triggers the macOS notification + pill pulse.
    public var becameBlocked = false
    /// A finished waiting interval to add to the daily idle total.
    public var endedWait: DateInterval?
}

/// Pure state machine: hook event + current session -> new session.
public enum Reducer {
    /// Questions and plan approvals that block on the user, even though they arrive as tool calls.
    public static let blockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Notification types that mean "blocked on you". Unknown types are treated as blocking too.
    static let ignoredNotificationTypes: Set<String> = [
        "auth_success", "elicitation_complete", "elicitation_response", "agent_completed",
        "quota_auto_resume_fired", "quota_auto_resume_stale", "quota_auto_resume_disabled", "plugin_notification",
    ]

    public static func apply(_ e: HookEvent, to existing: Session?, branch: String?) -> Transition {
        guard let id = e.sessionID, !id.isEmpty else { return Transition(change: .ignore) }
        let now = e.receivedAt

        if e.name == "SessionEnd" {
            guard let existing else { return Transition(change: .ignore) }
            return Transition(change: .remove(id), endedWait: wait(from: existing.waitingSince, to: now))
        }

        var s = existing ?? Session(id: id, cwd: e.cwd, status: .working, need: "Working", startedAt: now, lastEventAt: now)
        let before = s
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        s.branch = branch
        s.lastEventAt = now
        s.lastEvent = e.name
        if let pid = e.pid { s.pid = pid }

        switch e.name {
        case "SessionStart":
            if e.string("source") == "compact" {
                // Idle compaction fires this between turns. A session we're meeting for the first time this way
                // is sitting at its prompt, not working; one we already know keeps its state.
                if existing == nil { setWaiting(&s, .review, need: "Idle, waiting for your prompt", detail: "", now: now) }
                break
            }
            s.pendingPermissions = []
            setWaiting(&s, .review, need: "New session, waiting for your prompt",
                       detail: e.string("model").map { "Model: \($0)" } ?? "", now: now)

        case "UserPromptSubmit":
            let prompt = e.string("prompt") ?? ""
            s.pendingPermissions = []
            setWorking(&s, need: prompt.isEmpty ? "Working" : "Working on: \(Summarizer.oneLine(prompt, max: 70))", detail: prompt)

        case "PreToolUse":
            if blockingTools.contains(e.toolName) {
                block(&s, tool: e.toolName, input: e.toolInput, now: now)
            } else {
                // A new tool call means Claude has moved past any earlier prompt.
                s.pendingPermissions = []
                let call = Summarizer.toolCall(e.toolName, e.toolInput)
                setWorking(&s, need: "Running \(call)", detail: Summarizer.prettyJSON(e.toolInput))
            }

        case "PermissionRequest":
            let key = e.toolUseID ?? "name:\(e.toolName)"
            if !s.pendingPermissions.contains(key) { s.pendingPermissions.append(key) }
            if blockingTools.contains(e.toolName) {
                block(&s, tool: e.toolName, input: e.toolInput, now: now)
            } else {
                let detail = "Claude wants to use \(e.toolName):\n\n" + Summarizer.prettyJSON(e.toolInput)
                setWaiting(&s, .blocked, need: "Allow \(Summarizer.toolCall(e.toolName, e.toolInput))?", detail: detail, now: now)
                s.decisionID = e.string(PermissionDecision.requestIDKey)
            }

        case "PostToolUse", "PostToolUseFailure":
            // Only clear red once every outstanding permission prompt has resolved
            // (a parallel tool can finish while another is still waiting on you).
            s.pendingPermissions.removeAll { $0 == e.toolUseID || $0 == "name:\(e.toolName)" }
            if s.status.isWaiting && s.pendingPermissions.isEmpty {
                setWorking(&s, need: "Working", detail: "")
            }

        case "Notification":
            let type = e.string("notification_type") ?? ""
            let message = e.string("message") ?? "Claude needs your attention"
            if type == "idle_prompt" {
                if s.status == .working {
                    setWaiting(&s, .review, need: Summarizer.oneLine(message), detail: message, now: now)
                }
            } else if !ignoredNotificationTypes.contains(type) {
                if s.status == .blocked && !s.pendingPermissions.isEmpty {
                    // Already red with a more specific line from PermissionRequest; keep it.
                    break
                }
                let title = e.string("title").map { "\($0)\n\n" } ?? ""
                setWaiting(&s, .blocked, need: Summarizer.oneLine(message), detail: title + message, now: now)
            }

        case "Stop":
            s.pendingPermissions = []
            let last = e.string("last_assistant_message") ?? ""
            setWaiting(&s, .review, need: "Finished, ready for review", detail: last, now: now)

        case "StopFailure":
            s.pendingPermissions = []
            let err = e.string("last_assistant_message") ?? e.string("error") ?? "Stopped with an error"
            setWaiting(&s, .review, need: "Stopped: \(Summarizer.oneLine(err, max: 70))", detail: err, now: now)

        default:
            break
        }

        // An answer from the pill only makes sense while that prompt is still up.
        if s.status != .blocked || s.pendingPermissions.isEmpty { s.decisionID = nil }

        var t = Transition(change: .upsert(s))
        t.becameBlocked = s.status == .blocked && (existing == nil || before.status != .blocked)
        if before.waitingSince != nil && s.waitingSince == nil {
            t.endedWait = wait(from: before.waitingSince, to: now)
        }
        return t
    }

    private static func block(_ s: inout Session, tool: String, input: [String: Any], now: Date) {
        if tool == "ExitPlanMode" {
            let plan = input["plan"] as? String ?? ""
            setWaiting(&s, .blocked, need: "Plan ready for your approval", detail: plan, now: now)
        } else {
            let q = Summarizer.question(input)
            setWaiting(&s, .blocked, need: "Question: \(q.line)", detail: q.detail, now: now)
        }
    }

    private static func setWaiting(_ s: inout Session, _ status: SessionStatus, need: String, detail: String, now: Date) {
        s.status = status
        s.need = need
        s.detail = detail
        // The idle timer counts from when it first started waiting on you, across red/yellow changes.
        if s.waitingSince == nil { s.waitingSince = now }
    }

    private static func setWorking(_ s: inout Session, need: String, detail: String) {
        s.status = .working
        s.need = need
        s.detail = detail
        s.waitingSince = nil
    }

    private static func wait(from start: Date?, to end: Date) -> DateInterval? {
        guard let start, end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}
