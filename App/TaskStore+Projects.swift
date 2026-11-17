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

/// The store's actions on つながり: adding before and after, and turning one into pieces or a project and back.
extension TaskStore {
    func chain(containing id: UUID) -> [TaskItem] { notebook.chain(containing: id) }

    /// A new task right after this one (次にやること), or right before it (前にやること).
    @discardableResult
    func addLinked(_ title: String, to id: UUID, before: Bool = false) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard task(id) != nil else { error = "このタスクは別の端末で削除されました。"; return false }
        let added = TaskItem(title: text)
        return commit { book in
            if before { book.addTask(added, before: id) } else { book.addTask(added, after: id) }
        }
    }

    /// Takes a task out of its つながり; the tasks on either side join up.
    func unlink(_ id: UUID) {
        if commit({ $0.unlink(id) }) { offerUndo("つながりから外しました") }
    }

    func dissolveChain(containing id: UUID) {
        if commit({ $0.dissolveChain(containing: id) }) { offerUndo("つながりをほどきました") }
    }

    /// ひとまとめにする. Returns the new task, to open it.
    @discardableResult
    func gatherChain(containing id: UUID, title: String) -> TaskItem? {
        var made: UUID?
        guard commit({ made = $0.gatherChain(containing: id, title: title) }), let made else {
            if error == nil { error = "子タスクに分かれたタスクを含むつながりは、ひとまとめにできません。" }
            return nil
        }
        offerUndo("「\(title)」にまとめました")
        return task(made)
    }

    /// ばらす: the pieces become a つながり. Returns the first of them. The task's name is kept on this device,
    /// so ひとまとめにする on the same tasks offers it again.
    @discardableResult
    func scatterPieces(of id: UUID) -> TaskItem? {
        let title = task(id)?.title ?? ""
        let pieces = children(of: id).map(\.id)
        var first: UUID?
        guard commit({ first = $0.scatterPieces(of: id) }), let first else { return nil }
        if !isDemo { ScatteredNames.remember(title, for: pieces) }
        offerUndo("「\(title)」をつながりにしました")
        return task(first)
    }

    /// The name to offer when gathering this つながり: what its tasks were pieces of, when they were scattered here.
    func gatherName(containing id: UUID) -> String {
        isDemo ? "" : ScatteredNames.name(for: chain(containing: id).map(\.id)) ?? ""
    }

    func makeProject(ofChainContaining id: UUID, named name: String) {
        if commit({ $0.makeProject(ofChainContaining: id, named: name) }) { offerUndo("プロジェクト「\(name)」にしました") }
    }
}

/// The names of tasks scattered into つながり on this device, newest first, so gathering the same tasks again
/// needs no typing. Only a convenience: kept in this device's settings, not synced, and the last few only.
enum ScatteredNames {
    private static let key = "horme.scatteredNames"
    private static let limit = 20
    private struct Entry: Codable { var title: String; var ids: [UUID] }

    static func remember(_ title: String, for ids: [UUID], defaults: UserDefaults = .standard) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !ids.isEmpty else { return }
        let entries = [Entry(title: name, ids: ids)] + load(defaults).filter { Set($0.ids).isDisjoint(with: ids) }
        if let data = try? JSONEncoder().encode(Array(entries.prefix(limit))) { defaults.set(data, forKey: key) }
    }

    /// The newest name whose tasks include any of these.
    static func name(for ids: [UUID], defaults: UserDefaults = .standard) -> String? {
        let wanted = Set(ids)
        return load(defaults).first { !wanted.isDisjoint(with: $0.ids) }?.title
    }

    private static func load(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
