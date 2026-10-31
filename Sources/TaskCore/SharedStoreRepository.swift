import Foundation

public struct SyncConnection: Codable, Equatable {
    public var accountID: String
    public var zoneName: String
    public var ownerName: String
    public var isShared: Bool
    public init(accountID: String, zoneName: String, ownerName: String, isShared: Bool) {
        self.accountID = accountID; self.zoneName = zoneName
        self.ownerName = ownerName; self.isShared = isShared
    }
}

public struct SharedStoreState: Codable, Equatable {
    public var version = 1
    public var deviceID: String = UUID().uuidString
    public var notebook: Notebook
    public var replica: SyncReplica?
    public var connection: SyncConnection?
    public var lastSyncedAt: Date?
    public var hasPendingChanges = false
    /// Also synced with the Claude bridge (supabase/functions/horme). The link itself is kept in the Keychain.
    /// Optional so state files written before the bridge existed still decode.
    public var bridge: Bool?
    public init(notebook: Notebook = Notebook()) { self.notebook = notebook }

    /// The replica exists while something syncs with it: iCloud, the Claude bridge, or both.
    public var replicaInUse: Bool { connection != nil || bridge == true }

    /// Starts tracking edits for syncing, recording the current data as this device's changes.
    public mutating func startReplicaIfNeeded() throws {
        guard replica == nil else { return }
        var fresh = SyncReplica()
        try fresh.apply(before: Notebook(), after: notebook, device: deviceID)
        replica = fresh
    }

    public mutating func edit(_ next: Notebook) throws {
        _ = try NotebookCodec.decode(NotebookCodec.encode(next))
        if replica != nil {
            try replica?.apply(before: notebook, after: next, device: deviceID)
            hasPendingChanges = true
        }
        notebook = next
    }

    public mutating func receive(_ records: [SyncRecord]) throws {
        guard replica != nil, replicaInUse else { throw NotebookError.invalidData }
        try replica?.merge(records)
        notebook = try replica!.materialize()
    }

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw NotebookError.unsupportedVersion }
        guard !value.deviceID.isEmpty, value.replicaInUse == (value.replica != nil) else { throw NotebookError.invalidData }
        _ = try NotebookCodec.decode(NotebookCodec.encode(value.notebook))
        if let replica = value.replica {
            var validated = SyncReplica()
            try validated.merge(Array(replica.records.values))
            guard replica.clock >= validated.clock, replica.clock >= 0 else { throw NotebookError.invalidData }
            _ = try validated.materialize()
        }
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// A single atomic file holds both the local view and all unsent sync changes.
/// The old notebook.json is read only for migration and is kept untouched.
public struct SharedStoreRepository {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("horme-state.json") }
    public var previousURL: URL { url.appendingPathExtension("previous") }
    public var legacy: NotebookRepository { NotebookRepository(url: directory.appendingPathComponent("notebook.json")) }
    public var safetyBackupURL: URL { directory.appendingPathComponent("before-sharing.json") }
    public var syncBackupURL: URL { directory.appendingPathComponent("before-sync.json") }
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> SharedStoreState {
        if FileManager.default.fileExists(atPath: url.path) {
            return try SharedStoreState.decode(Data(contentsOf: url))
        }
        let state = SharedStoreState(notebook: try legacy.load())
        try save(state)
        return state
    }

    public func save(_ state: SharedStoreState) throws {
        let data = try state.encoded()
        _ = try SharedStoreState.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            _ = try SharedStoreState.decode(previous)
            try previous.write(to: previousURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    public func backup(_ notebook: Notebook, beforeSharing: Bool) throws {
        let data = try NotebookCodec.encode(notebook)
        _ = try NotebookCodec.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: beforeSharing ? safetyBackupURL : syncBackupURL, options: .atomic)
    }

    /// Moves an unreadable state file aside and starts with empty data, without migrating the old
    /// notebook again. Used when there is no earlier save to recover from.
    public func startFresh() throws -> SharedStoreState {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(UUID().uuidString)"))
        }
        let state = SharedStoreState()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try state.encoded().write(to: url, options: .atomic)
        return state
    }

    public func recoverPrevious() throws -> SharedStoreState {
        // A failed first migration still uses the original recovery path.
        guard FileManager.default.fileExists(atPath: url.path) else {
            let state = SharedStoreState(notebook: try legacy.recoverPrevious())
            try save(state); return state
        }
        let data = try Data(contentsOf: previousURL)
        var state = try SharedStoreState.decode(data)
        // A recovered older replica must not silently overwrite the server.
        // Keep the data locally and require an explicit merge to reconnect.
        state.connection = nil; state.replica = nil; state.lastSyncedAt = nil; state.bridge = nil
        let damaged = url.appendingPathExtension("unreadable-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: url, to: damaged)
        try state.encoded().write(to: url, options: .atomic)
        return state
    }
}
