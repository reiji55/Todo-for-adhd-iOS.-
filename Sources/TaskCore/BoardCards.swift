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
}

public struct BoardImport {
    public var cards: [BoardCard]
    public var skipped: Int
}

/// Reads task-3days `board.json` (`{"cards": [{title, created, goal, purpose, detail}]}`) without contacting its server.
public enum BoardImporter {
    private struct File: Decodable {
        struct Card: Decodable {
            var title: String?
            var created: String?
            var goal: String?
            var purpose: String?
            var detail: String?
        }
        var cards: [Card]
    }

    /// True only for the board file shape, so a backup or another JSON file is never misread as a board.
    public static func isBoardFile(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["cards"] is [Any] && object["tasks"] == nil && object["version"] == nil
    }

    public static func parse(_ data: Data, now: Date = Date(), calendar: Calendar = .current) throws -> BoardImport {
        let file = try JSONDecoder().decode(File.self, from: data)
        var result = BoardImport(cards: [], skipped: 0)
        for card in file.cards {
            let title = (card.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { result.skipped += 1; continue }
            result.cards.append(BoardCard(title: title, purpose: card.purpose ?? "", goal: card.goal ?? "",
                                          detail: card.detail ?? "",
                                          createdAt: day(card.created, calendar: calendar) ?? now))
        }
        return result
    }

    /// Adds only cards whose title is not on the board yet; existing cards are never changed.
    public static func merge(_ incoming: [BoardCard], into existing: [BoardCard]) -> [BoardCard] {
        var seen = Set(existing.map { BoardLink.normalized($0.title) })
        return existing + incoming.filter { seen.insert(BoardLink.normalized($0.title)).inserted }
    }

    private static func day(_ text: String?, calendar: Calendar) -> Date? {
        guard let fields = text?.split(separator: "-").compactMap({ Int($0) }), fields.count == 3 else { return nil }
        let date = calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2], hour: 12))
        guard let date, calendar.component(.day, from: date) == fields[2] else { return nil }
        return date
    }
}
