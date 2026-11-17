import Foundation

/// 期間タスク: a task to be done some time from one day to another ("12/1〜12/31"). The stretch is its
/// `periodStart` and its deadline, so when the stretch ends it is due like any deadline. Before the first day
/// it is quiet (not suggested); within the stretch it is suggested, and shows on today in the week and in the
/// timetable. A piece goes by the stretch of the task it is a piece of.
public struct TaskPeriod: Equatable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = min(start, end); self.end = max(start, end)
    }

    public func contains(_ day: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: day)
        return calendar.startOfDay(for: start) <= day && day <= calendar.startOfDay(for: end)
    }

    /// Whole days from the day to the last one: 0 on the last day.
    public func daysLeft(from day: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: end)).day ?? 0
    }

    /// Days in the stretch, both ends counted.
    public func length(calendar: Calendar = .current) -> Int {
        (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0) + 1
    }

    /// "12/1〜12/31".
    public func text(calendar: Calendar = .current) -> String {
        "\(Self.monthDay(start, calendar: calendar))〜\(Self.monthDay(end, calendar: calendar))"
    }

    static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
}

public extension TaskItem {
    /// Its own stretch: from `periodStart` to the deadline. Nil without both.
    var period: TaskPeriod? {
        guard let periodStart, let deadline else { return nil }
        return TaskPeriod(start: periodStart, end: deadline)
    }
}

public extension Notebook {
    /// The stretch that applies: the task's own, or that of the task it is a piece of.
    func period(of task: TaskItem) -> TaskPeriod? {
        task.period ?? task.parentID.flatMap { id in tasks.first { $0.id == id } }?.period
    }

    /// Open 期間タスク whose stretch includes the day, last day first. Top level only: a task in pieces is one.
    func periodTasks(on day: Date, calendar: Calendar = .current) -> [TaskItem] {
        tasks.filter { task in
            !task.isComplete && !task.isEvent && task.parentID == nil && task.period?.contains(day, calendar: calendar) == true
        }
        .sorted { ($0.deadline ?? .distantFuture, $0.createdAt) < ($1.deadline ?? .distantFuture, $1.createdAt) }
    }
}
