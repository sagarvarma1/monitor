import AppKit
import Darwin
import SwitchboardCore

/// Brings the terminal window/tab running a Claude Code session to the front.
enum TerminalFocus {
    struct ProcInfo { let pid: Int32; let ppid: Int32; let tty: String?; let name: String }

    static func focus(_ session: Session) {
        let claudePID = liveClaudePID(for: session)
        let tty = claudePID.flatMap { procInfo($0)?.tty }
        let app = claudePID.flatMap(owningApp) ?? fallbackTerminalApp()

        guard let app else {
            NSLog("Switchboard: no terminal app found for %@", session.cwd)
            NSSound.beep()
            return
        }
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            if let tty, runAppleScript(terminalScript(tty: tty)) { return }
        case "com.googlecode.iterm2":
            if let tty, runAppleScript(itermScript(tty: tty)) { return }
        default:
            break  // Ghostty, Warp, VS Code, etc.: no scripting API for tabs, just activate.
        }
        app.activate(options: [.activateAllWindows])
    }

    // MARK: Process lookup

    /// The pid sent by the hook if it's still alive, otherwise a "claude" process whose cwd matches.
    static func liveClaudePID(for session: Session) -> Int32? {
        if let pid = session.pid, kill(pid, 0) == 0 || errno == EPERM { return pid }
        return allPIDs().first { pid in
            guard let info = procInfo(pid), info.name.lowercased().contains("claude") else { return false }
            return cwd(of: pid) == session.cwd
        }
    }

    /// True if `pid` is running and started no later than `date`, so a pid recycled after a reboot doesn't count.
    static func isAlive(_ pid: Int32, startedBy date: Date) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return TimeInterval(info.pbi_start_tvsec) <= date.timeIntervalSince1970 + 1
    }

    static func procInfo(_ pid: Int32) -> ProcInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafePointer(to: &info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { String(cString: $0) }
        }
        var tty: String?
        if info.e_tdev != UInt32(bitPattern: -1), let dev = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) {
            tty = "/dev/" + String(cString: dev)
        }
        return ProcInfo(pid: pid, ppid: Int32(info.pbi_ppid), tty: tty, name: name)
    }

    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, n)))).filter { $0 > 0 }
    }

    /// Walks up the parent chain to the first process that is a regular GUI app.
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let info = procInfo(current), info.ppid > 1 else { return nil }
            current = info.ppid
        }
        return nil
    }

    static func fallbackTerminalApp() -> NSRunningApplication? {
        let ids = ["com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }

    // MARK: AppleScript

    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    @discardableResult
    static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Switchboard AppleScript error: %@", error) }
        return result?.stringValue == "ok"
    }
}
