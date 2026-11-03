import Foundation
import SwiftUI
import CloudKit
import Network

/// A routine being timed on this device: which one, which day of it, and since when.
struct RoutineRun: Codable, Equatable {
    var routineID: UUID
    var day: String
    var startedAt: Date
}

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()
    /// Kept on this device only, so a running timer survives the app being closed.
    @Published private(set) var routineRun: RoutineRun? = TaskStore.loadRoutineRun()
    @Published private(set) var notebook = Notebook()
    @Published var error: String?
    /// Items checked off while this screen is open. They stay visible, struck through, so a mistaken tap
    /// can be seen and undone; leaving the screen clears them. Never saved or synced.
    @Published private(set) var recentlyDone: Set<String> = []
    @Published private(set) var loadFailed = false
    /// Sample data shown in memory only. Saving, syncing, notifications and the Claude bridge leave the real
    /// data alone while it is on; ending demo mode or quitting the app brings the real data back.
    @Published private(set) var isDemo = false
    /// A short "取り消す" offer after an action that is hard to redo by hand (deleting, moving, bulk changes).
    @Published private(set) var undoOffer: UndoOffer?
    /// Recent states in memory, only to serve the undo offer. Never written to disk or synced.
    private var history: [Notebook] = []
    private let repository: SharedStoreRepository
    private var state = SharedStoreState()
    private let cloud = CloudSyncTransport()
    private let bridge = BridgeTransport()
    @Published private(set) var isBridgeSyncing = false
    @Published private(set) var bridgeSyncedAt: Date?
    @Published var bridgeError: String?
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
        moveCardsIntoProjectsOnce()
    }

    /// The saved data, even while demo mode shows samples. Notifications are planned from this.
    var realNotebook: Notebook { state.notebook }

    @discardableResult
    func commit(_ update: (inout Notebook) -> Void) -> Bool {
        guard isDemo || !loadFailed else { error = "読み込みに失敗したデータを保護しています。設定から直前の保存を復旧してください。"; return false }
        var next = notebook
        update(&next)
        guard next != notebook else { return true }
        // Any new change replaces the previous undo offer, so 取り消す always reverts what it names.
        undoOffer = nil
        if isDemo { remember(notebook); notebook = next; return true }
        do {
            var changed = state
            try changed.edit(next)
            try repository.save(changed)
            remember(notebook)
            state = changed; notebook = next
            requestSync()
            return true
        } catch { self.error = "保存できませんでした。変更は反映していません。\(error.localizedDescription)"; return false }
    }

    private func remember(_ book: Notebook) {
        history.append(book)
        if history.count > 5 { history.removeFirst() }
    }

    /// Shows "取り消す" for a few seconds after the change just made.
    func offerUndo(_ message: String) {
        let offer = UndoOffer(message: message)
        undoOffer = offer
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.undoOffer?.id == offer.id { self?.undoOffer = nil }
        }
    }

    func dismissUndo() { undoOffer = nil }

    func undo() {
        guard undoOffer != nil, let previous = history.last else { return }
        undoOffer = nil
        if isDemo { notebook = previous; history.removeLast(); return }
        do {
            var changed = state
            try changed.edit(previous)
            try repository.save(changed)
            state = changed; notebook = previous; history.removeLast()
            requestSync()
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Demo mode

    func startDemo() {
        guard !isDemo, !loadFailed else { return }
        scheduledSync?.cancel(); scheduledSync = nil
        history = []; recentlyDone = []; undoOffer = nil
        notebook = .demo(now: Date())
        isDemo = true
    }

    func endDemo() {
        guard isDemo else { return }
        isDemo = false
        history = []; recentlyDone = []; undoOffer = nil
        notebook = state.notebook
        // A timer started on a sample routine has nothing to finish once the samples are gone.
        if let run = routineRun, !notebook.routines.contains(where: { $0.id == run.routineID }) { cancelRoutineTimer() }
        requestSync()
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

    // MARK: Routine timer

    private static let routineRunKey = "horme.routineRun"

    private static func loadRoutineRun() -> RoutineRun? {
        UserDefaults.standard.data(forKey: routineRunKey).flatMap { try? JSONDecoder().decode(RoutineRun.self, from: $0) }
    }

    private func saveRoutineRun() {
        if let routineRun, let data = try? JSONEncoder().encode(routineRun) {
            UserDefaults.standard.set(data, forKey: Self.routineRunKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.routineRunKey)
        }
    }

    func isTiming(_ item: AgendaItem) -> Bool {
        guard case .routine(let id, let day) = item.source, let run = routineRun else { return false }
        return run.routineID == id && run.day == day
    }

    /// Starts timing one day of a routine. Only one runs at a time; starting another drops the first.
    func startRoutineTimer(_ item: AgendaItem) {
        guard case .routine(let id, let day) = item.source else { return }
        routineRun = RoutineRun(routineID: id, day: day, startedAt: Date())
        saveRoutineRun()
    }

    /// Stops the timer: that day of the routine is done, with the time it took.
    func finishRoutineTimer() {
        guard let run = routineRun else { return }
        let seconds = Int(Date().timeIntervalSince(run.startedAt))
        if commit({ $0.finishRoutine(run.routineID, originalDay: run.day, seconds: seconds) }) {
            routineRun = nil
            saveRoutineRun()
        }
    }

    func cancelRoutineTimer() {
        routineRun = nil
        saveRoutineRun()
    }

    /// Moves a row to another day and time. A routine moves for that one day only.
    /// No undo offer: a drag on the week grid is easy to drag back, and a banner there gets in the way.
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
        let saved = commit { book in
            for i in book.tasks.indices where ids.contains(book.tasks[i].id) {
                book.tasks[i].plannedAt = day
                // A time from an earlier day rarely still fits; keep the day, let the person pick a time again.
                if day == nil { book.tasks[i].slot = nil }
            }
        }
        if saved { offerUndo("\(ids.count)件を\(day.map { PlainText.dayTitle($0) } ?? "いつでも")へ移しました") }
    }

    func completeAll(_ ids: Set<UUID>) {
        let saved = commit { book in
            for i in book.tasks.indices where ids.contains(book.tasks[i].id) && !book.tasks[i].isComplete {
                book.tasks[i].completedAt = Date()
            }
            if let active = book.activeSession, ids.contains(active.taskID) { book.activeSession = nil }
        }
        if saved { offerUndo("\(ids.count)件を完了にしました") }
    }

    func deleteAll(_ ids: Set<UUID>) {
        let saved = commit { book in
            book.tasks.removeAll { ids.contains($0.id) }
            if let active = book.activeSession, ids.contains(active.taskID) { book.activeSession = nil }
        }
        if saved { offerUndo("\(ids.count)件を削除しました") }
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
        let title = routine(id)?.title ?? ""
        if commit({ $0.routines.removeAll { $0.id == id } }) { offerUndo("ルーティン「\(title)」を削除しました") }
    }

    func delete(_ id: UUID) {
        let title = task(id)?.title ?? ""
        let saved = commit { book in
            book.tasks.removeAll { $0.id == id }
            if book.activeSession?.taskID == id { book.activeSession = nil }
        }
        if saved { offerUndo("「\(title)」を削除しました") }
    }

    func deleteIdea(_ id: UUID) {
        if commit({ $0.ideas.removeAll { $0.id == id } }) { offerUndo("付箋をはがしました") }
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

    func makeTasks(from idea: Idea, _ drafts: [TaskItem], keepIdea: Bool) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }) else {
            error = "このアイデアはすでに削除またはタスク化されています。最新の一覧を確認してください。"
            return false
        }
        return commit { $0.makeTasks(fromIdea: idea.id, drafts, keepIdea: keepIdea) }
    }

    func saveIdea(_ idea: Idea) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }) else {
            error = "このアイデアは別の端末で削除またはタスク化されました。入力した内容をコピーしてから閉じてください。"
            return false
        }
        return commit { book in
            if let index = book.ideas.firstIndex(where: { $0.id == idea.id }) {
                book.ideas[index].text = idea.text
                book.ideas[index].touchedAt = Date()
            }
        }
    }

    func idea(_ id: UUID) -> Idea? { notebook.ideas.first { $0.id == id } }

    /// Opening an idea warms it. Once an hour is enough; every glance need not be a change to sync.
    func touchIdea(_ id: UUID) {
        guard let idea = idea(id), Date().timeIntervalSince(idea.lastTouched) > 3600 else { return }
        commit { book in
            if let index = book.ideas.firstIndex(where: { $0.id == id }) { book.ideas[index].touchedAt = Date() }
        }
    }

    /// A line added to an idea (メモ). It warms the idea, and lets it become fully warm.
    func addIdeaNote(_ text: String, to id: UUID) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        guard idea(id) != nil else {
            error = "このアイデアは別の端末で削除またはタスク化されました。"
            return false
        }
        return commit { book in
            guard let index = book.ideas.firstIndex(where: { $0.id == id }) else { return }
            book.ideas[index].notes.append(IdeaNote(text: line))
            book.ideas[index].touchedAt = Date()
        }
    }

    func deleteIdeaNote(_ noteID: UUID, from id: UUID) {
        commit { book in
            guard let index = book.ideas.firstIndex(where: { $0.id == id }) else { return }
            book.ideas[index].notes.removeAll { $0.id == noteID }
        }
    }

    func card(_ id: UUID) -> BoardCard? { notebook.boardCards.first { $0.id == id } }

    /// A task's or routine's cards are those of its project.
    func linkedCard(for task: TaskItem) -> BoardCard? { linkedCard(forProject: task.project) }

    func linkedCard(forProject project: String) -> BoardCard? { projectCards(ProjectBook.key(project)).first }

    func projectCards(_ key: String) -> [BoardCard] { key.isEmpty ? [] : ProjectBook.cards(key, in: notebook) }

    func linkedRoutines(for card: BoardCard) -> [Routine] {
        let key = ProjectBook.key(card.project)
        return key.isEmpty ? [] : ProjectBook.routines(key, in: notebook)
    }

    func linkedTasks(for card: BoardCard) -> [TaskItem] {
        let key = ProjectBook.key(card.project)
        return key.isEmpty ? [] : ProjectBook.tasks(key, in: notebook)
    }

    /// New cards go on top, where the person just typed.
    @discardableResult
    func upsertCard(_ card: BoardCard) -> Bool {
        commit { book in
            if let i = book.boardCards.firstIndex(where: { $0.id == card.id }) { book.boardCards[i] = card }
            else { book.boardCards.insert(card, at: 0) }
        }
    }

    // MARK: Projects

    var projectEntries: [ProjectBook.Entry] { ProjectBook.entries(notebook) }

    func projectEntry(_ key: String) -> ProjectBook.Entry? { ProjectBook.entry(key, in: notebook) }

    func savedProject(_ key: String) -> Project? { notebook.projects.first { ProjectBook.key($0.name) == key } }

    /// Saves the goal, deadline and name. A new name reaches every task, routine and card of the project.
    @discardableResult
    func saveProject(_ project: Project, renaming oldKey: String?) -> Bool {
        commit { book in
            if let oldKey, !oldKey.isEmpty, oldKey != ProjectBook.key(project.name) {
                ProjectBook.rename(oldKey, to: project.name, in: &book)
            }
            if let i = book.projects.firstIndex(where: { $0.id == project.id }) {
                var merged = project
                // Checkpoints are edited on the page, possibly while this form was open.
                merged.milestones = book.projects[i].milestones
                book.projects[i] = merged
            } else { book.projects.append(project) }
        }
    }

    func deleteProject(_ key: String) {
        let name = projectEntry(key)?.name ?? ""
        if commit({ ProjectBook.remove(key, from: &$0) }) { offerUndo("プロジェクト「\(name)」を外しました") }
    }

    /// Changes a project's record, making one first for a project that was only a name.
    private func editProject(_ key: String, _ update: (inout Project) -> Void) -> Bool {
        commit { book in
            if let i = book.projects.firstIndex(where: { ProjectBook.key($0.name) == key }) {
                update(&book.projects[i])
            } else {
                let name = ProjectBook.entry(key, in: book)?.name ?? key
                var project = Project(name: name)
                update(&project)
                book.projects.append(project)
            }
        }
    }

    @discardableResult
    func saveMilestone(_ milestone: Milestone, in key: String) -> Bool {
        editProject(key) { project in
            if let i = project.milestones.firstIndex(where: { $0.id == milestone.id }) { project.milestones[i] = milestone }
            else { project.milestones.append(milestone) }
        }
    }

    func deleteMilestone(_ id: UUID, in key: String) {
        let title = savedProject(key)?.milestones.first { $0.id == id }?.title ?? ""
        let removed = commit { book in
            for i in book.projects.indices where ProjectBook.key(book.projects[i].name) == key {
                book.projects[i].milestones.removeAll { $0.id == id }
            }
            for i in book.tasks.indices where book.tasks[i].milestoneID == id { book.tasks[i].milestoneID = nil }
            for i in book.routines.indices where book.routines[i].milestoneID == id { book.routines[i].milestoneID = nil }
        }
        if removed { offerUndo("通過点「\(title)」を消しました") }
    }

    func moveMilestone(_ id: UUID, in key: String, by offset: Int) {
        _ = editProject(key) { project in
            guard let i = project.milestones.firstIndex(where: { $0.id == id }) else { return }
            let j = min(max(i + offset, 0), project.milestones.count - 1)
            guard i != j else { return }
            project.milestones.swapAt(i, j)
        }
    }

    /// ＋1 on a count, or the check on a checkpoint.
    func advanceMilestone(_ id: UUID, in key: String) {
        _ = editProject(key) { project in
            guard let i = project.milestones.firstIndex(where: { $0.id == id }) else { return }
            switch project.milestones[i].kind {
            case .count: project.milestones[i].current += 1
            case .check: project.milestones[i].isDone.toggle()
            case .number, .tasks: break
            }
        }
    }

    /// A project grown from an idea: the idea's words become its origin, and its notes an overview card if asked.
    @discardableResult
    func makeProject(_ project: Project, from idea: Idea, overviewCard: Bool, keepIdea: Bool) -> Bool {
        commit { book in
            let key = ProjectBook.key(project.name)
            if let i = book.projects.firstIndex(where: { ProjectBook.key($0.name) == key }) {
                // Same name as a project already there: the idea joins it instead of splitting it in two.
                if book.projects[i].origin.isEmpty { book.projects[i].origin = project.origin }
                if book.projects[i].goal.isEmpty { book.projects[i].goal = project.goal }
                if book.projects[i].deadline == nil { book.projects[i].deadline = project.deadline }
            } else { book.projects.append(project) }
            if overviewCard {
                let notes = idea.notes.map { "・\($0.text)" }.joined(separator: "\n")
                let detail = notes.isEmpty ? idea.text : "\(idea.text)\n\n\(notes)"
                book.boardCards.insert(BoardCard(title: "概要", goal: project.goal, detail: detail, project: project.name), at: 0)
            }
            if !keepIdea { book.ideas.removeAll { $0.id == idea.id } }
        }
    }

    /// Once per device: cards that tasks reached by name join that project (see ProjectBook.moveCardsIntoProjects).
    private func moveCardsIntoProjectsOnce() {
        let key = "horme.projectsMigrated"
        guard !loadFailed, !UserDefaults.standard.bool(forKey: key) else { return }
        if commit({ ProjectBook.moveCardsIntoProjects(&$0) }) { UserDefaults.standard.set(true, forKey: key) }
    }

    func deleteCard(_ id: UUID) {
        let title = card(id)?.title ?? ""
        if commit({ $0.boardCards.removeAll { $0.id == id } }) { offerUndo("カード「\(title)」を削除しました") }
    }

    func moveCards(from source: IndexSet, to destination: Int) {
        commit { $0.boardCards.move(fromOffsets: source, toOffset: destination) }
    }

    var canRecoverPrevious: Bool { FileManager.default.fileExists(atPath: repository.previousURL.path) }

    /// The unreadable file stays on the device; this only lets the person continue or restore a backup.
    func startOver() {
        do {
            state = try repository.startFresh(); notebook = state.notebook; loadFailed = false
            history = []; undoOffer = nil
        } catch { self.error = "読めないデータを退避できませんでした。\(error.localizedDescription)" }
    }

    func recover() {
        do {
            state = try repository.recoverPrevious(); notebook = state.notebook; loadFailed = false
            history = []; undoOffer = nil
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
        guard connection != nil || bridgeOn, !loadFailed, !isDemo else { return }
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            // Clear the debounce task before entering network work; a new edit
            // must not cancel a sync that already has writes in flight.
            self?.scheduledSync = nil
            await self?.synchronize()
            await self?.synchronizeBridge()
        }
    }

    // MARK: Claude bridge

    var bridgeOn: Bool { state.bridge == true }
    var bridgeMCPURL: String? { BridgeLink.load().map { $0 + "/mcp" } }

    /// Connects to the bridge and merges both ways. Existing data on either side is kept.
    func connectBridge(_ text: String) async -> Bool {
        guard !isDemo else { bridgeError = "デモモード中は共有や連携の設定を変えられません。設定からデモモードを終えてください。"; return false }
        guard !loadFailed else { return false }
        guard let link = BridgeLink.normalized(text) else { bridgeError = BridgeError.invalidLink.localizedDescription; return false }
        do {
            // Check the link before changing anything locally.
            _ = try await bridge.synchronize(link: link, records: [])
            guard BridgeLink.save(link) else { bridgeError = "鍵をこの端末に保存できませんでした。"; return false }
            var next = state
            next.bridge = true
            try next.startReplicaIfNeeded()
            try repository.save(next)
            state = next; bridgeError = nil
            await synchronizeBridge()
            return bridgeError == nil
        } catch { bridgeError = error.localizedDescription; return false }
    }

    func disconnectBridge() {
        guard !isDemo else { bridgeError = "デモモード中は共有や連携の設定を変えられません。設定からデモモードを終えてください。"; return }
        do {
            var next = state
            next.bridge = nil
            if next.connection == nil { next.replica = nil; next.hasPendingChanges = false }
            try repository.save(next)
            BridgeLink.delete()
            state = next; bridgeSyncedAt = nil; bridgeError = nil
        } catch { self.error = error.localizedDescription }
    }

    func synchronizeBridge() async {
        guard bridgeOn, !isBridgeSyncing, !loadFailed, !isDemo, let link = BridgeLink.load(), let replica = state.replica else { return }
        isBridgeSyncing = true
        defer { isBridgeSyncing = false }
        do {
            let merged = try await bridge.synchronize(link: link, records: Array(replica.records.values))
            guard bridgeOn, let current = state.replica else { return }
            var next = state
            try next.receive(merged)
            let changed = next.replica?.records != current.records
            if changed {
                if !Self.sameContents(notebook, next.notebook) {
                    try repository.backup(notebook, beforeSharing: false)
                    // Do not apply a stale whole-book undo over Claude's change.
                    history = []; undoOffer = nil
                }
                // Changes from Claude still need to reach the other device through iCloud.
                if next.connection != nil { next.hasPendingChanges = true }
                try repository.save(next)
                state = next; notebook = next.notebook
            }
            bridgeSyncedAt = Date(); bridgeError = nil
            if changed && connection != nil { await synchronize() }
        } catch {
            bridgeError = "Claudeとの同期に失敗しました。\(error.localizedDescription) 端末のデータは保存されています。"
        }
    }

    func synchronize() async {
        guard !isSyncing, !loadFailed, !isDemo, Date() >= retryAfter,
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
                history = []; undoOffer = nil
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
        guard !isDemo else { syncError = "デモモード中は共有や連携の設定を変えられません。設定からデモモードを終えてください。"; return }
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
        // Opening an invitation is a deliberate step toward the real data.
        endDemo()
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
        guard !isDemo else { syncError = "デモモード中は共有や連携の設定を変えられません。設定からデモモードを終えてください。"; return }
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
            history = []; undoOffer = nil; syncError = nil; retryAfter = .distantPast
            UIApplication.shared.registerForRemoteNotifications()
            await synchronize()
            if pending.openShareAfterJoin, syncError == nil { await prepareSharing() }
        } catch { syncError = Self.describe(error) }
    }

    func disconnectSync() {
        guard !isDemo else { syncError = "デモモード中は共有や連携の設定を変えられません。設定からデモモードを終えてください。"; return }
        guard !loadFailed else { return }
        do {
            var next = state
            next.connection = nil; next.lastSyncedAt = nil; next.hasPendingChanges = false
            // The Claude bridge keeps using the replica after iCloud is turned off.
            if next.bridge != true { next.replica = nil }
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
            copy.projects.sort { $0.id.uuidString < $1.id.uuidString }
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

struct UndoOffer: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

extension Notebook {
    /// Sample data for demo mode, dated around today so every screen has something to show.
    static func demo(now: Date) -> Notebook {
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now) ?? now }
        let earlier = day(-30)
        let test = Milestone(title: "予想問題を解く", kind: .count, target: 5, current: 2, unit: "回", createdAt: earlier)
        let part7 = Milestone(title: "長文を時間内に解く", kind: .tasks, createdAt: earlier)
        let english = Project(name: "英語の勉強", goal: "本番で500点", deadline: day(41), milestones: [
            Milestone(title: "単語帳を1周する", kind: .check, isDone: true, createdAt: earlier),
            test,
            Milestone(title: "模試で450点", kind: .number, target: 450, current: 420, unit: "点", createdAt: earlier),
            part7
        ], createdAt: earlier)
        return Notebook(tasks: [
            TaskItem(title: "予想問題 第4回を解く", plannedAt: now, scheduledTime: "20:30-21:30", effort: .heavy,
                     project: "英語の勉強", milestoneID: test.id),
            TaskItem(title: "長文 時間を計って10問", plannedAt: day(-1), effort: .medium, project: "英語の勉強",
                     completedAt: day(-1), milestoneID: part7.id),
            TaskItem(title: "長文を1本解き直す", plannedAt: day(1), effort: .medium, project: "英語の勉強", milestoneID: part7.id),
            TaskItem(title: "本番", plannedAt: day(41), project: "英語の勉強", isEvent: true),
            TaskItem(title: "提出書類を送る", plannedAt: now, deadline: now, isMust: true, effort: .light,
                     memo: "これはサンプルです。", steps: [Step(title: "宛先を確認する"), Step(title: "メールに添付して送る")]),
            TaskItem(title: "予約の電話をする", plannedAt: now, scheduledTime: "14:00-14:15", effort: .light,
                     handoff: "受付時間を調べておいて"),
            TaskItem(title: "読みかけの本を読む", effort: .light, resumeNote: "42ページの途中まで"),
            TaskItem(title: "提案の下書きをつくる", plannedAt: day(1), scheduledTime: "10:00-11:30", deadline: day(2),
                     effort: .heavy, project: "仕事", steps: [Step(title: "見出しを3つ書く")]),
            TaskItem(title: "友達とランチ", plannedAt: now, scheduledTime: "12:00-13:30", memo: "駅前のお店", isEvent: true),
            TaskItem(title: "買い物に行く", plannedAt: day(2), isEvent: true),
            TaskItem(title: "図書館に本を返す", plannedAt: day(-1)),
            TaskItem(title: "気になる資料を読む", effort: .medium)
        ], ideas: [
            Idea(text: "散歩中に聞ける勉強メモを作れそう", notes: [IdeaNote(text: "通勤の15分で聞ける長さにする")])
        ], boardCards: [
            BoardCard(title: "部屋のリセット", purpose: "散らかった机が目に入ると、始める前に気力が削られるため。",
                      goal: "机の上に、いま使う物しかない状態。",
                      detail: "これはサンプルです。\n\n1. タイマーを15分にする\n2. 床の物を1か所に集める\n3. 机の上を「戻す・捨てる・保留」に分ける\n4. 保留は箱に入れて、今日は考えない\n\n▸ 15分で止める。全部やろうとしない",
                      createdAt: earlier, project: "部屋のリセット"),
            BoardCard(title: "単語のやり方", purpose: "単語は毎日少しずつが効く。", goal: "未チェックの単語をなくす。",
                      detail: "これはサンプルです。\n\n1. 日本語側を隠す\n2. 英語を見て2秒で意味を言う\n3. 出なければ即×。粘らない",
                      createdAt: earlier, project: "英語の勉強")
        ], routines: [
            Routine(title: "単語を回す", project: "英語の勉強", weekdays: [2, 3, 4, 5, 6], time: "19:00-19:30", createdAt: earlier),
            Routine(title: "部屋をリセットする", project: "部屋のリセット", time: "21:00-21:15", createdAt: earlier),
            Routine(title: "仕事", weekdays: [2, 3, 4, 5, 6], time: "9:00-18:00", notify: false, isBlock: true, createdAt: earlier),
            Routine(title: "睡眠", time: "0:00-7:00", notify: false, isBlock: true, createdAt: earlier)
        ], projects: [english])
    }
}
