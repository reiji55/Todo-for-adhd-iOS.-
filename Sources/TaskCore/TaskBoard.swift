import Foundation

public struct Candidate: Identifiable, Equatable {
    public let task: TaskItem
    public let reason: String
    /// The reason in a few words, for a small label ("明日が締切", "今日の予定", "続き"). Empty when
    /// there is nothing worth saying; ★ has a mark of its own (`isMust`).
    public let label: String
    /// ★ on the task, or on the task it is a piece of.
    public let isMust: Bool
    public var id: UUID { task.id }
}

/// All visibility decisions live here and can be tested without iOS.
///
/// A deadline says by when; ★ says that a task cannot be dropped. Only a deadline makes a task due
/// today: ★ alone never pushes in front of what is planned for the day. ★ tasks are kept together
/// below today's plan (`musts`) and come first among suggestions of the same standing.
public struct TaskBoard {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func isOnOrBeforeToday(_ date: Date, now: Date) -> Bool {
        calendar.startOfDay(for: date) <= calendar.startOfDay(for: now)
    }

    /// Due today or earlier: its deadline has come.
    public func isObligation(_ task: TaskItem, now: Date) -> Bool {
        guard !task.isComplete, !task.isEvent, let due = task.deadline else { return false }
        return isOnOrBeforeToday(due, now: now)
    }

    /// The same for a task among its family: a task in pieces carries the deadline itself.
    public func isObligation(_ task: TaskItem, among tasks: [TaskItem], now: Date) -> Bool {
        isObligation(task, now: now)
    }

    public func obligations(_ tasks: [TaskItem], now: Date) -> [TaskItem] {
        tasks.filter { isObligation($0, now: now) }.sorted { a, b in
            let ad = a.deadline ?? .distantFuture, bd = b.deadline ?? .distantFuture
            if ad != bd { return ad < bd }
            return stableOrder(a, b)
        }
    }

    public func obligationReason(_ task: TaskItem, now: Date) -> String {
        guard let due = task.deadline else { return "" }
        return calendar.isDate(due, inSameDayAs: now) ? "今日が締切" : "締切を過ぎています"
    }

    /// ★ on the task itself, or on the task it is a piece of.
    public func isMust(_ task: TaskItem, among tasks: [TaskItem]) -> Bool {
        task.isMust || (task.parentID.flatMap { id in tasks.first { $0.id == id } }?.isMust ?? false)
    }

    /// The deadline that applies: the task's own, else that of the task it is a piece of.
    public func deadline(of task: TaskItem, among tasks: [TaskItem]) -> Date? {
        task.deadline ?? task.parentID.flatMap { id in tasks.first { $0.id == id } }?.deadline
    }

    /// ★ tasks still open and not due yet, kept together below today's plan. Top level only (a task in
    /// pieces is one entry), nearest deadline first, then the soonest planned day, then undated.
    public func musts(_ tasks: [TaskItem], now: Date) -> [TaskItem] {
        func planned(_ task: TaskItem) -> Date {
            let kids = tasks.filter { $0.parentID == task.id && !$0.isComplete }
            return (kids.isEmpty ? task.plannedAt : kids.compactMap(\.plannedAt).min()) ?? .distantFuture
        }
        return tasks.filter { $0.isMust && !$0.isComplete && !$0.isEvent && $0.parentID == nil && !isObligation($0, now: now) }
            .sorted { a, b in
                let ad = a.deadline ?? .distantFuture, bd = b.deadline ?? .distantFuture
                if ad != bd { return ad < bd }
                let ap = planned(a), bp = planned(b)
                if ap != bp { return ap < bp }
                return stableOrder(a, b)
            }
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

    /// Suggestions, never what is due (that is always shown) nor what is planned for a later day.
    ///
    /// With no condition chosen they come by fixed tiers: due tomorrow, planned for today, ★, the next
    /// piece of something under way, then the rest, the longest untouched first. With a condition chosen,
    /// only tasks no heavier than it are offered, the heaviest first and by those tiers within each weight:
    /// on a good day the list starts with heavy work and, as things are passed over, comes down to lighter
    /// ones. A piece counts its parent's ★ and deadline as its own. No hidden score or cooldown.
    public func candidates(_ tasks: [TaskItem], energy: Energy, now: Date, limit: Int = 3) -> [Candidate] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A parent is done through its pieces, so the pieces are what is suggested.
        let parents = Set(tasks.compactMap(\.parentID))
        // Tasks in pieces already under way: their next pieces come before untouched ones.
        let underway = Set(tasks.filter { $0.isComplete }.compactMap(\.parentID))
        let wanted = energy.preferred
        let pool = tasks.filter { task in
            guard !task.isComplete, !task.isEvent, !parents.contains(task.id), !isObligation(task, now: now) else { return false }
            if let deferUntil = task.suggestionDeferredUntil, deferUntil > now { return false }
            if let planned = task.plannedAt, !isOnOrBeforeToday(planned, now: now) { return false }
            if let wanted, task.effort.rank > wanted.rank { return false }
            return true
        }
        func due(_ task: TaskItem) -> Date? { task.deadline ?? task.parentID.flatMap { byID[$0]?.deadline } }
        func must(_ task: TaskItem) -> Bool { task.isMust || (task.parentID.flatMap { byID[$0]?.isMust } ?? false) }
        func tier(_ task: TaskItem) -> Int {
            if let date = due(task), calendar.startOfDay(for: date) <= tomorrow { return 0 }
            if task.plannedAt.map({ calendar.isDate($0, inSameDayAs: now) }) == true { return 1 }
            if must(task) { return 2 }
            if let parent = task.parentID, underway.contains(parent) { return 3 }
            return 4
        }
        let ordered = pool.sorted { a, b in
            if wanted != nil, a.effort.rank != b.effort.rank { return a.effort.rank > b.effort.rank }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            let ad = a.lastStartedAt ?? a.createdAt, bd = b.lastStartedAt ?? b.createdAt
            if ad != bd { return ad < bd }
            return stableOrder(a, b)
        }
        return ordered.prefix(max(0, limit)).map { task in
            let reason: String
            let label: String
            switch tier(task) {
            case 0:
                // A piece of something due today is due today too.
                let date = calendar.startOfDay(for: due(task) ?? tomorrow)
                label = date < today ? "締切を過ぎた" : date == today ? "今日が締切" : "明日が締切"
                reason = label
            case 1: reason = "今日やる予定"; label = "今日の予定"
            case 2: reason = "落とせないもの（★必須）"; label = ""
            case 3: reason = "途中まで進んでいるタスクの続き"; label = "続き"
            default:
                reason = wanted == task.effort ? "今の調子に合う負荷" : "しばらく手をつけていないもの"
                // A task written down this week has not been waiting long.
                let untouched = now.timeIntervalSince(task.lastStartedAt ?? task.createdAt)
                label = untouched >= 7 * 24 * 3600 ? "しばらく手つかず" : ""
            }
            return Candidate(task: task, reason: reason, label: label, isMust: must(task))
        }
    }

    private func stableOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
