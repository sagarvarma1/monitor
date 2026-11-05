import AppKit
import SwiftUI
import SwitchboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore!
    private var ui = UIState()
    private var panel: PanelController!
    private var server: EventServer!
    private var hotKey: HotKey?
    private var notifier: Notifier!
    private var setup: Setup!
    private var windows: AppWindows!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy (e.g. login item plus a manual launch) would unlink and replace the first one's socket;
        // leave the first one running.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSLog("Switchboard: already running, exiting")
            NSApp.terminate(nil)
            return
        }

        Self.migrateDefaults()
        let customSocket = ProcessInfo.processInfo.environment["SWITCHBOARD_SOCKET"]
        let socketPath = customSocket ?? HookInstaller.defaultSocketPath
        let dbPath = ProcessInfo.processInfo.environment["SWITCHBOARD_DB"] ?? Database.defaultPath

        store = SessionStore(databasePath: dbPath)
        notifier = Notifier()
        Self.makeDataFolderPrivate((dbPath as NSString).deletingLastPathComponent)
        setup = Setup(socket: customSocket.map { "\"\($0)\"" } ?? HookInstaller.defaultSocketArgument, socketPath: socketPath)
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
        }
        notifier.onClick = { [weak self] id in
            self?.panel.show()
            self?.ui.pinned = true
            self?.ui.expandedID = id
        }

        server = EventServer(path: socketPath, onEvent: { [weak self] in self?.store.apply($0) })
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
        windows = AppWindows(
            dashboard: { [unowned self] in
                AnyView(DashboardView(store: store, nav: windows.nav, onFocus: { [weak self] in self?.focus($0) }))
            },
            settings: { [unowned self] in
                AnyView(SettingsView(setup: setup, onResetPill: { [weak self] in self?.panel.resetPosition() }))
            })
        ui.openDashboard = { [weak self] id in self?.windows.showDashboard(selecting: id) }
        ui.openSettings = { [weak self] in self?.windows.showSettings() }

        setup.onReady = { [weak self] in self?.notifier.requestPermission() }
        setup.onNeedsConsent = { [weak self] in
            guard let self else { return }
            self.windows.showWelcome(AnyView(WelcomeView { [weak self] connect, launchAtLogin in
                self?.windows.closeWelcome()
                self?.setup.finishWelcome(connect: connect, launchAtLogin: launchAtLogin)
            }))
        }
        // Skip the real settings.json when running against a scratch database (tests, demos).
        if ProcessInfo.processInfo.environment["SWITCHBOARD_DB"] == nil { setup.start() }

        hotKey = HotKey { [weak self] in self?.panel.toggle() }
        panel.show()
        // Development: open the Dashboard straight away (screenshots, UI work).
        if ProcessInfo.processInfo.environment["SWITCHBOARD_OPEN_DASHBOARD"] != nil { windows.showDashboard(selecting: nil) }
        installStatusItem()
        Watchdog.start()
    }

    /// Always reachable, including while the pill is hidden with ⌥S.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Switchboard")
        let menu = NSMenu()
        for (title, action, key) in [("Show or Hide Pill", #selector(togglePill), ""),
                                     ("Open Dashboard", #selector(openDashboard), ""),
                                     ("Settings…", #selector(openSettings), ",")] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Switchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePill() { panel.toggle() }
    @objc private func openDashboard() { windows.showDashboard(selecting: nil) }
    @objc private func openSettings() { windows.showSettings() }

    /// Session details, transcripts' contents and attachments are nobody else's business: 0700 folders, 0600 files.
    private static func makeDataFolderPrivate(_ folder: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        chmod(folder, 0o700)
        for item in (fm.enumerator(atPath: folder)?.allObjects as? [String]) ?? [] {
            var isDir: ObjCBool = false
            let path = folder + "/" + item
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            chmod(path, isDir.boolValue ? 0o700 : 0o600)
        }
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
