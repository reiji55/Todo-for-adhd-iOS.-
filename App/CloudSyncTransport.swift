import CloudKit
import Foundation

enum CloudSyncError: LocalizedError {
    case accountUnavailable, accountChanged, readOnly, wrongContainer, differentShare, tooLarge, busy, invalidRecord
    var errorDescription: String? {
        switch self {
        case .accountUnavailable: return "iCloudを利用できません。「設定」でApple AccountへのサインインとiCloudの設定を確認してください。端末のデータは保存されています。"
        case .accountChanged: return "iCloudのアカウントが変更されています。別のアカウントにデータを送らないよう同期を停止しました。元のアカウントに戻すか、この端末の同期を解除して接続し直してください。"
        case .readOnly: return "この共有には編集権限がありません。共有元で「変更可能」に設定してください。端末のデータは変更していません。"
        case .wrongContainer: return "この招待はHormeの共有ではありません。"
        case .differentShare: return "すでに別のデータと同期しています。共有先を変えるには、設定からこの端末の同期を解除してください。"
        case .tooLarge: return "一つのタスクまたはアイデアが大きすぎて送信できません。長い本文を分けて、もう一度同期してください。端末には保存されています。"
        case .busy: return "別の端末でも更新されています。少し待ってから同期をやり直します。"
        case .invalidRecord: return "共有データを読み込めませんでした。Hormeを最新版にして、もう一度同期してください。"
        }
    }
}

struct CloudSnapshot {
    var connection: SyncConnection
    var replica: SyncReplica
}

/// CloudKit owns transport and permissions; SyncReplica owns deterministic merges.
/// This small personal-data implementation reads paginated zone changes from the
/// start, so no change token can advance ahead of a durable local save. It never
/// queries records (no query indexes are required) or deletes server records.
@MainActor
final class CloudSyncTransport {
    static let containerID = "iCloud.io.github.reiji55.threedays"
    static let zoneName = "HormeData"
    static let recordType = "HormeItem"
    lazy var container = CKContainer(identifier: Self.containerID)
    private var subscribed: Set<String> = []

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudSyncError.accountUnavailable }
        return try await container.userRecordID().recordName
    }

    func verify(_ connection: SyncConnection) async throws {
        guard try await accountID() == connection.accountID else { throw CloudSyncError.accountChanged }
    }

    func prepareOwnData() async throws -> CloudSnapshot {
        let account = try await accountID()
        let id = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        do { _ = try await database.recordZone(for: id) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            _ = try await database.save(CKRecordZone(zoneID: id))
        }
        let connection = SyncConnection(accountID: account, zoneName: id.zoneName, ownerName: id.ownerName, isShared: false)
        let fetched = try await fetch(connection)
        var replica = SyncReplica(); try replica.merge(fetched.values.map(\.value))
        return CloudSnapshot(connection: connection, replica: replica)
    }

    func accept(_ metadata: CKShare.Metadata) async throws -> CloudSnapshot {
        guard metadata.containerIdentifier == Self.containerID else { throw CloudSyncError.wrongContainer }
        guard metadata.participantPermission == .readWrite else { throw CloudSyncError.readOnly }
        let account = try await accountID()
        guard metadata.participantStatus == .pending || metadata.participantStatus == .accepted else { throw CloudSyncError.readOnly }
        if metadata.participantStatus == .pending { _ = try await container.accept(metadata) }
        let id = metadata.share.recordID.zoneID
        let connection = SyncConnection(accountID: account, zoneName: id.zoneName, ownerName: id.ownerName, isShared: true)
        let fetched = try await fetch(connection)
        var replica = SyncReplica(); try replica.merge(fetched.values.map(\.value))
        return CloudSnapshot(connection: connection, replica: replica)
    }

    func synchronize(_ connection: SyncConnection, local: SyncReplica, stillConnected: () -> Bool) async throws -> SyncReplica {
        try await verify(connection)
        let fetched = try await fetch(connection)
        var merged = local
        try merged.merge(fetched.values.map(\.value))
        _ = try merged.materialize()
        let database = database(for: connection)
        let zoneID = zoneID(for: connection)
        // Save a converted task before its source idea's deletion marker. If a
        // connection drops between writes, another device can still find either
        // the idea or the task, and the durable replica completes the retry.
        let ids = merged.records.keys.sorted { left, right in
            if left.hasPrefix("task_") != right.hasPrefix("task_") { return left.hasPrefix("task_") }
            return left < right
        }
        for id in ids {
            guard let desired = merged.records[id], fetched[id]?.value != desired else { continue }
            try Task.checkCancellation()
            // Recheck the identity before each write, including a resumed operation.
            try await verify(connection)
            guard stillConnected() else { throw CancellationError() }
            let saved = try await save(desired, base: fetched[id]?.record, zoneID: zoneID, database: database)
            try merged.merge([saved])
        }
        await subscribe(connection)
        return merged
    }

    func share(for connection: SyncConnection) async throws -> CKShare {
        try await verify(connection)
        let database = database(for: connection)
        let zone = try await database.recordZone(for: zoneID(for: connection))
        if let reference = zone.share {
            guard let existing = try await database.record(for: reference.recordID) as? CKShare else { throw CloudSyncError.invalidRecord }
            return existing
        }
        guard !connection.isShared else { throw CloudSyncError.invalidRecord }
        let share = CKShare(recordZoneID: zone.zoneID)
        share[CKShare.SystemFieldKey.title] = "Hormeの共有データ" as CKRecordValue
        share.publicPermission = .none
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else { throw CloudSyncError.invalidRecord }
        return saved
    }

    private struct FetchedRecord { var record: CKRecord; var value: SyncRecord }

    private func fetch(_ connection: SyncConnection) async throws -> [String: FetchedRecord] {
        try await verify(connection)
        let database = database(for: connection)
        let zoneID = zoneID(for: connection)
        // Do not recreate a missing/revoked zone on a normal sync.
        let zone = try await database.recordZone(for: zoneID)
        if connection.isShared {
            guard let reference = zone.share,
                  let share = try await database.record(for: reference.recordID) as? CKShare,
                  share.currentUserParticipant?.permission == .readWrite else { throw CloudSyncError.readOnly }
        }
        var records: [String: FetchedRecord] = [:]
        var token: CKServerChangeToken?
        var more = true
        while more {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                if record is CKShare { continue }
                guard record.recordType == Self.recordType, let data = record["payload"] as? Data else {
                    throw CloudSyncError.invalidRecord
                }
                let value = try SyncRecord.decode(data, expectedID: id.recordName)
                records[id.recordName] = FetchedRecord(record: record, value: value)
            }
            for deleted in page.deletions { records.removeValue(forKey: deleted.recordID.recordName) }
            token = page.changeToken; more = page.moreComing
        }
        return records
    }

    private func save(_ value: SyncRecord, base: CKRecord?, zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> SyncRecord {
        var desired = value
        var record = base ?? CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: value.id, zoneID: zoneID))
        for attempt in 0..<4 {
            let data = try desired.encoded()
            guard data.count < 750_000 else { throw CloudSyncError.tooLarge }
            record["payload"] = data as CKRecordValue
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let saved = try result.saveResults[record.recordID]?.get(), let bytes = saved["payload"] as? Data else {
                    throw CloudSyncError.invalidRecord
                }
                return try SyncRecord.decode(bytes, expectedID: value.id)
            } catch {
                guard let conflict = Self.recordConflict(error), attempt < 3,
                      let server = conflict.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                      let bytes = server["payload"] as? Data else { throw error }
                try desired.merge(SyncRecord.decode(bytes, expectedID: desired.id))
                record = server
            }
        }
        throw CloudSyncError.busy
    }

    private static func recordConflict(_ error: Error) -> CKError? {
        guard let cloud = error as? CKError else { return nil }
        if cloud.code == .serverRecordChanged { return cloud }
        for child in (cloud.partialErrorsByItemID ?? [:]).values {
            if let conflict = recordConflict(child) { return conflict }
        }
        return nil
    }

    private func subscribe(_ connection: SyncConnection) async {
        let key = "\(connection.accountID)-\(connection.isShared)"
        guard !subscribed.contains(key) else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: "horme-\(connection.isShared ? "shared" : "private")")
        let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await database(for: connection).save(subscription); subscribed.insert(key) }
        catch { /* Foreground refresh and retry remain available when silent push is unavailable. */ }
    }

    private func database(for connection: SyncConnection) -> CKDatabase {
        connection.isShared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }
    private func zoneID(for connection: SyncConnection) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: connection.zoneName, ownerName: connection.ownerName)
    }
}
