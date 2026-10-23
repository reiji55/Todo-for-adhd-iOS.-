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
    public var kind: String
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

    public init(id: UUID = UUID(), title: String, plannedAt: Date? = nil,
                scheduledTime: String = "", deadline: Date? = nil, isMust: Bool = false,
                effort: Effort = .medium, kind: String = "", project: String = "", memo: String = "",
                handoff: String = "", resumeNote: String = "", steps: [Step] = [],
                createdAt: Date = Date(), lastStartedAt: Date? = nil, completedAt: Date? = nil,
                suggestionDeferredUntil: Date? = nil) {
        self.id = id; self.title = title; self.plannedAt = plannedAt
        self.scheduledTime = scheduledTime; self.deadline = deadline; self.isMust = isMust
        self.effort = effort; self.kind = kind; self.project = project; self.memo = memo; self.handoff = handoff
        self.resumeNote = resumeNote; self.steps = steps; self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt; self.completedAt = completedAt
        self.suggestionDeferredUntil = suggestionDeferredUntil
    }
    public var isComplete: Bool { completedAt != nil }
    public var nextStep: Step? { steps.first { !$0.isDone } }
    /// A task with no steps is still immediately actionable.
    public var actionTitle: String { nextStep?.title ?? title }
}

public struct Idea: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.createdAt = createdAt
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
    public var activeSession: Session?
    public init(tasks: [TaskItem] = [], ideas: [Idea] = [], activeSession: Session? = nil) {
        self.tasks = tasks; self.ideas = ideas; self.activeSession = activeSession
    }
}

// Decoding tolerates fields missing from older saves, so adding a field later never locks people out of their data.
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
        case id, title, plannedAt, scheduledTime, deadline, isMust, effort, kind, project, memo, handoff
        case resumeNote, steps, createdAt, lastStartedAt, completedAt, suggestionDeferredUntil
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
                  kind: try text(.kind), project: try text(.project), memo: try text(.memo),
                  handoff: try text(.handoff), resumeNote: try text(.resumeNote),
                  steps: try c.decodeIfPresent([Step].self, forKey: .steps) ?? [],
                  createdAt: try c.decode(Date.self, forKey: .createdAt),
                  lastStartedAt: try c.decodeIfPresent(Date.self, forKey: .lastStartedAt),
                  completedAt: try c.decodeIfPresent(Date.self, forKey: .completedAt),
                  suggestionDeferredUntil: try c.decodeIfPresent(Date.self, forKey: .suggestionDeferredUntil))
    }
}

extension Notebook {
    enum CodingKeys: String, CodingKey { case version, tasks, ideas, activeSession }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tasks: try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? [],
                  ideas: try c.decodeIfPresent([Idea].self, forKey: .ideas) ?? [],
                  activeSession: try c.decodeIfPresent(Session.self, forKey: .activeSession))
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
              notebook.ideas.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw NotebookError.invalidData }
        if let session = notebook.activeSession {
            guard notebook.tasks.contains(where: { $0.id == session.taskID && !$0.isComplete }) else {
                throw NotebookError.invalidData
            }
        }
        return notebook
    }
}
