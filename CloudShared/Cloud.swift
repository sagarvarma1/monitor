import CloudKit
import Foundation
import SwitchboardCore

/// The private iCloud database the Mac and the phone share. Everything lives in one custom zone and is read
/// with zone change tokens, so no CloudKit indexes need configuring.
enum Cloud {
    static let container = CKContainer(identifier: CloudSchema.container)
    static var db: CKDatabase { container.privateCloudDatabase }
    static let zoneID = CKRecordZone.ID(zoneName: CloudSchema.zone, ownerName: CKCurrentUserDefaultName)

    private static var zoneReady = false

    /// Creating an existing zone is a no-op, so this is safe to call from both devices.
    static func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneReady = true
    }

    static func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    struct Changes {
        var changed: [CKRecord] = []
        var deleted: [(id: CKRecord.ID, type: CKRecord.RecordType)] = []
        var token: CKServerChangeToken?
    }

    static func changes(since token: CKServerChangeToken?) async throws -> Changes {
        try await ensureZone()
        var out = Changes(token: token)
        var more = true
        while more {
            let page = try await db.recordZoneChanges(inZoneWith: zoneID, since: out.token)
            for (_, result) in page.modificationResultsByID {
                if case .success(let modification) = result { out.changed.append(modification.record) }
            }
            out.deleted += page.deletions.map { ($0.recordID, $0.recordType) }
            out.token = page.changeToken
            more = page.moreComing
        }
        return out
    }

    /// Last write wins: these records each have a single writer (the Mac, or one phone).
    static func save(_ records: [CKRecord], delete: [CKRecord.ID] = []) async throws {
        guard !records.isEmpty || !delete.isEmpty else { return }
        try await ensureZone()
        _ = try await db.modifyRecords(saving: records, deleting: delete, savePolicy: .allKeys, atomically: false)
    }

    // MARK: Sessions (Mac -> phone)

    /// "None" is written as "" / -1 rather than nil: a nil field isn't sent, so it would never clear an old
    /// value (a stale decisionID would keep showing Allow/Deny on the phone).
    static func record(_ s: LiveSession) -> CKRecord {
        let r = CKRecord(recordType: CloudSchema.sessionType, recordID: id(s.id))
        r["name"] = s.name
        r["branch"] = s.branch ?? ""
        r["status"] = s.status
        r["need"] = s.need
        r["waitingSince"] = s.waitingSince ?? -1
        r["decisionID"] = s.decisionID ?? ""
        r["canReply"] = s.canReply ? 1 : 0
        return r
    }

    static func liveSession(_ r: CKRecord) -> LiveSession? {
        guard r.recordType == CloudSchema.sessionType, let name = r["name"] as? String else { return nil }
        return LiveSession(id: r.recordID.recordName, name: name, branch: string(r["branch"]),
                           status: r["status"] as? Int ?? 2, need: r["need"] as? String ?? "",
                           waitingSince: (r["waitingSince"] as? Double).flatMap { $0 < 0 ? nil : $0 },
                           decisionID: string(r["decisionID"]), canReply: (r["canReply"] as? Int ?? 0) == 1)
    }

    /// A string field, with "" meaning none.
    static func string(_ value: CKRecordValue?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    // MARK: Commands (phone -> Mac)

    static func record(_ c: PhoneCommand) -> CKRecord {
        let r = CKRecord(recordType: CloudSchema.commandType, recordID: id(UUID().uuidString))
        r["kind"] = c.kind.rawValue
        r["sessionID"] = c.sessionID
        r["decisionID"] = c.decisionID
        r["text"] = c.text
        return r
    }

    static func command(_ r: CKRecord) -> PhoneCommand? {
        guard r.recordType == CloudSchema.commandType,
              let kind = (r["kind"] as? String).flatMap(PhoneCommand.Kind.init(rawValue:)),
              let sessionID = r["sessionID"] as? String else { return nil }
        return PhoneCommand(kind: kind, sessionID: sessionID, decisionID: r["decisionID"] as? String, text: r["text"] as? String)
    }

    static func send(_ command: PhoneCommand) async throws {
        try await save([record(command)])
    }
}
