import Foundation

/// A Claude Code hook payload. Payloads vary by event, so fields are read lazily from the raw JSON.
public struct HookEvent {
    public let raw: [String: Any]
    public let receivedAt: Date
    public let pid: Int32?

    public init(raw: [String: Any], receivedAt: Date = Date(), pid: Int32? = nil) {
        self.raw = raw
        self.pid = pid
        // Test hook: the fake-event script can backdate events so idle timers have realistic values.
        if let ts = raw["switchboard_ts"] as? Double {
            self.receivedAt = Date(timeIntervalSince1970: ts)
        } else {
            self.receivedAt = receivedAt
        }
    }

    public init?(json: Data, receivedAt: Date = Date(), pid: Int32? = nil) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        self.init(raw: obj, receivedAt: receivedAt, pid: pid)
    }

    public func string(_ key: String) -> String? { raw[key] as? String }

    public var sessionID: String? { string("session_id") }
    public var name: String { string("hook_event_name") ?? "" }
    public var cwd: String { string("cwd") ?? "" }
    public var toolName: String { string("tool_name") ?? "" }
    public var toolInput: [String: Any] { raw["tool_input"] as? [String: Any] ?? [:] }
    public var toolUseID: String? { string("tool_use_id") }
}
