import AppKit
import SwiftUI
import SwitchboardCore

/// Shows what a session's terminal shows, by asking Terminal, iTerm2 or tmux for its text once a second.
/// Polls only while the view is up. Runs osascript off the main thread: a busy terminal must not stall the app.
@MainActor
final class TerminalMirror: ObservableObject {
    enum State: Equatable {
        case loading
        /// `ansi` when the source gave real colors (tmux); plain text gets Claude Code's lines highlighted instead.
        case text(String, ansi: Bool)
        /// A terminal with no scripting API, such as VS Code or Ghostty.
        case unsupported(String)
        case needsPermission(String)
        case notFound
    }

    @Published private(set) var state = State.loading
    private var timer: Timer?
    private var session: Session?
    private var reading = false
    private let queue = DispatchQueue(label: "switchboard.terminal-mirror")

    func start(_ session: Session) {
        self.session = session
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !reading, let session else { return }
        reading = true
        queue.async {
            let next = Self.read(session)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                if self.timer != nil, self.state != next { self.state = next }
            }
        }
    }

    private nonisolated static func read(_ session: Session) -> State {
        guard let pid = TerminalFocus.liveClaudePID(for: session), let tty = TerminalFocus.procInfo(pid)?.tty else { return .notFound }
        // Under tmux the process tree stops at the tmux server, not a GUI app, whichever terminal is showing it.
        guard let app = TerminalFocus.owningApp(of: pid) else { return readTmux(tty: tty) }
        let name = app.localizedName ?? "this terminal"
        let script: String
        switch app.bundleIdentifier {
        case "com.apple.Terminal": script = terminalScript(tty: tty)
        case "com.googlecode.iterm2": script = itermScript(tty: tty)
        default: return .unsupported(name)
        }
        guard let result = run("/usr/bin/osascript", [], input: script) else { return .notFound }
        if result.status != 0 {
            return result.errors.contains("-1743") || result.errors.contains("Not authorized") ? .needsPermission(name) : .notFound
        }
        return screen(result.output, ansi: false)
    }

    private nonisolated static func readTmux(tty: String) -> State {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: FileManager.default.isExecutableFile(atPath:)),
              let panes = run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]), panes.status == 0,
              let line = panes.output.split(separator: "\n").first(where: { $0.hasPrefix(tty + " ") }),
              let pane = line.split(separator: " ").last,
              let capture = run(tmux, ["capture-pane", "-e", "-p", "-t", String(pane)]), capture.status == 0 else { return .notFound }
        return screen(capture.output, ansi: true)
    }

    private nonisolated static func screen(_ text: String, ansi: Bool) -> State {
        let trimmed = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? .notFound : .text(trimmed, ansi: ansi)
    }

    private nonisolated static func run(_ path: String, _ arguments: [String], input: String? = nil) -> (status: Int32, output: String, errors: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return nil }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "", String(data: errors, encoding: .utf8) ?? "")
    }

    // Indexes rather than `repeat with t in tabs`: "contents of t" on a loop variable yields t, not the tab's text.
    private nonisolated static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                    if tty of tab ti of window wi is "\(tty)" then return contents of tab ti of window wi
                end repeat
            end repeat
        end tell
        return ""
        """
    }

    private nonisolated static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                    repeat with si from 1 to count of sessions of tab ti of window wi
                        if tty of session si of tab ti of window wi is "\(tty)" then return text of session si of tab ti of window wi
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """
    }
}

struct TerminalMirrorView: View {
    let session: Session
    @StateObject private var mirror = TerminalMirror()
    @State private var following = true

    var body: some View {
        Group {
            switch mirror.state {
            case .text(let text, let ansi): terminal(text, ansi: ansi)
            case .loading: message("Connecting to the terminal…")
            case .unsupported(let name): message("\(name) doesn't let other apps read its text. Live view works with Terminal, iTerm2 and anything running inside tmux. The Activity tab works everywhere.")
            case .notFound: message("Can't find this session's terminal tab. It may have closed.")
            case .needsPermission(let name):
                VStack(spacing: 10) {
                    message("Switchboard needs permission to read \(name).")
                    Button("Open Automation Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { mirror.start(session) }
        .onDisappear { mirror.stop() }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
    }

    private func styled(_ text: String, ansi: Bool) -> AttributedString {
        let runs = ansi ? TerminalText.parseANSI(text) : TerminalText.highlightClaudeCode(text)
        var out = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            let weight: Font.Weight = run.bold ? .bold : .regular
            var font = Font.system(size: 11.5, weight: weight, design: .monospaced)
            if run.italic { font = font.italic() }
            part.font = font
            part.foregroundColor = Self.color(run.color).opacity(run.dim ? 0.55 : 1)
            if run.underline { part.underlineStyle = .single }
            out.append(part)
        }
        return out
    }

    private static func color(_ color: TerminalRun.Color?) -> Color {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
        let basic = [(0, 0, 0), (222, 96, 88), (72, 199, 116), (229, 192, 90), (88, 150, 240), (199, 120, 221), (86, 196, 208), (200, 200, 200),
                     (110, 110, 110), (255, 125, 115), (95, 225, 140), (245, 215, 120), (120, 175, 255), (220, 150, 240), (120, 220, 230), (255, 255, 255)]
        switch color {
        case nil: return Color(white: 0.9)
        case .rgb(let r, let g, let b): return rgb(r, g, b)
        case .indexed(let i) where i < 16: let c = basic[max(0, i)]; return rgb(c.0, c.1, c.2)
        case .indexed(let i) where i < 232:
            let n = i - 16, level = { (v: Int) in v == 0 ? 0 : 55 + v * 40 }
            return rgb(level(n / 36), level(n / 6 % 6), level(n % 6))
        case .indexed(let i): let v = 8 + (min(i, 255) - 232) * 10; return rgb(v, v, v)
        }
    }

    private func terminal(_ text: String, ansi: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(styled(text, ansi: ansi))
                        .textSelection(.enabled)
                        .fixedSize()
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(white: 0.09))
            .overlay(alignment: .bottomTrailing) {
                Toggle("Follow", isOn: $following)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .padding(8)
                    .help("Keep the newest output in view")
            }
            .onChange(of: text) { _ in if following { proxy.scrollTo("end", anchor: .bottomLeading) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottomLeading) }
        }
    }
}
