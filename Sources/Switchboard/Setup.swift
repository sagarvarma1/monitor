import AppKit
import ServiceManagement
import SwitchboardCore

/// Everything that used to be manual: hooks in ~/.claude/settings.json and launch at login.
/// Both are turned on automatically once; if you turn either off, it stays off.
final class Setup: ObservableObject {
    @Published private(set) var hooks: HookInstaller.Status = .notInstalled
    @Published private(set) var loginItem: SMAppService.Status = .notRegistered
    /// One line about the iPhone link, shown in the ⋯ menu (set by PhoneBridge).
    @Published var phoneStatus: String?
    /// Set when we just installed hooks. Current Claude Code picks them up live; older versions need a restart.
    @Published var restartHint = false

    var onHooksInstalled: (() -> Void)?

    private let port: Int
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
    }

    init(port: Int) {
        self.port = port
    }

    func start() {
        if isBundled && !defaults.bool(forKey: Key.loginConfigured) {
            defaults.set(true, forKey: Key.loginConfigured)
            setLaunchAtLogin(true)
        }
        refreshLoginItem()
        ensureHooks()
        // Self-heal: Claude Code can rewrite settings.json from a stale snapshot and drop our entries.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.ensureHooks()
            self?.refreshLoginItem()
        }
    }

    // MARK: Hooks

    var hooksEnabled: Bool { !defaults.bool(forKey: Key.hooksOff) }

    func ensureHooks() {
        hooks = HookInstaller.status(port: port)
        guard hooksEnabled, hooks == .notInstalled || hooks == .outdated else { return }
        do {
            if try HookInstaller.install(port: port) {
                restartHint = true
                onHooksInstalled?()
            }
        } catch {
            NSLog("Switchboard: could not install hooks: %@", error.localizedDescription)
        }
        hooks = HookInstaller.status(port: port)
    }

    func setHooksEnabled(_ on: Bool) {
        defaults.set(!on, forKey: Key.hooksOff)
        if on {
            ensureHooks()
        } else {
            do { try HookInstaller.uninstall() } catch {
                NSLog("Switchboard: could not remove hooks: %@", error.localizedDescription)
            }
            restartHint = false
            hooks = HookInstaller.status(port: port)
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
