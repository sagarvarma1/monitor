import CryptoKit
import Foundation

/// Token-based APNs auth: an ES256 JWT signed with the team's .p8 key. Apple accepts a token for an hour and
/// throttles fresh ones, so callers should reuse it (see `APNsToken.current`).
public struct APNsToken {
    public let keyID: String
    public let teamID: String
    private let key: P256.Signing.PrivateKey
    private var cached: (token: String, issued: Date)?

    public init(keyID: String, teamID: String, p8: String) throws {
        self.keyID = keyID
        self.teamID = teamID
        key = try P256.Signing.PrivateKey(pemRepresentation: p8)
    }

    /// Reused for 50 minutes, then re-signed.
    public mutating func current(now: Date = Date()) throws -> String {
        if let cached, now.timeIntervalSince(cached.issued) < 50 * 60 { return cached.token }
        let token = try sign(issuedAt: now)
        cached = (token, now)
        return token
    }

    public func sign(issuedAt: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)],
                                                options: [.sortedKeys])
        let input = header.base64URL + "." + claims.base64URL
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + signature.rawRepresentation.base64URL
    }
}

/// Live Activity push payloads (`apns-push-type: liveactivity`).
public enum LiveActivityPush {
    public struct Alert {
        public var title: String
        public var body: String
        public var sound: Bool
        public init(title: String, body: String, sound: Bool) {
            self.title = title
            self.body = body
            self.sound = sound
        }
    }

    /// Push-to-start: creates the Live Activity on the phone without the app running (iOS 17.2+).
    public static func start(_ state: LiveState, attributesType: String, attributes: [String: Any],
                             alert: Alert, now: Date = Date()) throws -> Data {
        var aps = try base("start", state, now: now)
        aps["attributes-type"] = attributesType
        aps["attributes"] = attributes
        aps["alert"] = alertObject(alert)
        return try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }

    /// An alert lights up the Lock Screen and expands the Dynamic Island briefly; without one the update is silent.
    public static func update(_ state: LiveState, alert: Alert?, now: Date = Date()) throws -> Data {
        var aps = try base("update", state, now: now)
        if let alert { aps["alert"] = alertObject(alert) }
        return try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }

    public static func end(_ state: LiveState, dismissAfter: TimeInterval = 0, now: Date = Date()) throws -> Data {
        var aps = try base("end", state, now: now)
        aps["dismissal-date"] = Int(now.addingTimeInterval(dismissAfter).timeIntervalSince1970)
        return try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }

    private static func base(_ event: String, _ state: LiveState, now: Date) throws -> [String: Any] {
        let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        return ["event": event, "timestamp": Int(now.timeIntervalSince1970), "content-state": content]
    }

    private static func alertObject(_ alert: Alert) -> [String: Any] {
        var obj: [String: Any] = ["title": alert.title, "body": alert.body]
        if alert.sound { obj["sound"] = "default" }
        return obj
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
