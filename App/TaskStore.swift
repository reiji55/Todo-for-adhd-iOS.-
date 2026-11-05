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
    /// The day 今日を終える was pressed on, as a day key; any other day reads as open. Kept on this device.
    /// Demo mode keeps its own in memory, so practising never quiets real reminders.
    @Published private(set) var closedDay: String? = UserDefaults.standard.string(forKey: TaskStore.closedDayKey)
    static let closedDayKey = "horme.closedDay"
    @Published private(set) var notebook = Notebook() {
        // Data from an older version (or another device not yet updated) may still hold steps or a running
        // task timer; they become child tasks as soon as they arrive.
        didSet { if notebook.needsStepConversion { scheduleStepConversion() } }
    }
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
    /// A project to show on the board as soon as the screen in front of it closes (one just made from an idea).
    @Published var projectToOpen: String?
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
        // Property observers do not run during init, so data loaded here is converted explicitly.
        if notebook.needsStepConversion { scheduleStepConversion() }
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
        closedDay = nil
    }

    func endDemo() {
        guard isDemo else { return }
        isDemo = false
        history = []; recentlyDone = []; undoOffer = nil
        notebook = state.notebook
        closedDay = UserDefaults.standard.string(forKey: Self.closedDayKey)
        // A timer started on a sample routine has nothing to finish once the samples are gone.
        if let run = routineRun, !notebook.routines.contains(where: { $0.id == run.routineID }) { cancelRoutineTimer() }
        requestSync()
    }

    func task(_ id: UUID) -> TaskItem? { notebook.tasks.first { $0.id == id } }

    func children(of id: UUID) -> [TaskItem] { notebook.children(of: id) }

    func hasChildren(_ id: UUID) -> Bool { notebook.hasChildren(id) }

    private var stepConversionPending = false

    private func scheduleStepConversion() {
        guard !stepConversionPending else { return }
        stepConversionPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stepConversionPending = false
            guard self.notebook.needsStepConversion, !self.loadFailed else { return }
            self.commit { $0.convertStepsToChildren() }
        }
    }

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

    /// Checks a task off or undoes it. A parent finishes with its last child; checking off a parent
    /// finishes the children still open. What was just finished stays in place, struck through.
    func complete(_ id: UUID) {
        let before = notebook
        guard commit({ $0.toggleTask(id) }) else { return }
        for task in notebook.tasks where task.isComplete && before.tasks.first(where: { $0.id == task.id })?.isComplete == false {
            recentlyDone.insert("task-\(task.id.uuidString)")
        }
    }

    /// A new piece of a task, at the end of its list. The first one takes over the task's day and time.
    @discardableResult
    func addChild(_ title: String, to parentID: UUID) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return commit { $0.addChild(TaskItem(title: text), to: parentID) }
    }

    /// Saves a task with its pieces as edited in one sheet. Each is merged with changes synced from other
    /// devices meanwhile, against how it looked when the sheet opened.
    func saveFamily(_ parent: TaskItem, original: TaskItem?, children: [TaskItem], originals: [UUID: TaskItem], removed: Set<UUID>) -> Bool {
        var merged: [TaskItem] = []
        for (index, child) in children.enumerated() {
            var edited = child
            edited.rank = index
            if let original = originals[child.id], let current = task(child.id) {
                do { edited = try SyncReplica.editedTask(original: original, edited: edited, current: current) }
                catch { self.error = error.localizedDescription; return false }
            }
            merged.append(edited)
        }
        var top = parent
        if let original {
            guard let current = task(parent.id) else {
                error = "このタスクは別の端末で削除されました。入力した内容をコピーしてから閉じてください。"
                return false
            }
            do { top = try SyncReplica.editedTask(original: original, edited: parent, current: current) }
            catch { self.error = error.localizedDescription; return false }
        }
        let hadChildren = notebook.hasChildren(parent.id)
        return commit { book in
            book.tasks.removeAll { removed.contains($0.id) && $0.parentID == top.id }
            if let i = book.tasks.firstIndex(where: { $0.id == top.id }) { book.tasks[i] = top } else { book.tasks.append(top) }
            var first = true
            for var child in merged {
                child.parentID = top.id
                child.project = top.project
                child.isEvent = false
                child.milestoneID = nil
                // The first piece of a task that had none takes over its day and time.
                if !hadChildren, first, child.plannedAt == nil, let day = top.plannedAt {
                    child.plannedAt = day
                    if child.scheduledTime.isEmpty { child.scheduledTime = top.scheduledTime }
                }
                first = false
                if let i = book.tasks.firstIndex(where: { $0.id == child.id }) { book.tasks[i] = child } else { book.tasks.append(child) }
            }
            if let i = book.tasks.firstIndex(where: { $0.id == top.id }) {
                if !merged.isEmpty {
                    // A parent keeps only its deadline and ★; days belong to its pieces.
                    book.tasks[i].plannedAt = nil
                    book.tasks[i].scheduledTime = ""
                } else if hadChildren {
                    book.tasks[i].completedAt = nil
                }
                // Its pieces follow it into another project.
                for k in book.tasks.indices where book.tasks[k].parentID == top.id { book.tasks[k].project = book.tasks[i].project }
            }
            book.settleParent(top.id)
        }
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
            recentlyDone.insert("routine-\(run.routineID.uuidString)-\(run.day)")
            routineRun = nil
            saveRoutineRun()
        }
    }

    func cancelRoutineTimer() {
        routineRun = nil
        saveRoutineRun()
    }

    // MARK: Ending the day

    /// 今日を終える: the いま screen shows the day as over, and what is left of today's tasks and routines
    /// stops announcing itself (events still do). Nothing in the data changes; leftovers are sorted the
    /// next morning as always. A routine being timed stops as with 中断.
    func closeDay(now: Date = Date()) {
        if routineRun != nil { cancelRoutineTimer() }
        closedDay = DayKey.of(now)
        if !isDemo { UserDefaults.standard.set(closedDay, forKey: Self.closedDayKey) }
    }

    /// 再開する: today is open again, with its reminders.
    func reopenDay() {
        closedDay = nil
        if !isDemo { UserDefaults.standard.removeObject(forKey: Self.closedDayKey) }
    }

#if DEBUG
    /// Screenshot runs: today shown as ended without saving it, so later launches start open.
    func closeDayForPreview() { closedDay = DayKey.of(Date()) }
#endif

    /// Where this time left off, shown when the routine is next started. An empty note keeps the last one.
    func saveRoutineNote(_ id: UUID, note: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commit { book in
            if let i = book.routines.firstIndex(where: { $0.id == id }) { book.routines[i].resumeNote = text }
        }
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
            for id in ids where book.tasks.first(where: { $0.id == id })?.isComplete == false { book.toggleTask(id) }
        }
        if saved { offerUndo("\(ids.count)件を完了にしました") }
    }

    func deleteAll(_ ids: Set<UUID>) {
        let saved = commit { book in
            for id in ids { book.removeTask(id) }
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

    /// Deletes a task; a parent goes with its pieces.
    func delete(_ id: UUID) {
        let title = task(id)?.title ?? ""
        let pieces = notebook.children(of: id).count
        if commit({ $0.removeTask(id) }) {
            offerUndo(pieces > 0 ? "「\(title)」と子タスク\(pieces)件を削除しました" : "「\(title)」を削除しました")
        }
    }

    func deleteIdea(_ id: UUID) {
        if commit({ $0.ideas.removeAll { $0.id == id } }) { offerUndo("付箋をはがしました") }
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
                if book.projects[i].overview.isEmpty { book.projects[i].overview = project.overview }
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
        ], createdAt: earlier, overview: "これはサンプルです。転職の条件に英語があるので、本番までに形式に慣れる。単語は毎日少しずつ、長文は時間を計って解く。")
        // Tasks in pieces: the pieces carry the days; the whole keeps its deadline and ★.
        let papers = TaskItem(title: "提出書類を送る", deadline: now, isMust: true, effort: .light, memo: "これはサンプルです。",
                              createdAt: earlier)
        let proposal = TaskItem(title: "提案書をつくる", deadline: day(2), effort: .heavy, project: "仕事", createdAt: earlier)
        let rereading = TaskItem(title: "長文の解き直し", effort: .medium, project: "英語の勉強", createdAt: earlier, milestoneID: part7.id)
        func piece(_ title: String, of parent: TaskItem, _ rank: Int, on date: Date? = nil, at time: String = "", done: Date? = nil) -> TaskItem {
            TaskItem(title: title, plannedAt: date, scheduledTime: time, project: parent.project,
                     createdAt: earlier.addingTimeInterval(Double(rank)), completedAt: done, parentID: parent.id, rank: rank)
        }
        return Notebook(tasks: [
            TaskItem(title: "予想問題 第4回を解く", plannedAt: now, scheduledTime: "20:30-21:30", effort: .heavy,
                     project: "英語の勉強", milestoneID: test.id),
            TaskItem(title: "長文 時間を計って10問", plannedAt: day(-1), effort: .medium, project: "英語の勉強",
                     completedAt: day(-1), milestoneID: part7.id),
            rereading,
            piece("第1段落を解き直す", of: rereading, 0, on: day(-2), done: day(-2)),
            piece("第2段落を解き直す", of: rereading, 1, on: day(-1), done: day(-1)),
            piece("第3段落を解き直す", of: rereading, 2, on: day(1)),
            piece("第4段落を解き直す", of: rereading, 3),
            TaskItem(title: "本番", plannedAt: day(41), project: "英語の勉強", isEvent: true),
            papers,
            piece("宛先を確認する", of: papers, 0, on: now),
            piece("メールに添付して送る", of: papers, 1, on: now),
            TaskItem(title: "予約の電話をする", plannedAt: now, scheduledTime: "14:00-14:15", effort: .light,
                     handoff: "受付時間を調べておいて"),
            TaskItem(title: "読みかけの本を読む", effort: .light, memo: "42ページの途中まで"),
            proposal,
            piece("構成を決める", of: proposal, 0, on: day(-1), done: day(-1)),
            piece("見出しを3つ書く", of: proposal, 1, on: now, at: "15:00-16:00"),
            piece("本文を書く", of: proposal, 2, on: day(1), at: "10:00-11:30"),
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
            Routine(title: "単語を回す", project: "英語の勉強", weekdays: [2, 3, 4, 5, 6], time: "19:00-19:30", createdAt: earlier,
                    resumeNote: "Section 3 の 120番まで"),
            Routine(title: "部屋をリセットする", project: "部屋のリセット", time: "21:00-21:15", createdAt: earlier),
            Routine(title: "仕事", weekdays: [2, 3, 4, 5, 6], time: "9:00-18:00", notify: false, isBlock: true, createdAt: earlier),
            Routine(title: "睡眠", time: "0:00-7:00", notify: false, isBlock: true, createdAt: earlier)
        ], projects: [english])
    }
}
