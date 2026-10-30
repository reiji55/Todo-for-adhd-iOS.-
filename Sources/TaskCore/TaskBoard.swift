import Foundation

public struct Candidate: Identifiable, Equatable {
    public let task: TaskItem
    public let reason: String
    public var id: UUID { task.id }
}

/// All visibility decisions live here and can be tested without iOS.
public struct TaskBoard {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func isOnOrBeforeToday(_ date: Date, now: Date) -> Bool {
        calendar.startOfDay(for: date) <= calendar.startOfDay(for: now)
    }

    public func isObligation(_ task: TaskItem, now: Date) -> Bool {
        guard !task.isComplete else { return false }
        let due = task.deadline.map { isOnOrBeforeToday($0, now: now) } ?? false
        let must = task.isMust && (task.plannedAt.map { isOnOrBeforeToday($0, now: now) } ?? true)
        return due || must
    }

    public func obligations(_ tasks: [TaskItem], now: Date) -> [TaskItem] {
        tasks.filter { isObligation($0, now: now) }.sorted { a, b in
            let ad = a.deadline ?? .distantFuture, bd = b.deadline ?? .distantFuture
            if ad != bd { return ad < bd }
            return stableOrder(a, b)
        }
    }

    public func obligationReason(_ task: TaskItem, now: Date) -> String {
        if let due = task.deadline, isOnOrBeforeToday(due, now: now) {
            return calendar.isDate(due, inSameDayAs: now) ? "今日が締切" : "締切を過ぎています"
        }
        return "自分で選んだ必須タスク"
    }

    public func scheduled(_ tasks: [TaskItem], for date: Date) -> [TaskItem] {
        tasks.filter { !$0.isComplete && $0.plannedAt.map { calendar.isDate($0, inSameDayAs: date) } == true }
            .sorted(by: scheduledOrder)
    }

    /// Must first, then by start time, untimed last.
    public func scheduledOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.isMust != b.isMust { return a.isMust }
        let at = a.slot?.start ?? Int.max, bt = b.slot?.start ?? Int.max
        if at != bt { return at < bt }
        return stableOrder(a, b)
    }

    public func pastPlanned(_ tasks: [TaskItem], now: Date) -> [TaskItem] {
        tasks.filter { !$0.isComplete && $0.plannedAt.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: now) } == true }
    }

    /// Suggestions are additive. Energy changes ranking, never obligation visibility.
    /// Fixed tiers make the result explainable; no hidden probabilistic score or cooldown.
    public func candidates(_ tasks: [TaskItem], energy: Energy, now: Date, limit: Int = 3) -> [Candidate] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let pool = tasks.filter { task in
            guard !task.isComplete, !isObligation(task, now: now) else { return false }
            if let deferUntil = task.suggestionDeferredUntil, deferUntil > now { return false }
            if let planned = task.plannedAt, !isOnOrBeforeToday(planned, now: now) { return false }
            return true
        }
        func tier(_ task: TaskItem) -> Int {
            if let due = task.deadline, calendar.startOfDay(for: due) <= tomorrow { return 0 }
            if task.plannedAt.map({ calendar.isDate($0, inSameDayAs: now) }) == true { return 1 }
            if !task.resumeNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 2 }
            return 3
        }
        func fit(_ task: TaskItem) -> Int {
            guard let wanted = energy.preferred else { return 0 }
            return abs(task.effort.rank - wanted.rank)
        }
        return Array(pool.sorted { a, b in
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            if fit(a) != fit(b) { return fit(a) < fit(b) }
            let ad = a.lastStartedAt ?? a.createdAt, bd = b.lastStartedAt ?? b.createdAt
            if ad != bd { return ad < bd }
            return stableOrder(a, b)
        }.prefix(max(0, limit))).map { task in
            let reason: String
            switch tier(task) {
            case 0: reason = "明日が締切"
            case 1: reason = "今日やる予定"
            case 2: reason = "続きのメモがあります"
            default:
                reason = energy.preferred == task.effort ? "今の調子に合う負荷" : "しばらく手をつけていないもの"
            }
            return Candidate(task: task, reason: reason)
        }
    }

    private func stableOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
