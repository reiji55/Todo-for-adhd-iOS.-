import Foundation

public struct ReminderRequest: Equatable {
    public var id: String
    public var date: Date
    public var title: String
    public var body: String
}

public struct ReminderOptions: Equatable {
    public var leadMinutes: Int
    public var tasks: Bool
    public var routines: Bool
    /// A morning banner on the day something is due.
    public var deadlines: Bool
    public var deadlineHour: Int
    public init(leadMinutes: Int = 0, tasks: Bool = true, routines: Bool = true, deadlines: Bool = true, deadlineHour: Int = 8) {
        self.leadMinutes = leadMinutes; self.tasks = tasks; self.routines = routines
        self.deadlines = deadlines; self.deadlineHour = deadlineHour
    }
}

/// What to announce. iOS keeps at most 64 pending notifications, so only the next few days are planned
/// and the plan is rebuilt whenever the data changes or the app comes back.
public enum ReminderPlan {
    public static func requests(for book: Notebook, now: Date, options: ReminderOptions, days: Int = 3, limit: Int = 60,
                                calendar: Calendar = .current) -> [ReminderRequest] {
        var result: [ReminderRequest] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = DayKey.of(day, calendar: calendar)
            for item in Agenda.items(on: day, tasks: book.tasks, routines: book.routines, calendar: calendar) {
                guard !item.isDone, !item.isBlock, let slot = item.slot, wanted(item, in: book, options: options) else { continue }
                guard let start = calendar.date(byAdding: .minute, value: slot.start, to: day),
                      let fire = calendar.date(byAdding: .minute, value: -options.leadMinutes, to: start), fire > now else { continue }
                let when = options.leadMinutes > 0 ? "\(options.leadMinutes)分後 \(slot.label)" : slot.label
                result.append(ReminderRequest(id: "horme.\(item.id).\(key)", date: fire, title: item.title,
                                              body: item.isRoutine ? "\(when)・ルーティン" : when))
            }
            guard options.deadlines else { continue }
            for task in book.tasks where !task.isComplete && task.notify {
                guard let due = task.deadline, calendar.isDate(due, inSameDayAs: day),
                      let fire = calendar.date(byAdding: .hour, value: options.deadlineHour, to: day), fire > now else { continue }
                result.append(ReminderRequest(id: "horme.deadline.\(task.id.uuidString).\(key)", date: fire,
                                              title: task.title, body: "今日が締切です"))
            }
        }
        return Array(result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.prefix(limit))
    }

    private static func wanted(_ item: AgendaItem, in book: Notebook, options: ReminderOptions) -> Bool {
        switch item.source {
        case .task(let id): return options.tasks && book.tasks.first { $0.id == id }?.notify == true
        case .routine(let id, _): return options.routines && book.routines.first { $0.id == id }?.notify == true
        }
    }
}
