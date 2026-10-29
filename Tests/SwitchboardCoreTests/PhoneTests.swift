import CryptoKit
import XCTest
@testable import SwitchboardCore

final class PhoneTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ id: String, _ status: SessionStatus, waiting: TimeInterval? = nil) -> Session {
        Session(id: id, cwd: "/code/\(id)", branch: "main", status: status, need: "need \(id)",
                waitingSince: waiting.map { t0.addingTimeInterval(-$0) }, startedAt: t0, lastEventAt: t0)
    }

    func testLiveStateOrdersCountsAndCaps() {
        let sessions = [session("a", .working), session("b", .blocked, waiting: 10), session("c", .review, waiting: 99),
                        session("d", .working), session("e", .working)]
        let state = LiveState.make(from: sessions, replyable: ["c"])
        XCTAssertEqual(state.sessions.map(\.id).prefix(2), ["b", "c"])
        XCTAssertEqual(state.sessions.count, LiveState.limit)
        XCTAssertEqual([state.blocked, state.review, state.working], [1, 1, 3])
        XCTAssertEqual(state.headline, "1 needs you")
        XCTAssertTrue(state.sessions[1].canReply)
        XCTAssertFalse(state.sessions[0].canReply)
    }

    /// ActivityKit decodes content-state with a default JSONDecoder, so it must round-trip that way.
    func testLiveStateRoundTripsThroughDefaultCoders() throws {
        let state = LiveState.make(from: [session("b", .blocked, waiting: 10)], replyable: [])
        XCTAssertEqual(try JSONDecoder().decode(LiveState.self, from: JSONEncoder().encode(state)), state)
    }

    func testPushPayloadsAreSmallAndShapedForActivityKit() throws {
        let many = (0..<20).map { session("session-\($0)", .blocked, waiting: Double($0)) }
        let state = LiveState.make(from: many, replyable: [])
        let start = try LiveActivityPush.start(state, attributesType: "SwitchboardActivityAttributes",
                                               attributes: ["title": "Switchboard"],
                                               alert: .init(title: "t", body: "b", sound: true), now: t0)
        XCTAssertLessThan(start.count, 4096)
        let aps = try XCTUnwrap((try JSONSerialization.jsonObject(with: start) as? [String: Any])?["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "start")
        XCTAssertEqual(aps["attributes-type"] as? String, "SwitchboardActivityAttributes")
        XCTAssertEqual(aps["timestamp"] as? Int, 1_800_000_000)
        XCTAssertNotNil(aps["content-state"] as? [String: Any])

        let silent = try JSONSerialization.jsonObject(with: LiveActivityPush.update(state, alert: nil, now: t0)) as? [String: Any]
        XCTAssertNil((silent?["aps"] as? [String: Any])?["alert"])
        let end = try JSONSerialization.jsonObject(with: LiveActivityPush.end(state, dismissAfter: 60, now: t0)) as? [String: Any]
        XCTAssertEqual((end?["aps"] as? [String: Any])?["dismissal-date"] as? Int, 1_800_000_060)
    }

    /// What ActivityKit does with a push: pull out content-state and decode it as the ContentState type.
    func testPushedContentStateDecodesAsLiveState() throws {
        let state = LiveState.make(from: [session("b", .blocked, waiting: 10), session("c", .review, waiting: 5)], replyable: ["c"])
        let payload = try LiveActivityPush.update(state, alert: nil, now: t0)
        let aps = (try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["aps"] as? [String: Any]
        let content = try JSONSerialization.data(withJSONObject: try XCTUnwrap(aps?["content-state"]))
        XCTAssertEqual(try JSONDecoder().decode(LiveState.self, from: content), state)
    }

    func testJWTVerifiesWithTheKeysPublicHalf() throws {
        let key = P256.Signing.PrivateKey()
        var token = try APNsToken(keyID: "ABC123DEFG", teamID: "2NM47V54SX", p8: key.pemRepresentation)
        let jwt = try token.current(now: t0)
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String]
        XCTAssertEqual(header?["kid"], "ABC123DEFG")
        XCTAssertEqual(header?["alg"], "ES256")
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any]
        XCTAssertEqual(claims?["iss"] as? String, "2NM47V54SX")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        XCTAssertEqual(try token.current(now: t0.addingTimeInterval(600)), jwt, "reused within the hour")
    }

    func testCommandsMapToDecisions() {
        XCTAssertEqual(PhoneCommand(kind: .allowAlways, sessionID: "s").decision, .allowAlways)
        XCTAssertNil(PhoneCommand(kind: .reply, sessionID: "s", text: "hi").decision)
    }
}
