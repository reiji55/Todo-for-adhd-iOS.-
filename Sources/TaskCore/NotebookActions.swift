import Foundation

public extension Notebook {
    /// Stable identity prevents two offline devices from turning one idea into
    /// two tasks. Existing unrelated records with that ID are never overwritten.
    @discardableResult
    mutating func convertIdea(_ id: UUID, plannedAt: Date?) -> Bool {
        guard let idea = ideas.first(where: { $0.id == id }), !tasks.contains(where: { $0.id == id }) else { return false }
        let lines = idea.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        tasks.append(TaskItem(id: idea.id, title: lines.first ?? idea.text, plannedAt: plannedAt,
                              memo: lines.dropFirst().joined(separator: "\n"), createdAt: idea.createdAt))
        ideas.removeAll { $0.id == id }
        return true
    }

    mutating func startTask(_ id: UUID, at now: Date = Date()) {
        guard let target = tasks.firstIndex(where: { $0.id == id && !$0.isComplete }) else { return }
        guard activeSession?.taskID != id else { return }
        if let previous = activeSession,
           let old = tasks.firstIndex(where: { $0.id == previous.taskID }),
           tasks[old].resumeNote.isEmpty {
            let action = tasks[old].steps.first { $0.id == previous.stepID }?.title ?? tasks[old].title
            tasks[old].resumeNote = "「\(action)」の途中"
        }
        activeSession = Session(taskID: id, startedAt: now, stepID: tasks[target].nextStep?.id)
        tasks[target].lastStartedAt = now
    }

    mutating func pauseTask(note: String) {
        if let active = activeSession,
           let i = tasks.firstIndex(where: { $0.id == active.taskID }) {
            let action = tasks[i].steps.first { $0.id == active.stepID }?.title ?? tasks[i].title
            tasks[i].resumeNote = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "「\(action)」の途中" : note
        }
        activeSession = nil
    }

    mutating func finishAction(at now: Date = Date()) {
        guard let active = activeSession,
              let i = tasks.firstIndex(where: { $0.id == active.taskID }) else { return }
        if let stepID = active.stepID {
            // If an edited task no longer contains this step, never complete a different one.
            if let j = tasks[i].steps.firstIndex(where: { $0.id == stepID }) {
                tasks[i].steps[j].isDone = true
            }
        } else {
            tasks[i].completedAt = now
        }
        tasks[i].resumeNote = ""
        activeSession = nil
    }
}
