import Foundation

public struct Candidate: Identifiable, Equatable {
    public let task: TaskItem
    public let reason: String
    /// The reason in a few words, for a small label ("明日が締切", "今日の予定", "続き"). Empty when
    /// there is nothing worth saying.
    public let label: String
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
        guard !task.isComplete, !task.isEvent else { return false }
        let due = task.deadline.map { isOnOrBeforeToday($0, now: now) } ?? false
        let must = task.isMust && (task.plannedAt.map { isOnOrBeforeToday($0, now: now) } ?? true)
        return due || must
    }

    /// A parent has no day of its own: for ★ it counts from the first day of its open children.
    public func isObligation(_ task: TaskItem, among tasks: [TaskItem], now: Date) -> Bool {
        let kids = tasks.filter { $0.parentID == task.id }
        guard !kids.isEmpty else { return isObligation(task, now: now) }
        var probe = task
        probe.plannedAt = kids.filter { !$0.isComplete }.compactMap(\.plannedAt).min()
        return isObligation(probe, now: now)
    }

    public func obligations(_ tasks: [TaskItem], now: Date) -> [TaskItem] {
        tasks.filter { isObligation($0, among: tasks, now: now) }.sorted { a, b in
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
        tasks.filter { !$0.isComplete && !$0.isEvent && $0.plannedAt.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: now) } == true }
    }

    /// Suggestions are additive. Energy changes ranking, never obligation visibility.
    /// Fixed tiers make the result explainable; no hidden probabilistic score or cooldown.
    public func candidates(_ tasks: [TaskItem], energy: Energy, now: Date, limit: Int = 3) -> [Candidate] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        // A parent is done through its pieces, so the pieces are what is suggested.
        let parents = Set(tasks.compactMap(\.parentID))
        // Tasks in pieces already under way: their next pieces come before untouched ones.
        let underway = Set(tasks.filter { $0.isComplete }.compactMap(\.parentID))
        let pool = tasks.filter { task in
            guard !task.isComplete, !task.isEvent, !parents.contains(task.id), !isObligation(task, now: now) else { return false }
            if let deferUntil = task.suggestionDeferredUntil, deferUntil > now { return false }
            if let planned = task.plannedAt, !isOnOrBeforeToday(planned, now: now) { return false }
            return true
        }
        func tier(_ task: TaskItem) -> Int {
            if let due = task.deadline, calendar.startOfDay(for: due) <= tomorrow { return 0 }
            if task.plannedAt.map({ calendar.isDate($0, inSameDayAs: now) }) == true { return 1 }
            if let parent = task.parentID, underway.contains(parent) { return 2 }
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
            let label: String
            switch tier(task) {
            case 0: reason = "明日が締切"; label = "明日が締切"
            case 1: reason = "今日やる予定"; label = "今日の予定"
            case 2: reason = "途中まで進んでいるタスクの続き"; label = "続き"
            default:
                if energy.preferred == task.effort {
                    reason = "今の調子に合う負荷"; label = "調子に合う"
                } else {
                    reason = "しばらく手をつけていないもの"
                    // A task written down this week has not been waiting long.
                    let untouched = now.timeIntervalSince(task.lastStartedAt ?? task.createdAt)
                    label = untouched >= 7 * 24 * 3600 ? "しばらく手つかず" : ""
                }
            }
            return Candidate(task: task, reason: reason, label: label)
        }
    }

    private func stableOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
