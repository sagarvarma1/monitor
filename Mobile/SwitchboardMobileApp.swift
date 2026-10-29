import ActivityKit
import CloudKit
import SwiftUI
import SwitchboardCore
import UIKit

@main
struct SwitchboardMobileApp: App {
    @StateObject private var model = SessionsModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            SessionsView(model: model)
                .onOpenURL { model.open($0) }
                .task {
                    LiveActivityTokens.shared.start()
                    #if DEBUG
                    if CommandLine.arguments.contains("-demoLiveActivity") { LiveActivityTokens.shared.startNow(with: .demo) }
                    #endif
                }
        }
        .onChange(of: phase) { _, phase in model.setActive(phase == .active) }
    }
}

/// Sessions as the Mac mirrors them into iCloud, refreshed every couple of seconds while the app is open.
@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [LiveSession] = []
    @Published private(set) var macName: String?
    @Published private(set) var macLastSeen: Date?
    @Published private(set) var error: String?
    @Published var replying: LiveSession?
    /// Prompts answered from here; hidden until the Mac's update arrives.
    @Published private(set) var answered: Set<String> = []

    private var byID: [String: LiveSession] = [:]
    private var token: CKServerChangeToken?
    private var active = false
    private var pendingReplyID: String?

    func setActive(_ isActive: Bool) {
        #if DEBUG
        // Screenshots without a Mac or iCloud.
        if CommandLine.arguments.contains("-demoLiveActivity") { sessions = .demo; return }
        #endif
        guard isActive != active else { return }
        active = isActive
        if isActive { Task { await loop() } }
    }

    private func loop() async {
        while active {
            await refresh()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func refresh() async {
        do {
            let changes = try await Cloud.changes(since: token)
            token = changes.token
            for record in changes.changed {
                if let s = Cloud.liveSession(record) {
                    byID[s.id] = s
                } else if record.recordType == CloudSchema.macType {
                    macLastSeen = record["lastSeen"] as? Date
                    macName = record["name"] as? String
                }
            }
            for deletion in changes.deleted where deletion.type == CloudSchema.sessionType {
                byID[deletion.id.recordName] = nil
            }
            sessions = byID.values.sorted { a, b in
                a.status != b.status ? a.status < b.status : (a.waitingSince ?? .infinity) < (b.waitingSince ?? .infinity)
            }
            answered = answered.filter { id in sessions.contains { $0.decisionID == id } }
            if let id = pendingReplyID, let s = byID[id], s.canReply { pendingReplyID = nil; replying = s }
            error = nil
        } catch {
            self.error = (error as? CKError)?.code == .notAuthenticated
                ? "Sign in to iCloud to see your Mac's sessions." : error.localizedDescription
        }
    }

    var macOnline: Bool { macLastSeen.map { Date().timeIntervalSince($0) < 180 } ?? false }

    func decide(_ session: LiveSession, _ kind: PhoneCommand.Kind) {
        guard let decisionID = session.decisionID else { return }
        answered.insert(decisionID)
        Task { try? await Cloud.send(PhoneCommand(kind: kind, sessionID: session.id, decisionID: decisionID)) }
    }

    func reply(_ session: LiveSession, _ text: String) {
        replying = nil
        Task { try? await Cloud.send(PhoneCommand(kind: .reply, sessionID: session.id, text: text)) }
    }

    /// switchboard://reply/<id> (from the Live Activity) opens the reply sheet once that session has loaded.
    func open(_ url: URL) {
        guard url.scheme == "switchboard", url.host == "reply", let id = url.pathComponents.last else { return }
        if let s = byID[id], s.canReply { replying = s } else { pendingReplyID = id }
    }
}

/// Reports this phone's Live Activity push tokens to the Mac through iCloud: the push-to-start token (so the Mac
/// can start the activity remotely) and the current activity's update token.
@MainActor
final class LiveActivityTokens {
    static let shared = LiveActivityTokens()

    private var started = false
    private var pushToStart: String?
    private var activityToken: String?
    private var observed: Set<String> = []

    func start() {
        guard !started else { return }
        started = true
        Task {
            for await data in Activity<SwitchboardActivityAttributes>.pushToStartTokenUpdates {
                pushToStart = data.hex
                await save()
            }
        }
        Task {
            for await activity in Activity<SwitchboardActivityAttributes>.activityUpdates { observe(activity) }
        }
        Activity<SwitchboardActivityAttributes>.activities.forEach(observe)
    }

    /// Starts the activity from the phone (the Mac normally does this itself when something needs you).
    func startNow(with sessions: [LiveSession]) {
        guard Activity<SwitchboardActivityAttributes>.activities.isEmpty else { return }
        let state = LiveState(sessions: Array(sessions.prefix(LiveState.limit)),
                              blocked: sessions.filter { $0.status == 0 }.count,
                              review: sessions.filter { $0.status == 1 }.count,
                              working: sessions.filter { $0.status == 2 }.count)
        _ = try? Activity.request(attributes: SwitchboardActivityAttributes(title: "Switchboard"),
                                  content: .init(state: state, staleDate: nil), pushType: .token)
    }

    var hasActivity: Bool { !Activity<SwitchboardActivityAttributes>.activities.isEmpty }

    private func observe(_ activity: Activity<SwitchboardActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                activityToken = data.hex
                await save()
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                activityToken = nil
                await save()
            }
        }
    }

    private func save() async {
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
        let record = CKRecord(recordType: CloudSchema.deviceType, recordID: Cloud.id(id))
        // Empty strings rather than nil: a nil field isn't sent, so it wouldn't clear an old token.
        record["pushToStart"] = pushToStart ?? ""
        record["activityToken"] = activityToken ?? ""
        record["environment"] = Bundle.main.object(forInfoDictionaryKey: "SBAPNSEnvironment") as? String ?? "development"
        record["name"] = UIDevice.current.name
        do { try await Cloud.save([record]) } catch { NSLog("Switchboard: saving push tokens failed: %@", error.localizedDescription) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

#if DEBUG
extension Array where Element == LiveSession {
    static var demo: [LiveSession] {
        let now = Date().timeIntervalSince1970
        return [
            LiveSession(id: "a", name: "api-server", branch: "feature/billing", status: 0,
                        need: "Allow Bash: npm run db:migrate -- --env staging?", waitingSince: now - 240,
                        decisionID: "demo", canReply: false),
            LiveSession(id: "b", name: "web-frontend", branch: "main", status: 1, need: "Finished, ready for review",
                        waitingSince: now - 720, decisionID: nil, canReply: true),
            LiveSession(id: "c", name: "infra", branch: "fix/terraform-drift", status: 2,
                        need: "Running Bash: terraform plan", waitingSince: nil, decisionID: nil, canReply: false),
        ]
    }
}
#endif
