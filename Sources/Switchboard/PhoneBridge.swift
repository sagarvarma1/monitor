import CloudKit
import Foundation
import Security
import SwitchboardCore

/// Bridges the Mac to the iPhone:
/// - mirrors sessions into iCloud for the phone app,
/// - drives the phone's Live Activity with APNs pushes (start / update / end),
/// - applies Allow/Deny/reply commands the phone writes back.
@MainActor
final class PhoneBridge {
    struct Device {
        var pushToStart: String?
        var activityToken: String?
        var environment = "development"
        var startRequestedAt: Date?
    }

    /// Where the APNs auth key goes: drop the downloaded AuthKey_<KEYID>.p8 file in here.
    static var keyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard/apns", isDirectory: true)
    }

    private let store: SessionStore
    private let setup: Setup
    private var apns: APNsSender?
    private var devices: [String: Device] = [:]
    private var mirrored: [String: LiveSession] = [:]
    private var lastPushed: LiveState?
    private var lastSilentPush = Date.distantPast
    private var changeToken: CKServerChangeToken?
    private var syncWork: DispatchWorkItem?
    private var running = false

    init(store: SessionStore, setup: Setup) {
        self.store = store
        self.setup = setup
    }

    /// iCloud needs the app to be signed with the iCloud entitlement; a plain local build isn't, and CloudKit
    /// would crash on first use, so the bridge stays off.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) != nil
    }

    func start() {
        guard Self.isEntitled else {
            setup.phoneStatus = "iPhone: needs a signed build"
            return
        }
        try? FileManager.default.createDirectory(at: Self.keyDirectory, withIntermediateDirectories: true)
        reloadKey()
        running = true
        Task { await pollLoop() }
        Task { await heartbeatLoop() }
        storeChanged()
    }

    func reloadKey() {
        let teamID = Bundle.main.object(forInfoDictionaryKey: "SBTeamID") as? String ?? ""
        apns = APNsSender(directory: Self.keyDirectory, teamID: teamID,
                          topic: (Bundle.main.bundleIdentifier ?? "") + ".mobile.push-type.liveactivity")
        refreshStatus()
    }

    private func refreshStatus() {
        if apns == nil {
            setup.phoneStatus = "iPhone: add your APNs key"
        } else if devices.isEmpty {
            setup.phoneStatus = "iPhone: open Switchboard on your phone"
        } else {
            setup.phoneStatus = "iPhone: connected"
        }
    }

    /// Called on every session change; coalesced so a burst of hook events becomes one sync.
    func storeChanged() {
        guard running else { return }
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.sync() } }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Mac -> phone

    private func sync() async {
        let state = LiveState.make(from: store.sessions, replyable: store.replyable)
        await mirror(store.sessions.map { LiveState.make(from: [$0], replyable: store.replyable).sessions[0] })
        await pushLiveActivity(state)
    }

    /// Keeps one SBSession record per session, writing only what changed.
    private func mirror(_ sessions: [LiveSession]) async {
        let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let changed = sessions.filter { mirrored[$0.id] != $0 }
        let removed = mirrored.keys.filter { current[$0] == nil }
        guard !changed.isEmpty || !removed.isEmpty else { return }
        do {
            try await Cloud.save(changed.map(Cloud.record), delete: removed.map(Cloud.id))
            mirrored = current
        } catch {
            NSLog("Switchboard: iCloud sync failed: %@", error.localizedDescription)
        }
    }

    /// Starts the Live Activity when something first needs you, keeps it current, and ends it when the
    /// sessions are gone. Alerts (which light up the phone) only for a session newly blocked or newly done.
    private func pushLiveActivity(_ state: LiveState) async {
        guard let apns else { return }
        let old = lastPushed ?? LiveState(sessions: [], blocked: 0, review: 0, working: 0)
        guard state != old else { return }
        let alert = alertFor(old: old, new: state)
        let statusesChanged = old.sessions.map { "\($0.id):\($0.status):\($0.decisionID ?? ""):\($0.canReply)" }
            != state.sessions.map { "\($0.id):\($0.status):\($0.decisionID ?? ""):\($0.canReply)" }
        // Text-only changes ("Running Bash: …") happen constantly while working; send those at most every 15s.
        if alert == nil && !statusesChanged && Date().timeIntervalSince(lastSilentPush) < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.storeChanged() }
            return
        }
        lastPushed = state
        if alert == nil { lastSilentPush = Date() }

        for (id, device) in devices {
            do {
                if state.isEmpty {
                    guard let token = device.activityToken else { continue }
                    try await send(apns, LiveActivityPush.end(state, dismissAfter: 0), to: token, device: id, priority: 10)
                    devices[id]?.activityToken = nil
                } else if let token = device.activityToken {
                    try await send(apns, LiveActivityPush.update(state, alert: alert), to: token, device: id,
                                   priority: alert == nil ? 5 : 10)
                } else if let startToken = device.pushToStart, state.blocked + state.review > 0,
                          Date().timeIntervalSince(device.startRequestedAt ?? .distantPast) > 120 {
                    devices[id]?.startRequestedAt = Date()
                    let opening = alert ?? .init(title: "Switchboard", body: state.headline, sound: false)
                    try await send(apns, LiveActivityPush.start(state, attributesType: "SwitchboardActivityAttributes",
                                                                attributes: ["title": "Switchboard"], alert: opening),
                                   to: startToken, device: id, priority: 10)
                }
            } catch {
                NSLog("Switchboard: Live Activity push failed: %@", error.localizedDescription)
            }
        }
    }

    private func send(_ apns: APNsSender, _ payload: Data, to token: String, device: String, priority: Int) async throws {
        let environment = devices[device]?.environment ?? "development"
        let (status, reason) = try await apns.send(payload, to: token, environment: environment, priority: priority)
        if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" {
            // That activity (or install) is gone; the phone will report a fresh token.
            if devices[device]?.activityToken == token { devices[device]?.activityToken = nil }
            if devices[device]?.pushToStart == token { devices[device]?.pushToStart = nil }
        } else if status != 200 {
            NSLog("Switchboard: APNs %d %@", status, reason)
        }
    }

    private func alertFor(old: LiveState, new: LiveState) -> LiveActivityPush.Alert? {
        let before = Dictionary(old.sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        if let s = new.sessions.first(where: { $0.status == 0 && before[$0.id] != 0 }) {
            return .init(title: "\(s.name) needs you", body: s.need, sound: true)
        }
        if let s = new.sessions.first(where: { $0.status == 1 && before[$0.id] == 2 }) {
            return .init(title: "\(s.name) is done", body: "Ready for review", sound: false)
        }
        return nil
    }

    // MARK: Phone -> Mac

    private func pollLoop() async {
        while running {
            if apns == nil { reloadKey() }  // picks up the key file as soon as it's dropped in
            await poll()
            // Quick while there's something the phone could be answering, relaxed otherwise.
            let busy = store.sessions.contains { $0.decisionID != nil } || !store.replyable.isEmpty
            try? await Task.sleep(nanoseconds: (busy ? 2 : 10) * 1_000_000_000)
        }
    }

    private func poll() async {
        do {
            let changes = try await Cloud.changes(since: changeToken)
            changeToken = changes.token
            var applied: [CKRecord.ID] = []
            var newActivity = false
            for record in changes.changed {
                switch record.recordType {
                case CloudSchema.commandType:
                    if let command = Cloud.command(record) { apply(command) }
                    applied.append(record.recordID)
                case CloudSchema.deviceType:
                    var device = devices[record.recordID.recordName] ?? Device()
                    let token = Cloud.string(record["activityToken"])
                    newActivity = newActivity || (token != nil && token != device.activityToken)
                    device.pushToStart = Cloud.string(record["pushToStart"])
                    device.activityToken = token
                    device.environment = record["environment"] as? String ?? "development"
                    devices[record.recordID.recordName] = device
                default:
                    break
                }
            }
            for deletion in changes.deleted where deletion.type == CloudSchema.deviceType {
                devices[deletion.id.recordName] = nil
            }
            try await Cloud.save([], delete: applied)
            if newActivity {
                // A fresh activity (just started on the phone) gets the current state right away.
                lastPushed = nil
                storeChanged()
            }
            refreshStatus()
        } catch {
            NSLog("Switchboard: iCloud poll failed: %@", error.localizedDescription)
        }
    }

    private func apply(_ command: PhoneCommand) {
        if let decision = command.decision {
            // Only answer the prompt the phone saw; a stale tap on an older prompt is dropped.
            guard store.sessions.first(where: { $0.id == command.sessionID })?.decisionID == command.decisionID else { return }
            store.decide(command.sessionID, decision)
        } else if let text = command.text {
            store.reply(command.sessionID, text)
        }
    }

    private func heartbeatLoop() async {
        while running {
            let record = CKRecord(recordType: CloudSchema.macType, recordID: Cloud.id("mac"))
            record["lastSeen"] = Date()
            record["name"] = Host.current().localizedName ?? "Mac"
            try? await Cloud.save([record])
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
    }
}

/// Sends pushes to APNs over HTTP/2 with token auth.
final class APNsSender {
    private var token: APNsToken
    private let topic: String

    /// Looks for the AuthKey_<KEYID>.p8 file Apple's developer site downloads; the key id is in its name.
    init?(directory: URL, teamID: String, topic: String) {
        guard !teamID.isEmpty,
              let file = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .first(where: { $0.lastPathComponent.hasPrefix("AuthKey_") && $0.pathExtension == "p8" }),
              let pem = try? String(contentsOf: file, encoding: .utf8),
              let token = try? APNsToken(keyID: String(file.deletingPathExtension().lastPathComponent.dropFirst("AuthKey_".count)),
                                         teamID: teamID, p8: pem) else { return nil }
        self.token = token
        self.topic = topic
    }

    func send(_ payload: Data, to deviceToken: String, environment: String, priority: Int) async throws -> (Int, String) {
        let host = environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("bearer \(try token.current())", forHTTPHeaderField: "authorization")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        let (data, response) = try await URLSession.shared.data(for: request)
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? ""
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, reason)
    }
}
