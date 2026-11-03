import AppKit
import SwiftUI
import SwitchboardCore

struct SettingsView: View {
    @ObservedObject var setup: Setup
    var onResetPill: () -> Void

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            claude.tabItem { Label("Claude Code", systemImage: "terminal") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 400)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                if setup.isBundled {
                    Toggle("Open Switchboard at login", isOn: Binding(get: { setup.launchesAtLogin },
                                                                    set: { setup.setLaunchAtLogin($0) }))
                    if setup.loginItem == .requiresApproval {
                        HStack {
                            Text("Waiting for your approval in System Settings").font(.callout).foregroundStyle(.secondary)
                            Button("Open Login Items…", action: setup.openLoginItemSettings)
                        }
                    }
                }
                Toggle("Show a banner when a session finishes", isOn: $setup.bannerOnDone)
                Text("The pill always flashes when a session is done; the banner is a macOS notification on top, for when you're away from the screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show or hide the pill") { Text("⌥S").font(.body.monospaced()) }
                LabeledContent("Pill position") {
                    Button("Move Back to Top Right", action: onResetPill)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Claude Code

    private var claude: some View {
        Form {
            Section {
                LabeledContent("Status") { hookStatus }
                Toggle("Connect to Claude Code", isOn: Binding(get: { setup.hooksEnabled && setup.hooks == .installed },
                                                               set: { setup.setHooksEnabled($0) }))
                Text("Switchboard adds hooks to your Claude Code settings so sessions report what they're doing. Your other hooks are left alone, and the file is backed up before every change.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Settings file") {
                    HStack {
                        Text("~/.claude/settings.json").font(.callout.monospaced())
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([HookInstaller.defaultSettingsURL])
                        }
                    }
                }
                LabeledContent("Listening on") { Text("127.0.0.1:\(setup.port)").font(.callout.monospaced()) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var hookStatus: some View {
        switch setup.hooks {
        case .installed: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(SessionStatus.working.color)
        case .outdated: Label("Updating…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(SessionStatus.review.color)
        case .notInstalled: Label("Not connected", systemImage: "bolt.slash").foregroundStyle(.secondary)
        case .invalidSettings(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SessionStatus.blocked.color)
        }
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Switchboard").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .foregroundStyle(.secondary)
            Text("Every Claude Code session, at a glance.").foregroundStyle(.secondary)
            HStack {
                Link("GitHub", destination: URL(string: "https://github.com/sagarvarma1/monitor")!)
                Text("·").foregroundStyle(.tertiary)
                Button("Show Data Folder") {
                    let folder = (Database.defaultPath as NSString).deletingLastPathComponent
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                }
                .buttonStyle(.link)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// First launch: says what Switchboard would change, and changes none of it until answered.
struct WelcomeView: View {
    var onFinish: (_ connect: Bool, _ launchAtLogin: Bool) -> Void
    @State private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Switchboard").font(.title2.weight(.semibold))
                    Text("See which Claude Code sessions need you.").foregroundStyle(.secondary)
                }
            }
            Text("To connect, Switchboard will:").padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                item("doc.badge.gearshape", "Add hooks to ~/.claude/settings.json", "Sessions report what they're doing. The file is backed up first and your other hooks are left alone.")
                item("lock.shield", "Stay on your Mac", "Hooks talk to the app on 127.0.0.1 only. Session data stays in this Mac's Application Support folder.")
                item("bell", "Ask to send notifications", "So a session that's blocked on you can get your attention.")
            }
            Toggle("Open Switchboard at login", isOn: $launchAtLogin).padding(.top, 2)
            HStack {
                Text("You can change or undo all of this in Settings.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Not Now") { onFinish(false, false) }
                Button("Connect") { onFinish(true, launchAtLogin) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func item(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The dashboard and settings windows. Switchboard is normally a Dock-less accessory app; while one of these
/// windows is open it becomes a regular app, so the window is in ⌘-Tab and the Dock like any other.
final class AppWindows: NSObject, NSWindowDelegate {
    let nav = DashboardNav()
    private var dashboard: NSWindow?
    private var settings: NSWindow?
    private var welcome: NSWindow?
    private let makeDashboard: () -> AnyView
    private let makeSettings: () -> AnyView

    init(dashboard: @escaping () -> AnyView, settings: @escaping () -> AnyView) {
        makeDashboard = dashboard
        makeSettings = settings
    }

    func showDashboard(selecting id: String? = nil) {
        if let id { nav.selectedID = id }
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Switchboard"
            let host = NSHostingController(rootView: makeDashboard())
            host.sizingOptions = [.minSize]  // the window keeps its own size, SwiftUI only sets the minimum
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1000, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("SwitchboardDashboard")
            dashboard = window
        }
        present(dashboard!)
    }

    func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Switchboard Settings"
            window.contentViewController = NSHostingController(rootView: makeSettings())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settings = window
        }
        present(settings!)
    }

    func showWelcome(_ view: AnyView) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Switchboard"
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        welcome = window
        present(window)
    }

    func closeWelcome() {
        welcome?.close()
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let stillOpen = [dashboard, settings, welcome].contains { $0 != nil && $0 !== closing && $0!.isVisible }
        if !stillOpen {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
