import Foundation

/// A checkpoint on the way to a project's goal, written by the person. How it is counted is their choice.
public struct Milestone: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Marked once it is done.
        case check
        /// Done a number of times: ＋1 by hand, plus the linked tasks and routines that get done.
        case count
        /// A value to reach, such as a score.
        case number
        /// The share of linked tasks that are done.
        case tasks
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .check: return "チェック"
            case .count: return "回数"
            case .number: return "数値"
            case .tasks: return "タスクで数える"
            }
        }
        public var detail: String {
            switch self {
            case .check: return "できたら印をつける"
            case .count: return "○回やる・＋1で数える"
            case .number: return "点数・kg・ページなど"
            case .tasks: return "つないだタスクの完了数"
            }
        }
    }

    public var id: UUID
    public var title: String
    public var kind: Kind
    /// For count and number: what to reach.
    public var target: Double
    /// For count: the ＋1s given by hand. For number: the latest value.
    public var current: Double
    public var unit: String
    /// For check.
    public var isDone: Bool
    public var dueDate: Date?
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, kind: Kind = .check, target: Double = 1, current: Double = 0,
                unit: String = "", isDone: Bool = false, dueDate: Date? = nil, createdAt: Date = Date()) {
        self.id = id; self.title = title; self.kind = kind; self.target = target; self.current = current
        self.unit = unit; self.isDone = isDone; self.dueDate = dueDate; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, title, kind, target, current, unit, isDone, dueDate, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        // A kind added by a later version reads as a plain checkpoint rather than failing the whole notebook.
        kind = (try c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .check
        target = try c.decodeIfPresent(Double.self, forKey: .target) ?? 1
        current = try c.decodeIfPresent(Double.self, forKey: .current) ?? 0
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// A big frame around tasks, routines, events and cards, with a goal and checkpoints on the way.
/// Things belong to a project by name (their `project` text), as they always have, so the Claude
/// bridge and older data keep working; this record adds the goal and the checkpoints.
public struct Project: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// The point of arrival, e.g. "本番で500点".
    public var goal: String
    public var deadline: Date?
    /// In the order of the way.
    public var milestones: [Milestone]
    /// The idea it grew from, as it was written.
    public var origin: String
    public var createdAt: Date
    /// What the project is for and how it goes, in the person's words; shown at the top of its page.
    public var overview: String

    public init(id: UUID = UUID(), name: String, goal: String = "", deadline: Date? = nil, milestones: [Milestone] = [],
                origin: String = "", createdAt: Date = Date(), overview: String = "") {
        self.id = id; self.name = name; self.goal = goal; self.deadline = deadline; self.milestones = milestones
        self.origin = origin; self.createdAt = createdAt; self.overview = overview
    }

    enum CodingKeys: String, CodingKey { case id, name, goal, deadline, milestones, origin, createdAt, overview }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
    }
}

/// Everything about projects that is worked out from the notebook rather than stored.
public enum ProjectBook {
    /// Names match ignoring case and spaces, like cards always have.
    public static func key(_ name: String) -> String { BoardLink.normalized(name) }

    public struct Entry: Identifiable, Equatable {
        public var id: String { key }
        public var key: String
        public var name: String
        /// Nil for a project that so far is only a name on some tasks, routines or cards.
        public var project: Project?
    }

    /// Saved projects in their order, then names used only by cards, open tasks or running routines, most used first.
    public static func entries(_ book: Notebook) -> [Entry] {
        var result: [Entry] = []
        var seen = Set<String>()
        for project in book.projects {
            let k = key(project.name)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            result.append(Entry(key: k, name: project.name.trimmingCharacters(in: .whitespacesAndNewlines), project: project))
        }
        var loose: [String: (name: String, count: Int)] = [:]
        let names = book.boardCards.map(\.project) + book.tasks.filter { !$0.isComplete }.map(\.project)
            + book.routines.filter { !$0.isPaused }.map(\.project)
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(name)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            loose[k, default: (name, 0)].count += 1
        }
        result += loose.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.name < $1.value.name }
            .map { Entry(key: $0.key, name: $0.value.name, project: nil) }
        return result
    }

    public static func entry(_ key: String, in book: Notebook) -> Entry? { entries(book).first { $0.key == key } }

    public static func project(named name: String, in book: Notebook) -> Project? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return book.projects.first { key($0.name) == k }
    }

    /// The project's tasks, a parent standing for its children (it counts once, when they are all done).
    public static func tasks(_ key: String, in book: Notebook) -> [TaskItem] {
        book.tasks.filter { $0.parentID == nil && self.key($0.project) == key }
    }
    public static func routines(_ key: String, in book: Notebook) -> [Routine] { book.routines.filter { self.key($0.project) == key } }
    public static func cards(_ key: String, in book: Notebook) -> [BoardCard] { book.boardCards.filter { self.key($0.project) == key } }

    /// How far a checkpoint has come, as a count for count, the value for number and the done tasks for tasks.
    public static func value(of milestone: Milestone, in book: Notebook, calendar: Calendar = .current) -> Double {
        switch milestone.kind {
        case .check: return milestone.isDone ? 1 : 0
        case .number: return milestone.current
        case .tasks: return Double(book.tasks.filter { $0.milestoneID == milestone.id && $0.isComplete }.count)
        case .count:
            let tasks = book.tasks.filter { $0.milestoneID == milestone.id && $0.isComplete }.count
            // A routine counts the days done since the checkpoint was set, not its whole history.
            let since = DayKey.of(milestone.createdAt, calendar: calendar)
            let days = book.routines.filter { $0.milestoneID == milestone.id }
                .reduce(0) { $0 + $1.doneDays.filter { $0 >= since }.count }
            return milestone.current + Double(tasks + days)
        }
    }

    /// What the value is measured against: the target, or the number of linked tasks.
    public static func target(of milestone: Milestone, in book: Notebook) -> Double {
        switch milestone.kind {
        case .check: return 1
        case .count, .number: return max(milestone.target, 0)
        case .tasks: return Double(book.tasks.filter { $0.milestoneID == milestone.id }.count)
        }
    }

    /// 0…1.
    public static func progress(of milestone: Milestone, in book: Notebook, calendar: Calendar = .current) -> Double {
        let goal = target(of: milestone, in: book)
        guard goal > 0 else { return 0 }
        return min(1, max(0, value(of: milestone, in: book, calendar: calendar) / goal))
    }

    public static func isReached(_ milestone: Milestone, in book: Notebook) -> Bool { progress(of: milestone, in: book) >= 1 }

    /// The average of the checkpoints; with none, the share of the project's tasks that are done.
    public static func progress(of key: String, in book: Notebook) -> Double? {
        if let project = book.projects.first(where: { self.key($0.name) == key }), !project.milestones.isEmpty {
            return project.milestones.map { progress(of: $0, in: book) }.reduce(0, +) / Double(project.milestones.count)
        }
        let tasks = tasks(key, in: book).filter { !$0.isEvent }
        guard !tasks.isEmpty else { return nil }
        return Double(tasks.filter(\.isComplete).count) / Double(tasks.count)
    }

    /// The first checkpoint on the way that is not reached yet.
    public static func next(of project: Project, in book: Notebook) -> Milestone? {
        project.milestones.first { !isReached($0, in: book) }
    }

    // MARK: Changes

    /// Renames a project everywhere: its record, and every task, routine and card that uses the name.
    public static func rename(_ key: String, to newName: String, in book: inout Notebook) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for i in book.projects.indices where self.key(book.projects[i].name) == key { book.projects[i].name = name }
        for i in book.tasks.indices where self.key(book.tasks[i].project) == key { book.tasks[i].project = name }
        for i in book.routines.indices where self.key(book.routines[i].project) == key { book.routines[i].project = name }
        for i in book.boardCards.indices where self.key(book.boardCards[i].project) == key { book.boardCards[i].project = name }
    }

    /// Removes a project: tasks, routines and cards stay, without the project, and lose their checkpoints.
    public static func remove(_ key: String, from book: inout Notebook) {
        let milestones = Set(book.projects.filter { self.key($0.name) == key }.flatMap { $0.milestones.map(\.id) })
        book.projects.removeAll { self.key($0.name) == key }
        for i in book.tasks.indices {
            if self.key(book.tasks[i].project) == key { book.tasks[i].project = "" }
            if let m = book.tasks[i].milestoneID, milestones.contains(m) { book.tasks[i].milestoneID = nil }
        }
        for i in book.routines.indices {
            if self.key(book.routines[i].project) == key { book.routines[i].project = "" }
            if let m = book.routines[i].milestoneID, milestones.contains(m) { book.routines[i].milestoneID = nil }
        }
        for i in book.boardCards.indices where self.key(book.boardCards[i].project) == key { book.boardCards[i].project = "" }
    }

    /// Cards used to belong to tasks by matching names ("TOEIC" and "TOEIC対策"). Each such card now joins
    /// the project its tasks and routines name most, and those that spelled it another way take that name,
    /// so one project holds them all. Cards nothing points at stay on the board on their own.
    public static func moveCardsIntoProjects(_ book: inout Notebook) {
        let cards = book.boardCards
        for (index, card) in cards.enumerated() where key(card.project).isEmpty {
            let taskIndices = book.tasks.indices.filter { BoardLink.card(forProject: book.tasks[$0].project, in: cards)?.id == card.id }
            let routineIndices = book.routines.indices.filter { BoardLink.card(forProject: book.routines[$0].project, in: cards)?.id == card.id }
            var counts: [String: (name: String, count: Int)] = [:]
            for name in taskIndices.map({ book.tasks[$0].project }) + routineIndices.map({ book.routines[$0].project }) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                counts[key(trimmed), default: (trimmed, 0)].count += 1
            }
            guard let chosen = counts.values.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }).first else { continue }
            let chosenKey = key(chosen.name)
            book.boardCards[index].project = chosen.name
            for i in taskIndices where key(book.tasks[i].project) != chosenKey { book.tasks[i].project = chosen.name }
            for i in routineIndices where key(book.routines[i].project) != chosenKey { book.routines[i].project = chosen.name }
        }
    }
}
