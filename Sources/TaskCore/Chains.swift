import Foundation

/// つながり: tasks one after another, each knowing the one before it (`follows`). A later one waits for the
/// one before it to be done before it is suggested. A つながり can be gathered under a named task (親と子) and
/// scattered back, or given a project name and have it taken off; each step can be undone the same way, and
/// no task is lost on the way.
///
/// Only top-level tasks (not events, not pieces) are linked: the pieces of a task already have an order.
/// Edits on two devices at once can leave two tasks after the same one, or (rarely) a loop; reading a
/// つながり tolerates both, keeping each task once.
public extension Notebook {
    /// Whether a task can take part in a つながり.
    func canChain(_ task: TaskItem) -> Bool { task.parentID == nil && !task.isEvent }

    /// The task right before this one, when it is still there.
    func previous(of task: TaskItem) -> TaskItem? {
        guard let id = task.follows else { return nil }
        return tasks.first { $0.id == id }
    }

    /// The tasks right after this one: one, unless edits on two devices crossed.
    func following(_ id: UUID) -> [TaskItem] {
        tasks.filter { $0.follows == id }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    /// The next task not done yet after this one, for "次：…".
    func nextInChain(after id: UUID) -> TaskItem? {
        var seen: Set<UUID> = [id]
        var current = following(id).first
        while let task = current, seen.insert(task.id).inserted {
            if !task.isComplete { return task }
            current = following(task.id).first
        }
        return nil
    }

    /// Waits for the task before it, still open.
    func isWaiting(_ task: TaskItem) -> Bool { previous(of: task).map { !$0.isComplete } ?? false }

    /// The whole つながり a task is in, first to last; just the task when it is in none.
    func chain(containing id: UUID) -> [TaskItem] {
        guard tasks.contains(where: { $0.id == id }) else { return [] }
        var head = id
        var back: Set<UUID> = [id]
        while let task = tasks.first(where: { $0.id == head }), let before = previous(of: task), back.insert(before.id).inserted {
            head = before.id
        }
        var result: [TaskItem] = []
        var seen: Set<UUID> = []
        func visit(_ id: UUID) {
            guard seen.insert(id).inserted, let task = tasks.first(where: { $0.id == id }) else { return }
            result.append(task)
            for next in following(id) { visit(next.id) }
        }
        visit(head)
        return result
    }

    /// Adds a task right after another. What came after that one now comes after the new one.
    @discardableResult
    mutating func addTask(_ task: TaskItem, after id: UUID) -> Bool {
        guard let anchor = tasks.first(where: { $0.id == id }), canChain(anchor) else { return false }
        var added = task
        added.follows = id
        added.parentID = nil
        if added.project.isEmpty { added.project = anchor.project }
        for i in tasks.indices where tasks[i].follows == id { tasks[i].follows = added.id }
        tasks.append(added)
        return true
    }

    /// Adds a task right before another: what has to happen first (逆算).
    @discardableResult
    mutating func addTask(_ task: TaskItem, before id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), canChain(tasks[i]) else { return false }
        var added = task
        added.follows = tasks[i].follows
        added.parentID = nil
        if added.project.isEmpty { added.project = tasks[i].project }
        tasks[i].follows = added.id
        tasks.append(added)
        return true
    }

    /// Takes one task out of its つながり; the ones on either side join up.
    mutating func unlink(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[i].follows
        for k in tasks.indices where tasks[k].follows == id { tasks[k].follows = before }
        tasks[i].follows = nil
    }

    /// Undoes a whole つながり: its tasks stay, each on its own.
    mutating func dissolveChain(containing id: UUID) {
        let members = Set(chain(containing: id).map(\.id))
        for i in tasks.indices where members.contains(tasks[i].id) { tasks[i].follows = nil }
    }

    /// ひとまとめにする: the つながり becomes the pieces of a new task with this name, in order. The new task takes
    /// the latest deadline and any ★ among them, and comes where the first one was. Nil when a task in it
    /// already has pieces of its own (one level only), or when there is nothing to gather.
    @discardableResult
    mutating func gatherChain(containing id: UUID, title: String, at now: Date = Date()) -> UUID? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = chain(containing: id)
        guard !name.isEmpty, members.count > 1, members.allSatisfy(canChain),
              !members.contains(where: { hasChildren($0.id) }), let first = members.first else { return nil }
        let ids = Set(members.map(\.id))
        let parent = TaskItem(title: name, deadline: members.compactMap(\.deadline).max(),
                              isMust: members.contains(where: \.isMust), project: first.project,
                              createdAt: first.createdAt, follows: first.follows.flatMap { ids.contains($0) ? nil : $0 })
        // What came after the つながり now comes after the new task.
        for i in tasks.indices where !ids.contains(tasks[i].id) {
            if let before = tasks[i].follows, ids.contains(before) { tasks[i].follows = parent.id }
        }
        for (rank, member) in members.enumerated() {
            guard let i = tasks.firstIndex(where: { $0.id == member.id }) else { continue }
            tasks[i].parentID = parent.id
            tasks[i].rank = rank
            tasks[i].follows = nil
            tasks[i].project = parent.project
            tasks[i].milestoneID = nil
        }
        tasks.append(parent)
        settleParent(parent.id, at: now)
        return parent.id
    }

    /// ばらす: a task's pieces become a つながり in their order, and the task itself goes. Its deadline and ★
    /// pass to its last piece when that has none, so nothing it said is lost. Nil when it has no pieces.
    @discardableResult
    mutating func scatterPieces(of id: UUID) -> UUID? {
        guard let p = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let parent = tasks[p]
        let pieces = children(of: id)
        guard let last = pieces.last else { return nil }
        var before = parent.follows
        for piece in pieces {
            guard let i = tasks.firstIndex(where: { $0.id == piece.id }) else { continue }
            tasks[i].parentID = nil
            tasks[i].rank = 0
            tasks[i].follows = before
            tasks[i].project = parent.project
            if tasks[i].id == last.id {
                if tasks[i].deadline == nil { tasks[i].deadline = parent.deadline }
                if parent.isMust { tasks[i].isMust = true }
                if tasks[i].milestoneID == nil { tasks[i].milestoneID = parent.milestoneID }
            }
            before = piece.id
        }
        // What came after the task now comes after its last piece.
        for i in tasks.indices where tasks[i].follows == id { tasks[i].follows = last.id }
        if activeSession?.taskID == id { activeSession = nil }
        tasks.removeAll { $0.id == id }
        return pieces.first?.id
    }

    /// プロジェクトにする: every task of the つながり (and their pieces) takes the project's name, and the project is
    /// made when there is none by that name yet. Taking the project off again (`ProjectBook.remove`) leaves the
    /// つながり as it was.
    mutating func makeProject(ofChainContaining id: UUID, named name: String, at now: Date = Date()) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let members = Set(chain(containing: id).map(\.id))
        guard !members.isEmpty else { return }
        for i in tasks.indices where members.contains(tasks[i].id) || tasks[i].parentID.map(members.contains) == true {
            if tasks[i].project != title { tasks[i].milestoneID = nil }
            tasks[i].project = title
        }
        if !projects.contains(where: { ProjectBook.key($0.name) == ProjectBook.key(title) }) {
            projects.append(Project(name: title, createdAt: now))
        }
    }
}
