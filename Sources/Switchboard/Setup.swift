import AppKit
import ServiceManagement
import SwitchboardCore

/// Hooks in ~/.claude/settings.json and launch at login. Nothing changes until the welcome screen is answered;
/// after that, if you turn either off, it stays off.
final class Setup: ObservableObject {
    @Published private(set) var hooks: HookInstaller.Status = .notInstalled
    @Published private(set) var loginItem: SMAppService.Status = .notRegistered
    /// Set when we just installed hooks. Current Claude Code picks them up live; older versions need a restart.
    @Published var restartHint = false

    var onHooksInstalled: (() -> Void)?
    /// First launch: nothing has been touched yet, and the welcome screen should ask.
    var onNeedsConsent: (() -> Void)?
    /// Setup has been agreed to (now, or on an earlier launch).
    var onReady: (() -> Void)?

    /// How the hook commands name the socket, and where it actually is.
    let socket: String
    let socketPath: String
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    /// SMAppService and login items only make sense for a real .app bundle (not `swift run`).
    let isBundled = Bundle.main.bundlePath.hasSuffix(".app")

    /// A macOS banner when a session finishes, on top of the pill's flash. Off by default.
    @Published var bannerOnDone = UserDefaults.standard.bool(forKey: Key.bannerOnDone) {
        didSet { defaults.set(bannerOnDone, forKey: Key.bannerOnDone) }
    }

    private enum Key {
        static let bannerOnDone = "bannerOnDone"
        static let hooksOff = "hooksDisabledByUser"
        static let loginConfigured = "loginItemConfigured"
        static let consented = "setupConsented"
    }

    init(socket: String, socketPath: String) {
        self.socket = socket
        self.socketPath = socketPath
    }

    func start() {
        // Copies from before the welcome screen existed have already been set up.
        if defaults.bool(forKey: Key.loginConfigured) { defaults.set(true, forKey: Key.consented) }
        refreshLoginItem()
        hooks = HookInstaller.status(socket: socket)
        // Self-heal: Claude Code can rewrite settings.json from a stale snapshot and drop our entries.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.ensureHooks()
            self?.refreshLoginItem()
        }
        if defaults.bool(forKey: Key.consented) {
            ensureHooks()
            onReady?()
        } else {
            onNeedsConsent?()
        }
    }

    /// The welcome screen's answer. Closing the window instead changes nothing, and it asks again next launch.
    func finishWelcome(connect: Bool, launchAtLogin: Bool) {
        defaults.set(true, forKey: Key.consented)
        defaults.set(true, forKey: Key.loginConfigured)
        defaults.set(!connect, forKey: Key.hooksOff)
        if launchAtLogin { setLaunchAtLogin(true) }
        ensureHooks()
        onReady?()
    }

    // MARK: Hooks

    var hooksEnabled: Bool { defaults.bool(forKey: Key.consented) && !defaults.bool(forKey: Key.hooksOff) }

    func ensureHooks() {
        hooks = HookInstaller.status(socket: socket)
        guard hooksEnabled, hooks == .notInstalled || hooks == .outdated else { return }
        do {
            if try HookInstaller.install(socket: socket) {
                restartHint = true
                onHooksInstalled?()
            }
        } catch {
            NSLog("Switchboard: could not install hooks: %@", error.localizedDescription)
        }
        hooks = HookInstaller.status(socket: socket)
    }

    func setHooksEnabled(_ on: Bool) {
        defaults.set(true, forKey: Key.consented)
        defaults.set(!on, forKey: Key.hooksOff)
        if on {
            ensureHooks()
        } else {
            do { try HookInstaller.uninstall() } catch {
                NSLog("Switchboard: could not remove hooks: %@", error.localizedDescription)
            }
            restartHint = false
            hooks = HookInstaller.status(socket: socket)
        }
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool { loginItem == .enabled || loginItem == .requiresApproval }

    func setLaunchAtLogin(_ on: Bool) {
        guard isBundled else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Switchboard: login item %@ failed: %@", on ? "register" : "unregister", error.localizedDescription)
        }
        refreshLoginItem()
    }

    func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func refreshLoginItem() {
        guard isBundled else { return }
        loginItem = SMAppService.mainApp.status
    }
}
