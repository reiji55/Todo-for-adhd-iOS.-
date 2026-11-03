import Foundation

public enum Effort: String, Codable, CaseIterable, Identifiable {
    case light, medium, heavy
    public var id: String { rawValue }
    public var label: String {
        switch self { case .light: return "軽め"; case .medium: return "ふつう"; case .heavy: return "じっくり" }
    }
    public var rank: Int {
        switch self { case .light: return 0; case .medium: return 1; case .heavy: return 2 }
    }
}

public enum Energy: String, CaseIterable, Identifiable {
    case any, low, normal, high
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .any: return "指定なし"
        case .low: return "軽めから"
        case .normal: return "いつも通り"
        case .high: return "じっくり"
        }
    }
    public var preferred: Effort? {
        switch self { case .any: return nil; case .low: return .light; case .normal: return .medium; case .high: return .heavy }
    }
}

public struct Step: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var isDone: Bool
    public init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id; self.title = title; self.isDone = isDone
    }
}

public struct TaskItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    /// Planned date and deadline deliberately remain separate.
    public var plannedAt: Date?
    public var scheduledTime: String
    public var deadline: Date?
    /// Explicitly chosen by the person; it is never inferred from mood or score.
    public var isMust: Bool
    public var effort: Effort
    public var project: String
    public var memo: String
    public var handoff: String
    public var resumeNote: String
    public var steps: [Step]
    public var createdAt: Date
    public var lastStartedAt: Date?
    public var completedAt: Date?
    /// Only affects suggestions. Never hides a task from the obligation or all-task lists.
    public var suggestionDeferredUntil: Date?
    /// Announce the start time with a banner. On unless the person turns it off for this task.
    public var notify: Bool
    /// Something happening that day (meeting a friend, going shopping), not a to-do: no checkbox, never
    /// suggested, never a leftover. Always has a date.
    public var isEvent: Bool
    /// The checkpoint of its project this task counts toward.
    public var milestoneID: UUID?

    public init(id: UUID = UUID(), title: String, plannedAt: Date? = nil,
                scheduledTime: String = "", deadline: Date? = nil, isMust: Bool = false,
                effort: Effort = .medium, project: String = "", memo: String = "",
                handoff: String = "", resumeNote: String = "", steps: [Step] = [],
                createdAt: Date = Date(), lastStartedAt: Date? = nil, completedAt: Date? = nil,
                suggestionDeferredUntil: Date? = nil, notify: Bool = true, isEvent: Bool = false, milestoneID: UUID? = nil) {
        self.id = id; self.title = title; self.plannedAt = plannedAt
        self.scheduledTime = scheduledTime; self.deadline = deadline; self.isMust = isMust
        self.effort = effort; self.project = project; self.memo = memo; self.handoff = handoff
        self.resumeNote = resumeNote; self.steps = steps; self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt; self.completedAt = completedAt
        self.suggestionDeferredUntil = suggestionDeferredUntil; self.notify = notify; self.isEvent = isEvent
        self.milestoneID = milestoneID
    }
    public var isComplete: Bool { completedAt != nil }
    public var nextStep: Step? { steps.first { !$0.isDone } }
    /// A task with no steps is still immediately actionable.
    public var actionTitle: String { nextStep?.title ?? title }
}

/// A line added to an idea later, as it takes shape.
public struct IdeaNote: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.createdAt = createdAt
    }
}

public struct Idea: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    /// Lines added later (メモ); having any is what lets an idea become fully warm.
    public var notes: [IdeaNote]
    /// When it was last opened or changed; nil means only when it was written.
    public var touchedAt: Date?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), notes: [IdeaNote] = [], touchedAt: Date? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.notes = notes; self.touchedAt = touchedAt
    }

    enum CodingKeys: String, CodingKey { case id, text, createdAt, notes, touchedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        notes = try c.decodeIfPresent([IdeaNote].self, forKey: .notes) ?? []
        touchedAt = try c.decodeIfPresent(Date.self, forKey: .touchedAt)
    }

    /// The last time it was written, opened or added to.
    public var lastTouched: Date {
        max(touchedAt ?? createdAt, notes.map(\.createdAt).max() ?? createdAt, createdAt)
    }

    /// 3 hot … 0 cold. Touching an idea warms it; it cools a step at 3 days, a week and two weeks
    /// untouched. Only an idea that has grown at least one note can be fully hot.
    public func warmth(now: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastTouched),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let level: Int
        switch days {
        case ..<3: level = 3
        case ..<7: level = 2
        case ..<14: level = 1
        default: level = 0
        }
        return notes.isEmpty ? min(level, 2) : level
    }
}

/// A long-form "how to do it" note. Tasks say what to do now; cards say how, and outlive any one task.
public struct BoardCard: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    /// Why this is worth doing.
    public var purpose: String
    /// What "done" looks like.
    public var goal: String
    /// Steps, methods and notes. Can be long.
    public var detail: String
    public var createdAt: Date
    /// The project it belongs to, by name; "" for a card that stands on its own on the board.
    public var project: String
    public init(id: UUID = UUID(), title: String, purpose: String = "", goal: String = "",
                detail: String = "", createdAt: Date = Date(), project: String = "") {
        self.id = id; self.title = title; self.purpose = purpose; self.goal = goal
        self.detail = detail; self.createdAt = createdAt; self.project = project
    }
    public var isBlank: Bool {
        [purpose, goal, detail].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    /// Plain text for the share sheet, e.g. to hand a method to an AI.
    public var shareText: String {
        var parts = [title]
        if !purpose.isEmpty { parts.append("目的：\(purpose)") }
        if !goal.isEmpty { parts.append("ゴール：\(goal)") }
        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: "\n\n")
    }
}

public struct Session: Codable, Equatable {
    public var taskID: UUID
    public var startedAt: Date
    /// Persist the specific step being worked on, even if the task is edited elsewhere.
    public var stepID: UUID?
    public init(taskID: UUID, startedAt: Date, stepID: UUID?) {
        self.taskID = taskID; self.startedAt = startedAt; self.stepID = stepID
    }
}

public struct Notebook: Codable, Equatable {
    public var version: Int = 1
    public var tasks: [TaskItem]
    public var ideas: [Idea]
    /// Kept in the person's chosen order.
    public var boardCards: [BoardCard]
    public var routines: [Routine]
    public var activeSession: Session?
    public var projects: [Project]
    public init(tasks: [TaskItem] = [], ideas: [Idea] = [], boardCards: [BoardCard] = [], routines: [Routine] = [],
                activeSession: Session? = nil, projects: [Project] = []) {
        self.tasks = tasks; self.ideas = ideas; self.boardCards = boardCards; self.routines = routines
        self.activeSession = activeSession; self.projects = projects
    }
    public var isEmpty: Bool { tasks.isEmpty && ideas.isEmpty && boardCards.isEmpty && routines.isEmpty && projects.isEmpty }
}

// Decoding tolerates fields missing from older saves and backups, so adding a field never locks people out of their data.
extension Step {
    enum CodingKeys: String, CodingKey { case id, title, isDone }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  isDone: try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false)
    }
}

extension TaskItem {
    enum CodingKeys: String, CodingKey {
        case id, title, plannedAt, scheduledTime, deadline, isMust, effort, project, memo, handoff
        case resumeNote, steps, createdAt, lastStartedAt, completedAt, suggestionDeferredUntil, notify, isEvent, milestoneID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  plannedAt: try c.decodeIfPresent(Date.self, forKey: .plannedAt),
                  scheduledTime: try text(.scheduledTime),
                  deadline: try c.decodeIfPresent(Date.self, forKey: .deadline),
                  isMust: try c.decodeIfPresent(Bool.self, forKey: .isMust) ?? false,
                  effort: try c.decodeIfPresent(Effort.self, forKey: .effort) ?? .medium,
                  project: try text(.project), memo: try text(.memo),
                  handoff: try text(.handoff), resumeNote: try text(.resumeNote),
                  steps: try c.decodeIfPresent([Step].self, forKey: .steps) ?? [],
                  createdAt: try c.decode(Date.self, forKey: .createdAt),
                  lastStartedAt: try c.decodeIfPresent(Date.self, forKey: .lastStartedAt),
                  completedAt: try c.decodeIfPresent(Date.self, forKey: .completedAt),
                  suggestionDeferredUntil: try c.decodeIfPresent(Date.self, forKey: .suggestionDeferredUntil),
                  notify: try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true,
                  isEvent: try c.decodeIfPresent(Bool.self, forKey: .isEvent) ?? false,
                  milestoneID: try c.decodeIfPresent(UUID.self, forKey: .milestoneID))
    }
}

extension BoardCard {
    enum CodingKeys: String, CodingKey { case id, title, purpose, goal, detail, createdAt, project }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  purpose: try text(.purpose), goal: try text(.goal), detail: try text(.detail),
                  createdAt: try c.decode(Date.self, forKey: .createdAt), project: try text(.project))
    }
}

extension Notebook {
    enum CodingKeys: String, CodingKey { case version, tasks, ideas, boardCards, routines, activeSession, projects }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tasks: try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? [],
                  ideas: try c.decodeIfPresent([Idea].self, forKey: .ideas) ?? [],
                  boardCards: try c.decodeIfPresent([BoardCard].self, forKey: .boardCards) ?? [],
                  routines: try c.decodeIfPresent([Routine].self, forKey: .routines) ?? [],
                  activeSession: try c.decodeIfPresent(Session.self, forKey: .activeSession),
                  projects: try c.decodeIfPresent([Project].self, forKey: .projects) ?? [])
        version = try c.decode(Int.self, forKey: .version)
    }
}

public enum NotebookError: LocalizedError {
    case unsupportedVersion, invalidData
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "このバックアップの形式にはまだ対応していません。"
        case .invalidData: return "データの形式を確認できませんでした。現在のデータは変更していません。"
        }
    }
}

public enum NotebookCodec {
    public static func encode(_ notebook: Notebook) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(notebook)
    }
    public static func decode(_ data: Data) throws -> Notebook {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let notebook = try decoder.decode(Notebook.self, from: data)
        guard notebook.version == 1 else { throw NotebookError.unsupportedVersion }
        guard Set(notebook.tasks.map(\.id)).count == notebook.tasks.count,
              Set(notebook.ideas.map(\.id)).count == notebook.ideas.count,
              notebook.tasks.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Set($0.steps.map(\.id)).count == $0.steps.count }),
              notebook.ideas.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(notebook.boardCards.map(\.id)).count == notebook.boardCards.count,
              notebook.boardCards.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(notebook.routines.map(\.id)).count == notebook.routines.count,
              notebook.routines.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.weekdays.isEmpty && $0.weekdays.allSatisfy((1...7).contains) }),
              Set(notebook.projects.map(\.id)).count == notebook.projects.count,
              notebook.projects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && Set($0.milestones.map(\.id)).count == $0.milestones.count })
        else { throw NotebookError.invalidData }
        if let session = notebook.activeSession {
            guard notebook.tasks.contains(where: { $0.id == session.taskID && !$0.isComplete }) else {
                throw NotebookError.invalidData
            }
        }
        return notebook
    }
}
