import Foundation

/// Ordinary task timing is deliberately local to the current app session, not a persisted routine run
/// or the legacy activeSession. Interruption discards it; the next start gets a fresh clock.
public struct TaskWork: Equatable {
    public let taskID: UUID
    public let startedAt: Date
    public init(taskID: UUID, startedAt: Date) {
        self.taskID = taskID; self.startedAt = startedAt
    }
    public func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }
}

public extension Notebook {
    @discardableResult
    mutating func startTask(_ id: UUID, at now: Date = Date()) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isComplete,
              !tasks[i].isEvent, !hasChildren(id) else { return false }
        tasks[i].lastStartedAt = now
        return true
    }

    @discardableResult
    mutating func saveTaskContinuation(_ id: UUID, note: String) -> Bool {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = tasks.firstIndex(where: { $0.id == id }),
              !tasks[i].isEvent, !tasks[i].isComplete else { return false }
        tasks[i].continuationNote = text
        return true
    }

    /// Also covers completion through an editor, a parent, or an older syncing client.
    @discardableResult
    mutating func clearCompletedContinuationNotes() -> Bool {
        var changed = false
        for i in tasks.indices where tasks[i].isComplete && !tasks[i].continuationNote.isEmpty {
            tasks[i].continuationNote = ""
            changed = true
        }
        return changed
    }
}
