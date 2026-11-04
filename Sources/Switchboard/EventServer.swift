import Darwin
import Foundation
import SwitchboardCore

/// Listens on a Unix socket for hook POSTs (curl --unix-socket). Not TCP: a localhost port can be reached by every
/// account on the Mac and by web pages, and while the app is closed any program could take the port and answer
/// permission prompts. The socket lives in a 0700 folder, and every connection's user id is checked.
/// /event replies at once; /permission and /reply are held open until the user answers (or it stops mattering).
final class EventServer {
    private let path: String
    private var listener: DispatchSourceRead?
    private let queue = DispatchQueue(label: "switchboard.server")
    private let onEvent: (HookEvent) -> Void
    private let snapshot: () -> Data
    var onStateChange: ((String?) -> Void)?
    /// A waiting permission hook went away on its own (answered in the terminal, or Claude Code gave up on it).
    var onRequestGone: ((String) -> Void)?

    private struct PendingPermission {
        let conn: HookConnection
        let suggestions: Any?
    }
    /// Waiting PermissionRequest hooks by request id. Only touched on `queue`.
    private var pending: [String: PendingPermission] = [:]
    /// Waiting background Stop hooks (reply from the pill), one per session id. Only touched on `queue`.
    private var replies: [String: HookConnection] = [:]
    /// A session can now (true) or can no longer (false) be replied to from the pill.
    var onReplyAvailable: ((String, Bool) -> Void)?
    /// Events that mean the user (or Claude) has moved on from the finished turn, so a waiting reply hook is moot.
    private static let movedOn: Set<String> = ["UserPromptSubmit", "PreToolUse", "SessionStart", "SessionEnd"]

    init(path: String, onEvent: @escaping (HookEvent) -> Void, snapshot: @escaping () -> Data) {
        self.path = path
        self.onEvent = onEvent
        self.snapshot = snapshot
    }

    func start() {
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        chmod(folder, 0o700)
        unlink(path)  // a socket left by a crash

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return report("Socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return report("Can't create the hook socket: \(String(cString: strerror(errno)))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            return report("Can't listen on \(path): \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        report(nil)
    }

    private func acceptAll(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)  // another account on this Mac
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handle(HookConnection(fd: fd, queue: queue))
        }
    }

    private func report(_ error: String?) {
        if let error { NSLog("Switchboard: %@", error) }
        DispatchQueue.main.async { self.onStateChange?(error) }
    }

    private func handle(_ conn: HookConnection) {
        var buffer = Data()
        conn.onData = { [weak self, unowned conn] data in
            guard let self else { return }
            buffer.append(data)
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                conn.onData = nil  // a held connection's next event is the client hanging up
                self.respond(conn, to: request)
            case .invalid:
                self.send(conn, HTTPRequest.response(status: 400, reason: "Bad Request", body: Data("bad request\n".utf8)))
            case .incomplete:
                break
            }
        }
        conn.start()
        // Drop connections that never finish sending (a waiting permission or reply hook is allowed to stay).
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let held = self.pending.values.contains { $0.conn === conn } || self.replies.values.contains { $0 === conn }
            if !held { conn.cancel() }
        }
    }

    private func respond(_ conn: HookConnection, to request: HTTPRequest) {
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
            conn.onClose = { [weak self, unowned conn] in
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
            conn.onClose = { [weak self] in
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
            let message = ChatMessage.replyPrefix + text
            self.send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data(message.utf8)))
        }
    }

    /// Lets a waiting reply hook finish with no reply (exit 0, nothing happens). Call on `queue`.
    private func releaseReply(_ sessionID: String, notify: Bool = true) {
        guard let conn = replies.removeValue(forKey: sessionID) else { return }
        send(conn, HTTPRequest.response(status: 200, reason: "OK", body: Data()))
        if notify { DispatchQueue.main.async { self.onReplyAvailable?(sessionID, false) } }
    }

    private func send(_ conn: HookConnection, _ data: Data) {
        conn.onClose = nil
        conn.send(data)
    }
}

/// One accepted connection. Reads arrive on the server's queue; the socket closes on `send` or `cancel`, or when
/// the client hangs up (which calls `onClose`). Retained by its dispatch source until then.
final class HookConnection {
    private let fd: Int32
    private let source: DispatchSourceRead
    private var closed = false
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { self.readAvailable() }  // strong on purpose: released when the source is cancelled
        source.setCancelHandler { close(fd) }
    }

    func start() { source.resume() }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &bytes, bytes.count)
        if n > 0 {
            onData?(Data(bytes[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            let wasOpen = !closed
            let hangup = onClose
            cancel()
            if wasOpen { hangup?() }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        cancel()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        onData = nil
        onClose = nil
        source.cancel()
    }
}
