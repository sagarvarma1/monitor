import Foundation

/// An answer to a PermissionRequest hook, sent back as the hook's stdout.
public enum PermissionDecision: String, Sendable {
    case allow, allowAlways, deny

    /// Added to a PermissionRequest event's raw JSON by the server, so the session knows which waiting hook to answer.
    public static let requestIDKey = "switchboard_request_id"

    /// The hook output JSON. `suggestions` is the request's `permission_suggestions`, applied for "always allow"
    /// (e.g. an allow rule for this command, so Claude Code stops asking).
    public func responseBody(suggestions: Any?) -> Data {
        var decision: [String: Any]
        switch self {
        case .allow:
            decision = ["behavior": "allow"]
        case .allowAlways:
            decision = ["behavior": "allow"]
            if let suggestions = suggestions as? [Any], !suggestions.isEmpty { decision["updatedPermissions"] = suggestions }
        case .deny:
            decision = ["behavior": "deny", "message": "The user denied this from Switchboard."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }
}
