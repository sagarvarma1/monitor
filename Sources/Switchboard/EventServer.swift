import Foundation
import Network
import SwitchboardCore

/// Listens on 127.0.0.1:7777 for hook POSTs. /event replies immediately so hooks never wait on the UI;
/// /permission is held open until the user answers from the pill (or the prompt is resolved some other way).
final class EventServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "switchboard.server")
    private let onEvent: (HookEvent) -> Void
    private let snapshot: () -> Data
    var onStateChange: ((String?) -> Void)?
    /// A waiting permission hook went away on its own (answered in the terminal, or Claude Code gave up on it).
    var onRequestGone: ((String) -> Void)?

    private struct PendingPermission {
        let conn: NWConnection
        let suggestions: Any?
    }
    /// Waiting PermissionRequest hooks by request id. Only touched on `queue`.
    private var pending: [String: PendingPermission] = [:]
    /// Waiting background Stop hooks (reply from the pill), one per session id. Only touched on `queue`.
    private var replies: [String: NWConnection] = [:]
    /// A session can now (true) or can no longer (false) be replied to from the pill.
    var onReplyAvailable: ((String, Bool) -> Void)?
    /// Events that mean the user (or Claude) has moved on from the finished turn, so a waiting reply hook is moot.
    private static let movedOn: Set<String> = ["UserPromptSubmit", "PreToolUse", "SessionStart", "SessionEnd"]

    init(port: UInt16, onEvent: @escaping (HookEvent) -> Void, snapshot: @escaping () -> Data) {
        self.port = port
        self.onEvent = onEvent
        self.snapshot = snapshot
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.report(nil)
                case .failed(let err): self.report("Can't listen on port \(self.port): \(err.localizedDescription)")
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            report("Can't listen on port \(port): \(error.localizedDescription)")
        }
    }

    private func report(_ error: String?) {
        if let error { NSLog("Switchboard: %@", error) }
        DispatchQueue.main.async { self.onStateChange?(error) }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
        // Drop connections that never finish sending (a waiting permission hook is allowed to stay).
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let held = self.pending.values.contains { $0.conn === conn } || self.replies.values.contains { $0 === conn }
            if !held { conn.cancel() }
        }
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.respond(conn, to: request)
            case .invalid:
                self.send(conn, HTTPRequest.response(status: 400, reason: "Bad Request", body: Data("bad request\n".utf8)))
            case .incomplete:
                if isComplete || error != nil { conn.cancel() } else { self.receive(conn, buffer: buffer) }
            }
        }
    }

    private func respond(_ conn: NWConnection, to request: HTTPRequest) {
        switch (request.method, request.path) {
        case ("POST", "/event"):
            let pid = request.headers["x-claude-pid"].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil }
            guard let event = HookEvent(json: request.body, pid: pid) else {
                send(conn, HTTPRequest.response(status: 400, reason: "Bad Request", body: Data("invalid json\n".utf8)))
                return
            }
            send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data("ok\n".utf8)))
            if let sid = event.sessionID, Self.movedOn.contains(event.name) { releaseReply(sid) }
            DispatchQueue.main.async { self.onEvent(event) }
        case ("POST", "/reply"):
            guard let sid = HookEvent(json: request.body)?.sessionID else {
                send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data()))
                return
            }
            releaseReply(sid, notify: false)  // a newer turn's hook replaces an older one
            replies[sid] = conn
            watchForHangup(conn) { [weak self] in
                guard let self, self.replies[sid] === conn else { return }
                self.replies[sid] = nil
                DispatchQueue.main.async { self.onReplyAvailable?(sid, false) }
            }
            DispatchQueue.main.async { self.onReplyAvailable?(sid, true) }
        case ("POST", "/permission"):
            let pid = request.headers["x-claude-pid"].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil }
            guard let event = HookEvent(json: request.body, pid: pid) else {
                send(conn, HTTPRequest.response(status: 400, reason: "Bad Request", body: Data("invalid json\n".utf8)))
                return
            }
            // Questions and plan approvals need a real answer in the terminal, so never hold those.
            guard !Reducer.blockingTools.contains(event.toolName) else {
                send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data()))
                DispatchQueue.main.async { self.onEvent(event) }
                return
            }
            let id = UUID().uuidString
            var raw = event.raw
            raw[PermissionDecision.requestIDKey] = id
            let tagged = HookEvent(raw: raw, receivedAt: event.receivedAt, pid: event.pid)
            pending[id] = PendingPermission(conn: conn, suggestions: raw["permission_suggestions"])
            watchForHangup(conn) { [weak self] in
                guard let self, self.pending.removeValue(forKey: id) != nil else { return }
                DispatchQueue.main.async { self.onRequestGone?(id) }
            }
            DispatchQueue.main.async { self.onEvent(tagged) }
        case ("GET", "/sessions"):
            let body = DispatchQueue.main.sync { snapshot() }
            send(conn, HTTPRequest.response(status: 200, reason: "OK", body: body, contentType: "application/json"))
        case ("GET", "/health"):
            send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data("switchboard ok\n".utf8)))
        default:
            send(conn, HTTPRequest.response(status: 404, reason: "Not Found", body: Data("not found\n".utf8)))
        }
    }

    /// Answers a waiting permission hook (a no-op if it has already gone away). Async: /sessions syncs onto main
    /// from this queue, so main must never sync onto it.
    func decide(_ id: String, _ decision: PermissionDecision) {
        queue.async {
            guard let p = self.pending.removeValue(forKey: id) else { return }
            self.send(p.conn, HTTPRequest.response(status: 200, reason: "OK",
                                                   body: decision.responseBody(suggestions: p.suggestions),
                                                   contentType: "application/json"))
        }
    }

    /// Lets go of waiting hooks whose prompt is no longer up, with an empty reply (no decision).
    func release(except active: Set<String>) {
        queue.async {
            for (id, p) in self.pending where !active.contains(id) {
                self.pending[id] = nil
                self.send(p.conn, HTTPRequest.response(status: 200, reason: "OK", body: Data()))
            }
        }
    }

    /// Sends text typed into the pill to the session's waiting Stop hook, which wakes Claude with it.
    func reply(to sessionID: String, _ text: String) {
        queue.async {
            guard let conn = self.replies.removeValue(forKey: sessionID) else { return }
            let message = "The user replied from Switchboard. Treat this as their next message:\n\n" + text
            self.send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data(message.utf8)))
        }
    }

    /// Lets a waiting reply hook finish with no reply (exit 0, nothing happens). Call on `queue`.
    private func releaseReply(_ sessionID: String, notify: Bool = true) {
        guard let conn = replies.removeValue(forKey: sessionID) else { return }
        send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data()))
        if notify { DispatchQueue.main.async { self.onReplyAvailable?(sessionID, false) } }
    }

    /// A read on a held connection only completes when the client hangs up (curl killed or timed out).
    private func watchForHangup(_ conn: NWConnection, onHangup: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            conn.cancel()
            onHangup()
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}
