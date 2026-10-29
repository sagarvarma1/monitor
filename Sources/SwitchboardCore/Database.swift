import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite persistence for sessions and daily idle totals. Not thread-safe; use from one queue.
public final class Database {
    private var db: OpaquePointer?

    public init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "Switchboard.Database", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open \(path)"])
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS idle_daily (
                day TEXT PRIMARY KEY,
                seconds REAL NOT NULL DEFAULT 0
            );
            """)
    }

    deinit { sqlite3_close(db) }

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Switchboard/switchboard.db").path
    }

    // MARK: Sessions

    public func loadSessions() -> [Session] {
        let decoder = JSONDecoder()
        var out: [Session] = []
        query("SELECT json FROM sessions", bind: []) { stmt in
            if let text = sqlite3_column_text(stmt, 0),
               let s = try? decoder.decode(Session.self, from: Data(String(cString: text).utf8)) {
                out.append(s)
            }
        }
        return out
    }

    public func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session), let json = String(data: data, encoding: .utf8) else { return }
        query("INSERT OR REPLACE INTO sessions (id, json) VALUES (?, ?)", bind: [session.id, json])
    }

    public func deleteSession(_ id: String) {
        query("DELETE FROM sessions WHERE id = ?", bind: [id])
    }

    // MARK: Idle totals

    public func addIdle(_ interval: DateInterval) {
        for (day, seconds) in IdleMath.splitByDay(interval) {
            query("""
                INSERT INTO idle_daily (day, seconds) VALUES (?, ?)
                ON CONFLICT(day) DO UPDATE SET seconds = seconds + excluded.seconds
                """, bind: [day, seconds])
        }
    }

    public func idleSeconds(day: String) -> TimeInterval {
        var total: TimeInterval = 0
        query("SELECT seconds FROM idle_daily WHERE day = ?", bind: [day]) { total = sqlite3_column_double($0, 0) }
        return total
    }

    // MARK: Helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(domain: "Switchboard.Database", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func query(_ sql: String, bind: [Any], row: ((OpaquePointer) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("Switchboard SQL error: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row?(stmt) }
    }
}
