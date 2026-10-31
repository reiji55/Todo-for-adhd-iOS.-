import Foundation

/// Schedules as plain text, for Shortcuts, Siri and AI assistants. Written so a person or a model can
/// read it without knowing the app: one line per item, time first, kind and project in brackets.
public enum PlainText {
    private static let weekdays = ["日", "月", "火", "水", "木", "金", "土"]

    public static func dayTitle(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .weekday], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日(\(weekdays[(c.weekday ?? 1) - 1]))"
    }

    public static func line(_ item: AgendaItem, task: TaskItem? = nil) -> String {
        let time = item.slot?.label ?? "時間未定"
        var tags: [String] = []
        if item.isRoutine { tags.append(item.isBlock ? "押さえている時間" : "ルーティン") }
        if item.isMust { tags.append("必須") }
        if let due = task?.deadline { tags.append("締切\(Calendar.current.component(.month, from: due))/\(Calendar.current.component(.day, from: due))") }
        if !item.project.isEmpty { tags.append(item.project) }
        let mark = item.isBlock ? "・" : (item.isDone ? "[x]" : "[ ]")
        var text = "\(mark) \(time) \(item.title)" + (tags.isEmpty ? "" : "〔\(tags.joined(separator: "・"))〕")
        if let task, !task.isComplete {
            if let next = task.nextStep { text += "\n    次の一手：\(next.title)" }
            if !task.resumeNote.isEmpty { text += "\n    続き：\(task.resumeNote)" }
            if !task.handoff.isEmpty { text += "\n    AIへの引き継ぎ：\(task.handoff)" }
        }
        return text
    }

    public static func day(_ date: Date, book: Notebook, includeDone: Bool = true, calendar: Calendar = .current) -> String {
        let items = Agenda.items(on: date, tasks: book.tasks, routines: book.routines, calendar: calendar)
            .filter { includeDone || !$0.isDone }
        var lines = [dayTitle(date, calendar: calendar)]
        if items.isEmpty { lines.append("予定はありません。") }
        for item in items {
            var task: TaskItem?
            if case .task(let id) = item.source { task = book.tasks.first { $0.id == id } }
            lines.append(line(item, task: task))
        }
        return lines.joined(separator: "\n")
    }

    /// Today, plus what would otherwise be missed: overdue and undated must tasks, and tasks left on earlier days.
    public static func today(_ now: Date, book: Notebook, calendar: Calendar = .current) -> String {
        let board = TaskBoard(calendar: calendar)
        var parts = [day(now, book: book, calendar: calendar)]
        let required = board.obligations(book.tasks, now: now).filter {
            $0.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } != true
        }
        if !required.isEmpty {
            parts.append("今日中に必要なもの\n" + required.map { "\(line(AgendaItem(task: $0), task: $0))（\(board.obligationReason($0, now: now))）" }
                .joined(separator: "\n"))
        }
        let leftovers = board.pastPlanned(book.tasks, now: now)
        if !leftovers.isEmpty {
            parts.append("前の日から残っているもの\n" + leftovers.map { task in
                "[ ] \(task.plannedAt.map { dayTitle($0, calendar: calendar) } ?? "") \(task.title)"
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    public static func week(from start: Date, days: Int = 7, book: Notebook, calendar: Calendar = .current) -> String {
        (0..<max(1, min(days, 31))).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { day($0, book: book, calendar: calendar) }.joined(separator: "\n\n")
    }

    public static func anytime(book: Notebook) -> String {
        let tasks = book.tasks.filter { !$0.isComplete && $0.plannedAt == nil }
        guard !tasks.isEmpty else { return "日付を決めていないタスクはありません。" }
        return "いつでも（日付なし）\n" + tasks.map { line(AgendaItem(task: $0), task: $0) }.joined(separator: "\n")
    }
}

public extension AgendaItem {
    init(task: TaskItem) {
        self.init(source: .task(task.id), title: task.title, project: task.project, slot: task.slot,
                  isDone: task.isComplete, isMust: task.isMust, isBlock: false)
    }
}
