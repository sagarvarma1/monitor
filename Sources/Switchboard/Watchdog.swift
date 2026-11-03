import Foundation

/// A hung main thread takes every way of quitting with it: the pill, the menu bar item, and (because the app has no
/// Dock icon) the Force Quit window doesn't list it either. So a background thread pings the main queue, and if
/// nothing answers for `timeout`, the app crashes on purpose, which leaves a report in
/// ~/Library/Logs/DiagnosticReports. Claude Code is unaffected: its hooks do nothing when the app isn't running.
enum Watchdog {
    static func start(timeout: TimeInterval = 180, interval: TimeInterval = 5) {
        Thread.detachNewThread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                // DispatchTime stops while the Mac sleeps, so sleeping doesn't count as hanging.
                if answered.wait(timeout: .now() + timeout) == .timedOut {
                    fatalError("Switchboard: main thread unresponsive for \(Int(timeout))s")
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }
}
