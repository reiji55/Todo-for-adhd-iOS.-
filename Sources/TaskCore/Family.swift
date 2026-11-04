import Foundation

/// Parent and child tasks. A task with children is a parent: it keeps only its deadline and ★, and is
/// done exactly when all its children are. Children carry the days and times, so a piece that does not
/// get done today moves on its own. One level only.
public extension Notebook {
    /// Whether data from before parent and child tasks still needs converting.
    var needsStepConversion: Bool {
        activeSession != nil || tasks.contains { !$0.steps.isEmpty || !$0.resumeNote.isEmpty }
    }

    func children(of id: UUID) -> [TaskItem] {
        tasks.filter { $0.parentID == id }.sorted(by: Self.childOrder)
    }

    func hasChildren(_ id: UUID) -> Bool { tasks.contains { $0.parentID == id } }

    /// IDs of every task that has children.
    var parentIDs: Set<UUID> { Set(tasks.compactMap(\.parentID)) }

    /// The next open child, in order.
    func nextChild(of id: UUID) -> TaskItem? { children(of: id).first { !$0.isComplete } }

    static func childOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// A parent is done exactly when every child is. Called after any change to its children.
    mutating func settleParent(_ id: UUID, at now: Date = Date()) {
        guard let p = tasks.firstIndex(where: { $0.id == id }) else { return }
        let kids = tasks.filter { $0.parentID == id }
        guard !kids.isEmpty else { return }
        if kids.allSatisfy(\.isComplete) {
            if tasks[p].completedAt == nil { tasks[p].completedAt = now }
        } else {
            tasks[p].completedAt = nil
        }
    }

    /// Checks a task off, or undoes it. For a parent, checking off finishes every child still open;
    /// undoing reopens the children it finished that way (or, if the last child finished it, that child).
    mutating func toggleTask(_ id: UUID, at now: Date = Date()) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let kids = tasks.indices.filter { tasks[$0].parentID == id }
        if !kids.isEmpty {
            if let finished = tasks[i].completedAt {
                let together = kids.filter { tasks[$0].completedAt == finished }
                let reopen = together.isEmpty
                    ? kids.max { (tasks[$0].completedAt ?? .distantPast) < (tasks[$1].completedAt ?? .distantPast) }.map { [$0] } ?? []
                    : together
                for k in reopen { tasks[k].completedAt = nil }
                tasks[i].completedAt = nil
            } else {
                for k in kids where tasks[k].completedAt == nil { tasks[k].completedAt = now }
                tasks[i].completedAt = now
            }
        } else {
            tasks[i].completedAt = tasks[i].isComplete ? nil : now
            if let parent = tasks[i].parentID { settleParent(parent, at: now) }
        }
        if activeSession?.taskID == id { activeSession = nil }
    }

    /// Adds a piece to a task. The first piece takes over the task's day and time (the task keeps only
    /// its deadline and ★ from then on), so nothing planned is lost.
    mutating func addChild(_ child: TaskItem, to parentID: UUID, at now: Date = Date()) {
        guard let p = tasks.firstIndex(where: { $0.id == parentID }), tasks[p].parentID == nil, !tasks[p].isEvent else { return }
        var piece = child
        let siblings = tasks.filter { $0.parentID == parentID }
        if siblings.isEmpty {
            if piece.plannedAt == nil, let day = tasks[p].plannedAt {
                piece.plannedAt = day
                if piece.scheduledTime.isEmpty { piece.scheduledTime = tasks[p].scheduledTime }
            }
            tasks[p].plannedAt = nil
            tasks[p].scheduledTime = ""
        }
        piece.parentID = parentID
        piece.project = tasks[p].project
        piece.isEvent = false
        piece.milestoneID = nil
        piece.rank = (siblings.map(\.rank).max() ?? -1) + 1
        tasks.append(piece)
        settleParent(parentID, at: now)
    }

    /// Removes a task; a parent goes with its children. A parent left with no children is an ordinary
    /// task again, with no day until one is chosen.
    mutating func removeTask(_ id: UUID, at now: Date = Date()) {
        let parent = tasks.first { $0.id == id }?.parentID
        tasks.removeAll { $0.id == id || $0.parentID == id }
        if let active = activeSession, !tasks.contains(where: { $0.id == active.taskID }) { activeSession = nil }
        if let parent { settleParent(parent, at: now) }
    }

    /// Earlier versions kept a task's pieces as steps inside it, and a "where I left off" note for the
    /// focus screen. Steps become children (each keeping its step's ID, so two devices converting the
    /// same task make the same children), the task's day and time pass to its first open piece, and the
    /// note joins the memo. Tasks no longer run a timer. Returns whether anything changed.
    @discardableResult
    mutating func convertStepsToChildren(at now: Date = Date()) -> Bool {
        var changed = false
        if activeSession != nil { activeSession = nil; changed = true }
        for p in tasks.indices {
            let note = tasks[p].resumeNote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                tasks[p].memo = tasks[p].memo.isEmpty ? "続き：\(note)" : "\(tasks[p].memo)\n続き：\(note)"
                tasks[p].resumeNote = ""
                changed = true
            } else if !tasks[p].resumeNote.isEmpty {
                tasks[p].resumeNote = ""; changed = true
            }
            guard !tasks[p].steps.isEmpty else { continue }
            changed = true
            let parent = tasks[p]
            tasks[p].steps = []
            // A child cannot itself have children: its steps become its siblings.
            let parentID = parent.parentID ?? parent.id
            let existing = Set(tasks.map(\.id))
            let base = (tasks.filter { $0.parentID == parentID }.map(\.rank).max() ?? -1) + 1
            let firstOpen = parent.steps.firstIndex { !$0.isDone }
            var pieces: [TaskItem] = []
            for (index, step) in parent.steps.enumerated() where !existing.contains(step.id) {
                var piece = TaskItem(id: step.id, title: step.title, project: parent.project,
                                     createdAt: parent.createdAt.addingTimeInterval(Double(index + 1) / 1000),
                                     completedAt: step.isDone || parent.isComplete ? (parent.completedAt ?? parent.createdAt) : nil,
                                     parentID: parentID, rank: base + index)
                if index == firstOpen, parent.parentID == nil, !parent.isComplete {
                    piece.plannedAt = parent.plannedAt
                    piece.scheduledTime = parent.scheduledTime
                }
                pieces.append(piece)
            }
            tasks.append(contentsOf: pieces)
            if parent.parentID == nil {
                tasks[p].plannedAt = nil
                tasks[p].scheduledTime = ""
            }
            settleParent(parentID, at: parent.completedAt ?? now)
        }
        // A finished task's open steps were left behind when it was checked off: they are done too.
        for p in tasks.indices where tasks[p].parentID == nil && tasks[p].isComplete {
            for k in tasks.indices where tasks[k].parentID == tasks[p].id && !tasks[k].isComplete {
                tasks[k].completedAt = tasks[p].completedAt
                changed = true
            }
        }
        return changed
    }
}
