import AppKit
import SwitchboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore!
    private var ui = UIState()
    private var panel: PanelController!
    private var server: EventServer!
    private var hotKey: HotKey?
    private var notifier: Notifier!
    private var setup: Setup!
    private var phone: PhoneBridge!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy (e.g. login item plus a manual launch) would lose the port race; leave the first one running.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSLog("Switchboard: already running, exiting")
            NSApp.terminate(nil)
            return
        }

        Self.migrateDefaults()
        let port = UInt16(ProcessInfo.processInfo.environment["SWITCHBOARD_PORT"] ?? "") ?? 7777
        let dbPath = ProcessInfo.processInfo.environment["SWITCHBOARD_DB"] ?? Database.defaultPath

        store = SessionStore(databasePath: dbPath)
        notifier = Notifier()
        setup = Setup(port: Int(port))
        panel = PanelController(store: store, ui: ui, setup: setup,
                                onFocus: { [weak self] id in self?.focus(id) },
                                onDecide: { [weak self] id, decision in self?.store.decide(id, decision) },
                                onReply: { [weak self] id, text in
                                    self?.store.reply(id, text)
                                    self?.ui.replyingID = nil
                                    self?.ui.pinned = false
                                })

        store.onBecameBlocked = { [weak self] session in self?.notifier.notifyBlocked(session) }
        // A prompt you can answer from the peek stays up longer than one you can only look at.
        store.onPeek = { [weak self] session in
            self?.ui.peek(session.id, for: session.decisionID != nil ? 20 : session.status == .blocked ? 8 : 5)
        }
        store.onFinished = { [weak self] session in
            guard let self else { return }
            self.ui.flashDone(session.id)
            if self.setup.bannerOnDone { self.notifier.notifyDone(session) }
        }
        store.onUpdate = { [weak self] in
            guard let self else { return }
            if let id = self.ui.peekID, self.store.sessions.first(where: { $0.id == id })?.status.isWaiting != true {
                self.ui.endPeek()
            }
            self.ui.pruneDone(keeping: Set(self.store.sessions.filter { $0.status == .review }.map(\.id)))
            self.phone?.storeChanged()
        }
        notifier.onClick = { [weak self] id in
            self?.panel.show()
            self?.ui.pinned = true
            self?.ui.expandedID = id
        }

        server = EventServer(port: port,
                             onEvent: { [weak self] in self?.store.apply($0) },
                             snapshot: { [weak self] in self?.store.snapshotJSON() ?? Data() })
        server.onStateChange = { [weak self] error in self?.store.serverError = error }
        server.onRequestGone = { [weak self] id in self?.store.requestGone(id) }
        store.onDecide = { [weak self] id, decision in self?.server.decide(id, decision) }
        store.onReply = { [weak self] id, text in self?.server.reply(to: id, text) }
        server.onReplyAvailable = { [weak self] id, available in self?.store.setReplyable(id, available) }
        store.onActiveDecisionsChanged = { [weak self] active in self?.server.release(except: active) }
        server.start()

        setup.onHooksInstalled = { [weak self] in
            self?.notifier.notify(title: "Switchboard is connected to Claude Code",
                                  body: "Your sessions will appear as soon as they do something.")
        }
        // Skip the real settings.json and iCloud when running against a scratch database (tests, demos).
        phone = PhoneBridge(store: store, setup: setup)
        if ProcessInfo.processInfo.environment["SWITCHBOARD_DB"] == nil {
            setup.start()
            phone.start()
        }

        hotKey = HotKey { [weak self] in self?.panel.toggle() }
        panel.show()
    }

    /// Settings saved under the app's previous bundle id (pill position, toggles) carry over once.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyDefaults"),
              let legacy = UserDefaults(suiteName: "dev.switchboard.Switchboard") else { return }
        for key in ["pillAnchor", "hooksDisabledByUser", "bannerOnDone"] where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }

    private func focus(_ id: String) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        TerminalFocus.focus(session)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar takeover
let delegate = AppDelegate()
app.delegate = delegate
app.run()
