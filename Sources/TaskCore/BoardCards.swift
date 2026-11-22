import Foundation

/// Tasks and board cards are tied by name, as in task-3days: a task's project and a card's title
/// belong together when they are equal or one contains the other ("TOEIC" and "TOEIC対策").
public enum BoardLink {
    /// Ignores case and spaces, including full-width ones, so "TOEIC 対策" matches "toeic対策".
    public static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// One card per task, so a task never shows under two cards. An exact name wins over containment;
    /// otherwise the first card in board order. Single-character names only match exactly.
    public static func card(for task: TaskItem, in cards: [BoardCard]) -> BoardCard? {
        card(forProject: task.project, in: cards)
    }

    public static func card(forProject project: String, in cards: [BoardCard]) -> BoardCard? {
        let name = normalized(project)
        guard !name.isEmpty else { return nil }
        if let exact = cards.first(where: { normalized($0.title) == name }) { return exact }
        return cards.first { card in
            let title = normalized(card.title)
            guard min(title.count, name.count) >= 2 else { return false }
            return title.contains(name) || name.contains(title)
        }
    }

    public static func tasks(for card: BoardCard, in tasks: [TaskItem], cards: [BoardCard]) -> [TaskItem] {
        tasks.filter { self.card(for: $0, in: cards)?.id == card.id }
    }

    /// Project names in use that no card stands for, the most used first, so they can be picked
    /// again without retyping. Names that differ only in case or spaces count as one.
    public static func looseProjects(tasks: [TaskItem], routines: [Routine], cards: [BoardCard]) -> [String] {
        var seen: [String: (name: String, count: Int)] = [:]
        for raw in tasks.map(\.project) + routines.map(\.project) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(name)
            guard !key.isEmpty, card(forProject: name, in: cards) == nil else { continue }
            seen[key, default: (name, 0)].count += 1
        }
        return seen.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }.map(\.name)
    }
}

