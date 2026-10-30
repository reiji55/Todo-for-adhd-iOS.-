import Foundation

/// A stable per-field ordering. Observe remote clocks before creating a local edit.
public struct SyncStamp: Codable, Equatable, Comparable {
    public var tick: Int64
    public var device: String
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.tick == rhs.tick ? lhs.device < rhs.device : lhs.tick < rhs.tick
    }
}

public struct SyncField: Codable, Equatable {
    public var value: Data
    public var stamp: SyncStamp
}

public struct SyncRecord: Codable, Equatable {
    public var version = 1
    public var id: String
    public var fields: [String: SyncField] = [:]

    public mutating func merge(_ other: Self) throws {
        guard version == 1, other.version == 1, id == other.id else { throw NotebookError.unsupportedVersion }
        for (key, field) in other.fields {
            guard field.stamp.tick >= 0, field.stamp.tick < Int64.max, !field.stamp.device.isEmpty else {
                throw NotebookError.invalidData
            }
            if let current = fields[key] {
                // Equal stamps must contain the same value; corruption must not silently diverge.
                if current.stamp == field.stamp, current.value != field.value { throw NotebookError.invalidData }
                if current.stamp < field.stamp { fields[key] = field }
            } else { fields[key] = field }
        }
    }

    public static func decode(_ data: Data, expectedID: String) throws -> Self {
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.id == expectedID, record.version == 1,
              record.id == "session" || ["task_", "idea_", "card_", "routine_"].contains(where: record.id.hasPrefix) else {
            throw NotebookError.unsupportedVersion
        }
        guard record.fields["alive"] != nil else { throw NotebookError.invalidData }
        var validated = Self(id: record.id)
        try validated.merge(record)
        return validated
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// The replica is saved atomically with the visible data. Unsent edits therefore
/// survive termination and are retried by comparing these fields with CloudKit.
/// Deleted records/steps retain tombstones so stale offline edits cannot revive them.
public struct SyncReplica: Codable, Equatable {
    public var records: [String: SyncRecord] = [:]
    public var clock: Int64 = 0
    public init() {}

    public mutating func merge(_ incoming: [SyncRecord]) throws {
        for record in incoming {
            var current = records[record.id] ?? SyncRecord(id: record.id)
            try current.merge(record)
            records[record.id] = current
            clock = max(clock, current.fields.values.map(\.stamp.tick).max() ?? 0)
        }
    }

    public mutating func apply(before: Notebook, after: Notebook, device: String, now: Date = Date()) throws {
        let old = try Self.flatten(before)
        let new = try Self.flatten(after)
        let wall = Int64(now.timeIntervalSince1970 * 1000)
        guard clock < Int64.max - 1 else { throw NotebookError.invalidData }
        clock = max(clock + 1, wall)
        let stamp = SyncStamp(tick: clock, device: device)
        for id in Set(old.keys).union(new.keys) {
            guard old[id] != new[id] else { continue }
            var record = records[id] ?? SyncRecord(id: id)
            if new[id] == nil {
                record.fields["alive"] = SyncField(value: Data("false".utf8), stamp: stamp)
            } else {
                if old[id] == nil {
                    record.fields["alive"] = SyncField(value: Data("true".utf8), stamp: stamp)
                }
                let beforeFields = old[id] ?? [:]
                let afterFields = new[id] ?? [:]
                for key in Set(beforeFields.keys).union(afterFields.keys) where beforeFields[key] != afterFields[key] {
                    record.fields[key] = SyncField(value: afterFields[key] ?? Data("null".utf8), stamp: stamp)
                }
            }
            records[id] = record
        }
    }

    public func materialize() throws -> Notebook {
        var tasks: [TaskItem] = []
        var ideas: [Idea] = []
        var cards: [(rank: Int, card: BoardCard)] = []
        var routines: [Routine] = []
        var session: Session?
        for record in records.values {
            guard try Self.object(record.fields["alive"]?.value) as? Bool == true else { continue }
            var object: [String: Any] = [:]
            for (key, field) in record.fields where key != "alive" && !key.hasPrefix("step.")
                && !key.hasPrefix("done.") && !key.hasPrefix("move.") {
                object[key] = try Self.object(field.value)
            }
            if record.id.hasPrefix("task_") {
                var steps: [(Int, String, [String: Any])] = []
                let ids = Set(record.fields.keys.filter { $0.hasPrefix("step.") }.compactMap {
                    $0.split(separator: ".").dropFirst().first.map(String.init)
                })
                for id in ids {
                    let prefix = "step.\(id)."
                    guard try Self.object(record.fields[prefix + "alive"]?.value) as? Bool == true else { continue }
                    guard let title = try Self.object(record.fields[prefix + "title"]?.value) as? String,
                          let done = try Self.object(record.fields[prefix + "isDone"]?.value) as? Bool else {
                        throw NotebookError.invalidData
                    }
                    let rank = try Self.object(record.fields[prefix + "rank"]?.value) as? Int ?? 0
                    steps.append((rank, id, ["id": id, "title": title, "isDone": done]))
                }
                object["steps"] = steps.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
                let task: TaskItem = try Self.decodeObject(object)
                guard record.id == "task_\(task.id.uuidString)" else { throw NotebookError.invalidData }
                tasks.append(task)
            } else if record.id.hasPrefix("idea_") {
                let idea: Idea = try Self.decodeObject(object)
                guard record.id == "idea_\(idea.id.uuidString)" else { throw NotebookError.invalidData }
                ideas.append(idea)
            } else if record.id.hasPrefix("card_") {
                let rank = object.removeValue(forKey: "rank") as? Int ?? 0
                let card: BoardCard = try Self.decodeObject(object)
                guard record.id == "card_\(card.id.uuidString)" else { throw NotebookError.invalidData }
                cards.append((rank, card))
            } else if record.id.hasPrefix("routine_") {
                // Each day's check and move is its own field, so different days edited on two devices both survive.
                var done: [String] = []
                var moves: [String: Any] = [:]
                for (key, field) in record.fields {
                    let value = try Self.object(field.value)
                    if key.hasPrefix("done."), value as? Bool == true { done.append(String(key.dropFirst(5))) }
                    if key.hasPrefix("move."), value is [String: Any] { moves[String(key.dropFirst(5))] = value }
                }
                object["doneDays"] = done.sorted()
                object["moves"] = moves
                let routine: Routine = try Self.decodeObject(object)
                guard record.id == "routine_\(routine.id.uuidString)" else { throw NotebookError.invalidData }
                routines.append(routine)
            } else if record.id == "session" {
                // A session is one field to keep its task/step/time together.
                if let data = record.fields["value"]?.value { session = try Self.decoder().decode(Session.self, from: data) }
            } else { throw NotebookError.unsupportedVersion }
        }
        tasks.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        ideas.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        if let active = session, !tasks.contains(where: { $0.id == active.taskID && !$0.isComplete }) { session = nil }
        // Board order is the person's choice, so it travels as a rank like steps do.
        cards.sort { $0.rank == $1.rank ? $0.card.id.uuidString < $1.card.id.uuidString : $0.rank < $1.rank }
        routines.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        let book = Notebook(tasks: tasks, ideas: ideas, boardCards: cards.map(\.card), routines: routines, activeSession: session)
        // Validate remote data before replacing a user's local view.
        _ = try NotebookCodec.decode(NotebookCodec.encode(book))
        return book
    }

    /// Apply only the fields edited in an open editor, preserving concurrent
    /// remote changes to other fields (including individual steps).
    public static func editedTask(original: TaskItem, edited: TaskItem, current: TaskItem) throws -> TaskItem {
        var replica = SyncReplica()
        let base = Notebook(tasks: [original])
        try replica.apply(before: Notebook(), after: base, device: "base", now: Date(timeIntervalSince1970: 0))
        try replica.apply(before: base, after: Notebook(tasks: [current]), device: "remote", now: Date(timeIntervalSince1970: 1))
        try replica.apply(before: base, after: Notebook(tasks: [edited]), device: "editor", now: Date(timeIntervalSince1970: 2))
        guard let result = try replica.materialize().tasks.first else { throw NotebookError.invalidData }
        return result
    }

    private static func flatten(_ book: Notebook) throws -> [String: [String: Data]] {
        var result: [String: [String: Data]] = [:]
        for task in book.tasks {
            var fields = try fieldsFor(task)
            fields.removeValue(forKey: "steps")
            for (index, step) in task.steps.enumerated() {
                let prefix = "step.\(step.id.uuidString)."
                fields[prefix + "alive"] = Data("true".utf8)
                fields[prefix + "title"] = try jsonData(step.title)
                fields[prefix + "isDone"] = try jsonData(step.isDone)
                fields[prefix + "rank"] = try jsonData(index)
            }
            result["task_\(task.id.uuidString)"] = fields
        }
        for idea in book.ideas { result["idea_\(idea.id.uuidString)"] = try fieldsFor(idea) }
        for (index, card) in book.boardCards.enumerated() {
            var fields = try fieldsFor(card)
            fields["rank"] = try jsonData(index)
            result["card_\(card.id.uuidString)"] = fields
        }
        for routine in book.routines {
            var fields = try fieldsFor(routine)
            fields.removeValue(forKey: "doneDays"); fields.removeValue(forKey: "moves")
            for day in routine.doneDays { fields["done." + day] = try jsonData(true) }
            for (day, move) in routine.moves {
                fields["move." + day] = try jsonData(["toDay": move.toDay, "time": move.time])
            }
            result["routine_\(routine.id.uuidString)"] = fields
        }
        if let session = book.activeSession { result["session"] = ["value": try encoder().encode(session)] }
        return result
    }

    private static func fieldsFor<T: Encodable>(_ value: T) throws -> [String: Data] {
        guard let object = try JSONSerialization.jsonObject(with: encoder().encode(value)) as? [String: Any] else {
            throw NotebookError.invalidData
        }
        return try object.mapValues { try jsonData($0) }
    }
    private static func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    private static func object(_ data: Data?) throws -> Any {
        guard let data else { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    private static func decodeObject<T: Decodable>(_ object: [String: Any]) throws -> T {
        try decoder().decode(T.self, from: jsonData(object))
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct ShareMergePreview {
    public var combined: Notebook
    public var conflictingTasks = 0
    public var conflictingIdeas = 0
    public var conflictingCards = 0
    public var conflictingRoutines = 0

    /// Before joining, keep different data with the same ID as a separate copy.
    /// Normal synchronization uses field merging; this rule is only for joining
    /// two previously independent data sets, where no common edit history exists.
    public init(local: Notebook, remote: Notebook) {
        combined = remote
        var remappedTasks: [UUID: UUID] = [:]
        for var task in local.tasks {
            if let existing = remote.tasks.first(where: { $0.id == task.id }) {
                if (try? NotebookCodec.encode(Notebook(tasks: [existing]))) == (try? NotebookCodec.encode(Notebook(tasks: [task]))) { continue }
                let originalID = task.id
                task.id = UUID(); remappedTasks[originalID] = task.id; conflictingTasks += 1
            }
            combined.tasks.append(task)
        }
        for var idea in local.ideas {
            if let existing = remote.ideas.first(where: { $0.id == idea.id }) {
                if (try? NotebookCodec.encode(Notebook(ideas: [existing]))) == (try? NotebookCodec.encode(Notebook(ideas: [idea]))) { continue }
                idea.id = UUID(); conflictingIdeas += 1
            }
            combined.ideas.append(idea)
        }
        for var card in local.boardCards {
            if let existing = remote.boardCards.first(where: { $0.id == card.id }) {
                if Self.samePersistedContents(Notebook(boardCards: [existing]), Notebook(boardCards: [card])) { continue }
                card.id = UUID(); conflictingCards += 1
            }
            combined.boardCards.append(card)
        }
        for var routine in local.routines {
            if let existing = remote.routines.first(where: { $0.id == routine.id }) {
                if Self.samePersistedContents(Notebook(routines: [existing]), Notebook(routines: [routine])) { continue }
                routine.id = UUID(); conflictingRoutines += 1
            }
            combined.routines.append(routine)
        }
        if combined.activeSession == nil, var active = local.activeSession {
            active.taskID = remappedTasks[active.taskID] ?? active.taskID
            if combined.tasks.contains(where: { $0.id == active.taskID && !$0.isComplete }) { combined.activeSession = active }
        }
    }

    private static func samePersistedContents(_ left: Notebook, _ right: Notebook) -> Bool {
        // Cloud payloads keep whole seconds. Compare decoded values as well so
        // a routine's Set of completed days does not depend on JSON array order.
        guard let first = try? NotebookCodec.decode(NotebookCodec.encode(left)),
              let second = try? NotebookCodec.decode(NotebookCodec.encode(right)) else { return false }
        return first == second
    }
}
