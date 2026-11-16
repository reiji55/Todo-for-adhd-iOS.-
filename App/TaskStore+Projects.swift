import SwiftUI

/// The store's actions on the board: cards, projects and their checkpoints.
extension TaskStore {
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

    func deleteCard(_ id: UUID) {
        let title = card(id)?.title ?? ""
        if commit({ $0.boardCards.removeAll { $0.id == id } }) { offerUndo("カード「\(title)」を削除しました") }
    }

    func moveCards(from source: IndexSet, to destination: Int) {
        commit { $0.boardCards.move(fromOffsets: source, toOffset: destination) }
    }
}
