import Foundation

/// パッケージ: a named set of pieces that comes back the same way each time (旅行の準備: 荷造り, レンタカーを手配…).
/// Only the names and their order are kept: no days, no deadlines. Put into a task it becomes its pieces; put
/// into an event it becomes the event's 関連タスク.
public struct TaskPackage: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var items: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, items: [String], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.items = items; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, items, createdAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        items = try c.decodeIfPresent([String].self, forKey: .items) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// The names worth putting in: trimmed, none empty.
    public var cleanItems: [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public extension Notebook {
    /// Saves how a task is split as a パッケージ under a name. A パッケージ of the same name is written over.
    @discardableResult
    mutating func savePackage(fromPiecesOf taskID: UUID, name: String, at now: Date = Date()) -> UUID? {
        savePackage(name: name, items: children(of: taskID).map(\.title), at: now)
    }

    /// Makes a パッケージ, or writes over the one with this name. Nil without a name or anything in it.
    @discardableResult
    mutating func savePackage(name: String, items: [String], at now: Date = Date()) -> UUID? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = TaskPackage(name: title, items: items).cleanItems
        guard !title.isEmpty, !names.isEmpty else { return nil }
        if let i = packages.firstIndex(where: { $0.name == title }) {
            packages[i].items = names
            return packages[i].id
        }
        let package = TaskPackage(name: title, items: names, createdAt: now)
        packages.append(package)
        return package.id
    }

    /// Puts a パッケージ into a task as its pieces (after any it has), or into an event as its 関連タスク.
    /// Returns how many were added.
    @discardableResult
    mutating func applyPackage(_ id: UUID, to targetID: UUID, at now: Date = Date()) -> Int {
        guard let package = packages.first(where: { $0.id == id }),
              let target = tasks.first(where: { $0.id == targetID }), target.parentID == nil else { return 0 }
        let names = package.cleanItems
        for (index, name) in names.enumerated() {
            // A second's step apart keeps them in the order of the パッケージ.
            let task = TaskItem(title: name, createdAt: now.addingTimeInterval(Double(index) / 1000))
            if target.isEvent { addRelated(task, to: targetID) } else { addChild(task, to: targetID, at: now) }
        }
        return names.count
    }

    // MARK: 関連タスク

    /// The tasks for an event, in the order they were added.
    func relatedTasks(of eventID: UUID) -> [TaskItem] {
        tasks.filter { $0.eventID == eventID && $0.parentID == nil }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    /// A task for an event: due on the event's day unless it has a deadline of its own, in the event's project.
    mutating func addRelated(_ task: TaskItem, to eventID: UUID) {
        guard let event = tasks.first(where: { $0.id == eventID }), event.isEvent else { return }
        var related = task
        related.eventID = eventID
        related.isEvent = false
        related.parentID = nil
        if related.deadline == nil { related.deadline = event.plannedAt }
        if related.project.isEmpty { related.project = event.project }
        tasks.append(related)
    }

    /// The event a task is for, while it is there.
    func event(of task: TaskItem) -> TaskItem? {
        task.eventID.flatMap { id in tasks.first { $0.id == id && $0.isEvent } }
    }
}
