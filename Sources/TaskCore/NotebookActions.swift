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

    /// Tasks written from an idea: split into several, or derived while the idea stays for more.
    /// When the idea goes, the first task takes its identity, so two offline devices converting the
    /// same idea still end up with one task for it, as with convertIdea.
    @discardableResult
    mutating func makeTasks(fromIdea id: UUID, _ drafts: [TaskItem], keepIdea: Bool) -> Bool {
        guard ideas.contains(where: { $0.id == id }), !drafts.isEmpty || !keepIdea else { return false }
        var made = drafts
        if !keepIdea, !made.isEmpty, !tasks.contains(where: { $0.id == id }) { made[0].id = id }
        tasks.append(contentsOf: made)
        if !keepIdea { ideas.removeAll { $0.id == id } }
        return true
    }
}
