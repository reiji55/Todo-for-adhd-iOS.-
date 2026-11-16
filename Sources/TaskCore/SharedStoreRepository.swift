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

    /// Says that a change was checked by `edit` or `receive`: the book keeps its rules, and what changed writes
    /// and reads back. A state saved with it need not be read back whole again (see `SharedStoreRepository.save(_:after:)`).
    public struct CheckedEdit {
        fileprivate init() {}
    }

    /// Takes an edited book. Only what changed is written out and read back as a check; the rest was checked
    /// when it was loaded or last changed, and going through all of it on each edit made every tap slow.
    @discardableResult
    public mutating func edit(_ next: Notebook) throws -> CheckedEdit {
        try NotebookCodec.validate(next)
        if var updated = replica {
            let changed = try updated.apply(before: notebook, after: next, device: deviceID)
            try updated.check(changed)
            replica = updated
            hasPendingChanges = true
        } else {
            try SyncReplica.checkChanges(from: notebook, to: next)
        }
        notebook = next
        return CheckedEdit()
    }

    /// Takes the records a sync brought. When they hold nothing new (the usual case right after sending an
    /// edit) what is shown already says what the records say, and they are not all read back again. Otherwise
    /// every record is read back into the book, which checks them all. Either way the state can then be saved
    /// without reading the whole file back once more.
    @discardableResult
    public mutating func receive(_ records: [SyncRecord]) throws -> CheckedEdit {
        guard let before = replica, replicaInUse else { throw NotebookError.invalidData }
        try replica?.merge(records)
        guard replica != before else { return CheckedEdit() }
        notebook = try replica!.materialize()
        let received = notebook
        if notebook.clearCompletedContinuationNotes() {
            // An older client may complete a task without knowing the new field. Send an explicit
            // clear back, so a stale offline note cannot reappear if the task is later reopened.
            if let cleared = try replica?.apply(before: received, after: notebook, device: deviceID) {
                try replica?.check(cleared)
            }
            hasPendingChanges = true
        }
        return CheckedEdit()
    }

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw NotebookError.unsupportedVersion }
        guard !value.deviceID.isEmpty, value.replicaInUse == (value.replica != nil) else { throw NotebookError.invalidData }
        // The book was just read from these bytes; what is left to check is that it keeps its rules.
        try NotebookCodec.validate(value.notebook)
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

extension Data {
    /// Written so it stays readable while the phone is locked after its first unlock: the app is woken in the
    /// background (lock-screen buttons, sync) and must be able to read and save its data then.
    func writeState(to url: URL) throws {
        #if os(iOS)
        try write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try write(to: url, options: .atomic)
        #endif
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
    /// The bytes last read or written and found valid. Saving keeps the current file as the previous one only
    /// when it is valid; when it is exactly what was last checked, checking it again (which rebuilds the whole
    /// sync history) is skipped, so each edit stays quick.
    private final class KnownGood { var data: Data? }
    private let knownGood = KnownGood()
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> SharedStoreState {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let state = try SharedStoreState.decode(data)
            knownGood.data = data
            return state
        }
        let state = SharedStoreState(notebook: try legacy.load())
        try save(state)
        return state
    }

    public func save(_ state: SharedStoreState) throws {
        let data = try state.encoded()
        _ = try SharedStoreState.decode(data)
        try write(data)
    }

    /// Saves a state right after `edit` or `receive` checked the change it holds. The file as a whole is not read back:
    /// it is the file this repository last read or wrote, plus that change. Before this repository has read or
    /// written the file, everything is checked as in `save(_:)`.
    public func save(_ state: SharedStoreState, after edit: SharedStoreState.CheckedEdit) throws {
        guard knownGood.data != nil else { return try save(state) }
        try write(state.encoded())
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            if previous != knownGood.data { _ = try SharedStoreState.decode(previous) }
            try previous.writeState(to: previousURL)
        }
        try data.writeState(to: url)
        knownGood.data = data
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
        try state.encoded().writeState(to: url)
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
        try state.encoded().writeState(to: url)
        return state
    }
}
