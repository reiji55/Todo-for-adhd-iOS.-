import Foundation
import SwiftUI
import CloudKit
import Network

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()
    @Published private(set) var notebook = Notebook()
    @Published var error: String?
    /// Items checked off while this screen is open. They stay visible, struck through, so a mistaken tap
    /// can be seen and undone; leaving the screen clears them. Never saved or synced.
    @Published private(set) var recentlyDone: Set<String> = []
    @Published private(set) var loadFailed = false
    @Published private(set) var canUndo = false
    private var history: [Notebook] = []
    private let repository: SharedStoreRepository
    private var state = SharedStoreState()
    private let cloud = CloudSyncTransport()
    @Published private(set) var isSyncing = false
    @Published private(set) var isPreparingShare = false
    @Published var syncError: String?
    @Published var pendingJoin: PendingCloudJoin?
    @Published var sharingSheet: CloudSharingSheet?
    private var syncGeneration = UUID()
    private var scheduledSync: Task<Void, Never>?
    private var foregroundRefresh: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private let network = NWPathMonitor()
    private var accountObserver: NSObjectProtocol?

    var connection: SyncConnection? { state.connection }
    var lastSyncedAt: Date? { state.lastSyncedAt }
    var hasPendingChanges: Bool { state.hasPendingChanges }
    var hasSharingBackup: Bool { FileManager.default.fileExists(atPath: repository.safetyBackupURL.path) }
    var hasSyncBackup: Bool { FileManager.default.fileExists(atPath: repository.syncBackupURL.path) }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeDays", isDirectory: true)
        repository = SharedStoreRepository(directory: directory)
        do { state = try repository.load(); notebook = state.notebook }
        catch { loadFailed = true; self.error = "保存データを開けませんでした。\(error.localizedDescription)" }
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.requestSync() }
        }
        network.start(queue: DispatchQueue(label: "Horme.network"))
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestSync() }
        }
    }

    @discardableResult
    func commit(_ update: (inout Notebook) -> Void) -> Bool {
        guard !loadFailed else { error = "読み込みに失敗したデータを保護しています。設定から直前の保存を復旧してください。"; return false }
        var next = notebook
        update(&next)
        guard next != notebook else { return true }
        do {
            var changed = state
            try changed.edit(next)
            try repository.save(changed)
            history.append(notebook)
            if history.count > 20 { history.removeFirst() }
            state = changed; notebook = next; canUndo = !history.isEmpty
            requestSync()
            return true
        } catch { self.error = "保存できませんでした。変更は反映していません。\(error.localizedDescription)"; return false }
    }

    func undo() {
        guard let previous = history.last else { return }
        do {
            var changed = state
            try changed.edit(previous)
            try repository.save(changed)
            state = changed; notebook = previous; history.removeLast(); canUndo = !history.isEmpty
            requestSync()
        } catch { self.error = error.localizedDescription }
    }

    func task(_ id: UUID) -> TaskItem? { notebook.tasks.first { $0.id == id } }

    func upsert(_ task: TaskItem, original: TaskItem? = nil) -> Bool {
        var edited = task
        if let original {
            guard let current = self.task(task.id) else {
                error = "このタスクは別の端末で削除されました。入力した内容をコピーしてから閉じてください。"
                return false
            }
            do { edited = try SyncReplica.editedTask(original: original, edited: task, current: current) }
            catch { self.error = error.localizedDescription; return false }
        }
        return commit { book in
            if let i = book.tasks.firstIndex(where: { $0.id == edited.id }) { book.tasks[i] = edited }
            else { book.tasks.append(edited) }
        }
    }

    func change(_ id: UUID, _ update: (inout TaskItem) -> Void) {
        commit { book in
            if let i = book.tasks.firstIndex(where: { $0.id == id }) { update(&book.tasks[i]) }
        }
    }

    func complete(_ id: UUID) {
        let finishing = task(id)?.isComplete == false
        let saved = commit { book in
            guard let i = book.tasks.firstIndex(where: { $0.id == id }) else { return }
            book.tasks[i].completedAt = book.tasks[i].isComplete ? nil : Date()
            if book.activeSession?.taskID == id { book.activeSession = nil }
        }
        if saved && finishing { recentlyDone.insert("task-\(id.uuidString)") }
    }

    /// Checks or unchecks one agenda row, whether it is a task or one day of a routine.
    func toggle(_ item: AgendaItem) {
        switch item.source {
        case .task(let id): complete(id)
        case .routine(let id, let day):
            let finishing = !item.isDone
            if commit({ $0.toggleRoutine(id, originalDay: day) }) && finishing { recentlyDone.insert(item.id) }
        }
    }

    func clearRecentlyDone() { if !recentlyDone.isEmpty { recentlyDone = [] } }

    /// Moves a row to another day and time. A routine moves for that one day only.
    func move(_ item: AgendaItem, to day: Date, slot: TimeSlot?) {
        commit { book in
            switch item.source {
            case .task(let id): book.moveTask(id, to: day, slot: slot)
            case .routine(let id, let original):
                book.moveRoutine(id, originalDay: original, toDay: DayKey.of(day), time: slot?.label ?? "")
            }
        }
    }

    // MARK: Leftovers from earlier days

    func plan(_ ids: Set<UUID>, on day: Date?) {
        commit { book in
            for i in book.tasks.indices where ids.contains(book.tasks[i].id) {
                book.tasks[i].plannedAt = day
                // A time from an earlier day rarely still fits; keep the day, let the person pick a time again.
                if day == nil { book.tasks[i].slot = nil }
            }
        }
    }

    func completeAll(_ ids: Set<UUID>) {
        commit { book in
            for i in book.tasks.indices where ids.contains(book.tasks[i].id) && !book.tasks[i].isComplete {
                book.tasks[i].completedAt = Date()
            }
            if let active = book.activeSession, ids.contains(active.taskID) { book.activeSession = nil }
        }
    }

    func deleteAll(_ ids: Set<UUID>) {
        commit { book in
            book.tasks.removeAll { ids.contains($0.id) }
            if let active = book.activeSession, ids.contains(active.taskID) { book.activeSession = nil }
        }
    }

    // MARK: Routines

    func routine(_ id: UUID) -> Routine? { notebook.routines.first { $0.id == id } }

    @discardableResult
    func upsertRoutine(_ routine: Routine) -> Bool {
        commit { book in
            if let i = book.routines.firstIndex(where: { $0.id == routine.id }) {
                // Keep checks and moves made elsewhere while the editor was open.
                var merged = routine
                merged.doneDays = book.routines[i].doneDays
                merged.moves = book.routines[i].moves
                book.routines[i] = merged
            } else { book.routines.append(routine) }
        }
    }

    func deleteRoutine(_ id: UUID) {
        commit { $0.routines.removeAll { $0.id == id } }
    }

    func delete(_ id: UUID) {
        commit { book in
            book.tasks.removeAll { $0.id == id }
            if book.activeSession?.taskID == id { book.activeSession = nil }
        }
    }

    func start(_ task: TaskItem) {
        commit { $0.startTask(task.id) }
    }

    func pause(note: String) -> Bool {
        commit { $0.pauseTask(note: note) }
    }

    func finishAction() -> Bool {
        commit { $0.finishAction() }
    }

    func convert(_ idea: Idea, plannedAt: Date?) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }), task(idea.id) == nil else {
            error = "このアイデアはすでに削除またはタスク化されています。最新の一覧を確認してください。"
            return false
        }
        return commit { $0.convertIdea(idea.id, plannedAt: plannedAt) }
    }

    func saveIdea(_ idea: Idea) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }) else {
            error = "このアイデアは別の端末で削除またはタスク化されました。入力した内容をコピーしてから閉じてください。"
            return false
        }
        return commit { book in
            if let index = book.ideas.firstIndex(where: { $0.id == idea.id }) { book.ideas[index].text = idea.text }
        }
    }

    func card(_ id: UUID) -> BoardCard? { notebook.boardCards.first { $0.id == id } }

    func linkedCard(for task: TaskItem) -> BoardCard? { BoardLink.card(for: task, in: notebook.boardCards) }

    func linkedRoutines(for card: BoardCard) -> [Routine] {
        notebook.routines.filter { BoardLink.card(forProject: $0.project, in: notebook.boardCards)?.id == card.id }
    }

    func linkedTasks(for card: BoardCard) -> [TaskItem] {
        BoardLink.tasks(for: card, in: notebook.tasks, cards: notebook.boardCards)
    }

    /// New cards go on top, where the person just typed.
    @discardableResult
    func upsertCard(_ card: BoardCard) -> Bool {
        commit { book in
            if let i = book.boardCards.firstIndex(where: { $0.id == card.id }) {
                // Renaming a card would silently cut its link to tasks named after it, so carry them along.
                if BoardLink.normalized(book.boardCards[i].title) != BoardLink.normalized(card.title) {
                    let linkedTasks = Set(BoardLink.tasks(for: book.boardCards[i], in: book.tasks, cards: book.boardCards).map(\.id))
                    for j in book.tasks.indices where linkedTasks.contains(book.tasks[j].id) { book.tasks[j].project = card.title }
                    for j in book.routines.indices
                    where BoardLink.card(forProject: book.routines[j].project, in: book.boardCards)?.id == card.id {
                        book.routines[j].project = card.title
                    }
                }
                book.boardCards[i] = card
            } else { book.boardCards.insert(card, at: 0) }
        }
    }

    func deleteCard(_ id: UUID) {
        commit { $0.boardCards.removeAll { $0.id == id } }
    }

    func moveCards(from source: IndexSet, to destination: Int) {
        commit { $0.boardCards.move(fromOffsets: source, toOffset: destination) }
    }

    var canRecoverPrevious: Bool { FileManager.default.fileExists(atPath: repository.previousURL.path) }

    /// The unreadable file stays on the device; this only lets the person continue or restore a backup.
    func startOver() {
        do {
            state = try repository.startFresh(); notebook = state.notebook; loadFailed = false
            history = []; canUndo = false
        } catch { self.error = "読めないデータを退避できませんでした。\(error.localizedDescription)" }
    }

    func recover() {
        do {
            state = try repository.recoverPrevious(); notebook = state.notebook; loadFailed = false
            history = []; canUndo = false
        } catch { self.error = "直前の保存から復旧できませんでした。\(error.localizedDescription)" }
    }

    func setForeground(_ active: Bool) {
        foregroundRefresh?.cancel(); foregroundRefresh = nil
        guard active else { return }
        requestSync()
        foregroundRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.requestSync()
            }
        }
    }

    func requestSync() {
        guard connection != nil, !loadFailed else { return }
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            // Clear the debounce task before entering network work; a new edit
            // must not cancel a sync that already has writes in flight.
            self?.scheduledSync = nil
            await self?.synchronize()
        }
    }

    func synchronize() async {
        guard !isSyncing, !loadFailed, Date() >= retryAfter,
              let connection, let replica = state.replica else { return }
        let generation = syncGeneration
        isSyncing = true
        defer { if generation == syncGeneration { isSyncing = false } }
        do {
            let result = try await cloud.synchronize(connection, local: replica) { [weak self] in
                self?.syncGeneration == generation && self?.connection == connection
            }
            guard generation == syncGeneration, state.connection == connection else { return }
            var next = state
            try next.receive(Array(result.records.values))
            next.hasPendingChanges = next.replica?.records != result.records
            next.lastSyncedAt = Date()
            if !Self.sameContents(notebook, next.notebook) {
                try repository.backup(notebook, beforeSharing: false)
                // Do not apply a stale whole-book undo over a remote change.
                history = []; canUndo = false
            }
            try repository.save(next)
            state = next; notebook = next.notebook; syncError = nil; retryAfter = .distantPast
            if next.hasPendingChanges { requestSync() }
        } catch {
            guard generation == syncGeneration else { return }
            syncError = Self.describe(error)
            let delay = (error as? CKError)?.retryAfterSeconds ?? 30
            retryAfter = Date().addingTimeInterval(max(5, delay))
            // The replica remains durable. Foreground refresh, reconnection and
            // silent notifications retry without blocking task entry.
        }
    }

    func prepareSharing() async {
        guard !loadFailed, !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            if let connection {
                await synchronize()
                // An outstanding local change is not a reason to lose access to
                // the existing share-management UI.
                let share = try await cloud.share(for: connection)
                sharingSheet = CloudSharingSheet(share: share, container: cloud.container)
            } else {
                let snapshot = try await cloud.prepareOwnData()
                pendingJoin = try PendingCloudJoin(snapshot: snapshot, local: notebook, openShareAfterJoin: true)
            }
            syncError = nil
        } catch { syncError = Self.describe(error) }
    }

    func acceptInvitation(_ metadata: CKShare.Metadata) async {
        guard !loadFailed, !isPreparingShare else { return }
        guard metadata.containerIdentifier == CloudSyncTransport.containerID else { syncError = CloudSyncError.wrongContainer.localizedDescription; return }
        if let connection {
            let id = metadata.share.recordID.zoneID
            if connection.zoneName == id.zoneName && connection.ownerName == id.ownerName {
                await synchronize(); return
            }
            error = CloudSyncError.differentShare.localizedDescription; return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let snapshot = try await cloud.accept(metadata)
            pendingJoin = try PendingCloudJoin(snapshot: snapshot, local: notebook, openShareAfterJoin: false)
            syncError = nil
        } catch { self.error = Self.describe(error) }
    }

    func confirmJoin(_ pending: PendingCloudJoin) async {
        guard connection == nil, !loadFailed else { return }
        pendingJoin = nil
        do {
            try await cloud.verify(pending.snapshot.connection)
            var replica = pending.snapshot.replica
            let remote = try replica.materialize()
            // Rebuild the preview from the current local data in case the user
            // kept editing while the invitation was being fetched.
            let merge = ShareMergePreview(local: notebook, remote: remote)
            var next = state
            try replica.apply(before: remote, after: merge.combined, device: next.deviceID)
            next.replica = replica; next.connection = pending.snapshot.connection
            next.notebook = try replica.materialize(); next.lastSyncedAt = nil; next.hasPendingChanges = true
            try repository.backup(notebook, beforeSharing: true)
            try repository.save(next)
            syncGeneration = UUID(); state = next; notebook = next.notebook
            history = []; canUndo = false; syncError = nil; retryAfter = .distantPast
            UIApplication.shared.registerForRemoteNotifications()
            await synchronize()
            if pending.openShareAfterJoin, syncError == nil { await prepareSharing() }
        } catch { syncError = Self.describe(error) }
    }

    func disconnectSync() {
        guard !loadFailed else { return }
        do {
            var next = state
            next.connection = nil; next.replica = nil; next.lastSyncedAt = nil; next.hasPendingChanges = false
            try repository.save(next)
            syncGeneration = UUID(); scheduledSync?.cancel(); scheduledSync = nil
            state = next; notebook = next.notebook; isSyncing = false
            pendingJoin = nil; sharingSheet = nil; syncError = nil
        } catch { self.error = error.localizedDescription }
    }

    func sharingStopped() {
        sharingSheet = nil
        if connection?.isShared == true { disconnectSync() }
        else { requestSync() }
    }

    func backupData(beforeSharing: Bool) throws -> Data {
        try Data(contentsOf: beforeSharing ? repository.safetyBackupURL : repository.syncBackupURL)
    }

    private static func sameContents(_ left: Notebook, _ right: Notebook) -> Bool {
        func normalized(_ value: Notebook) -> Data? {
            var copy = value
            copy.tasks.sort { $0.id.uuidString < $1.id.uuidString }
            copy.ideas.sort { $0.id.uuidString < $1.id.uuidString }
            copy.routines.sort { $0.id.uuidString < $1.id.uuidString }
            return try? NotebookCodec.encode(copy)
        }
        return normalized(left) == normalized(right)
    }

    static func describe(_ error: Error) -> String {
        guard let cloud = error as? CKError else { return error.localizedDescription }
        switch cloud.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "接続を待っています。入力した内容は端末に保存済みです。通信が戻ると同期を再試行します。"
        case .notAuthenticated: return CloudSyncError.accountUnavailable.localizedDescription
        case .permissionFailure, .zoneNotFound, .userDeletedZone:
            return "共有にアクセスできません。共有元の権限や招待を確認してください。端末のデータは残っています。"
        case .quotaExceeded: return "iCloudの空き容量を確認してください。入力した内容は端末に保存されています。"
        case .badContainer, .badDatabase, .serverRejectedRequest, .invalidArguments, .missingEntitlement:
            return "この版のiCloud設定を確認する必要があります。アプリの開発者にお知らせください。端末のデータは保存されています。"
        default: return "同期できませんでした。少し待ってから「今すぐ同期」を試してください。端末のデータは保存されています。"
        }
    }
}
