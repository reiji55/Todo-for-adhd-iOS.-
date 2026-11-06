import Foundation

/// One thing the いま card can show, and why it is there.
public struct NowPick: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// Its time is now: a timed task, a routine or an event whose slot holds the present minute.
        case inSlot
        /// Must be done today: due today or earlier.
        case obligation
        /// A suggestion, in the order the Today screen uses.
        case candidate
        /// Nothing else is left today: the next timed thing.
        case upcoming
    }
    public var item: AgendaItem
    public var kind: Kind
    /// Why it is here, in a few words ("今日が締切", "続き"). Empty when its time says enough.
    public var label: String
    /// The task this one is a piece of.
    public var parentID: UUID?
    /// ★ on it, or on the task it is a piece of.
    public var isMust: Bool
    public var id: String { item.id }

    public init(item: AgendaItem, kind: Kind, label: String, parentID: UUID? = nil, isMust: Bool = false) {
        self.item = item; self.kind = kind; self.label = label; self.parentID = parentID; self.isMust = isMust
    }
}

/// The time between things on today's schedule, when nothing is set for now.
public struct FreeStretch: Equatable {
    /// Sleep or work holding this time, when it does.
    public var held: AgendaItem?
    /// The next thing on today's schedule not done yet; nil when nothing more is on today.
    public var next: AgendaItem?
    /// Minute of the day the stretch ends: the end of what holds it, else the start of the next thing.
    public var until: Int?
    /// Names the stretch. A condition chosen in it holds until it ends; the next free stretch asks again.
    public var key: String
}

/// What the いま card offers, by the Today screen's own rules: what is happening now, then what is due
/// today, then suggestions. Something set for a later time today waits for its time. Things passed
/// over with 入れ替える go to the back, in the order they were passed over; passing over changes no data.
/// Once everything has been passed over, the order is the original one again: the round starts over.
public enum NowPlan {
    public static func picks(in book: Notebook, energy: Energy, now: Date, passed: [String] = [],
                             calendar: Calendar = .current) -> [NowPick] {
        let board = TaskBoard(calendar: calendar)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let open = Agenda.items(on: now, tasks: book.tasks, routines: book.routines, calendar: calendar)
            .filter { !$0.isDone && !$0.isBlock }
        // Set for later today at a time: it comes up when its time does.
        func waits(_ task: TaskItem) -> Bool {
            guard let day = task.plannedAt, calendar.isDate(day, inSameDayAs: now), let slot = task.slot else { return false }
            return slot.start > minute
        }
        func must(_ item: AgendaItem) -> Bool {
            guard case .task(let id) = item.source, let task = book.tasks.first(where: { $0.id == id }) else { return false }
            return board.isMust(task, among: book.tasks)
        }
        var picks: [NowPick] = []
        var seen = Set<String>()
        func add(_ pick: NowPick) {
            if seen.insert(pick.id).inserted { picks.append(pick) }
        }

        for item in open {
            guard let slot = item.slot, slot.start <= minute, minute < slot.end else { continue }
            add(NowPick(item: item, kind: .inSlot, label: timeLabel(item), parentID: parentID(of: item, in: book), isMust: must(item)))
        }
        for task in board.obligations(book.tasks, now: now) {
            let label = obligationLabel(task, now: now, calendar: calendar)
            if book.hasChildren(task.id) {
                // A task in pieces is done piece by piece; the next open piece stands for it.
                guard let piece = book.nextChild(of: task.id), !waits(piece) else { continue }
                add(NowPick(item: AgendaItem(task: piece), kind: .obligation, label: label, parentID: task.id, isMust: task.isMust))
            } else if !waits(task) {
                add(NowPick(item: AgendaItem(task: task), kind: .obligation, label: label, isMust: task.isMust))
            }
        }
        for candidate in board.candidates(book.tasks, energy: energy, now: now, limit: 50) where !waits(candidate.task) {
            add(NowPick(item: AgendaItem(task: candidate.task), kind: .candidate, label: candidate.label,
                        parentID: candidate.task.parentID, isMust: candidate.isMust))
        }
        if picks.isEmpty, let next = open.first(where: { ($0.slot?.start ?? -1) > minute }) {
            add(NowPick(item: next, kind: .upcoming, label: timeLabel(next), parentID: parentID(of: next, in: book), isMust: must(next)))
        }
        let rank = Dictionary(passed.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { _, last in last })
        let fresh = picks.filter { rank[$0.id] == nil }
        let later = picks.filter { rank[$0.id] != nil }.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        return fresh + later
    }

    /// Where now falls when nothing is in its time: a free stretch, or time held for sleep or work.
    /// Nil while something on the schedule (not done yet) holds the present minute.
    public static func freeStretch(in book: Notebook, now: Date, calendar: Calendar = .current) -> FreeStretch? {
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let items = Agenda.items(on: now, tasks: book.tasks, routines: book.routines, calendar: calendar)
        let covering = items.filter { item in
            guard let slot = item.slot else { return false }
            return slot.start <= minute && minute < slot.end
        }
        if covering.contains(where: { !$0.isBlock && !$0.isDone }) { return nil }
        let day = DayKey.of(now, calendar: calendar)
        let next = items.first { !$0.isDone && ($0.slot?.start ?? -1) > minute }
        if let held = covering.first(where: \.isBlock), let slot = held.slot {
            return FreeStretch(held: held, next: next, until: slot.end, key: "\(day)-held-\(held.id)")
        }
        let until = next?.slot?.start
        return FreeStretch(held: nil, next: next, until: until, key: "\(day)-free-\(until ?? 24 * 60)")
    }

    /// The first thing the next day holds: its earliest timed item, or else something planned for it.
    public static func firstOfNextDay(after now: Date, in book: Notebook, calendar: Calendar = .current) -> AgendaItem? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return Agenda.items(on: next, tasks: book.tasks, routines: book.routines, calendar: calendar)
            .first { !$0.isDone && !$0.isBlock }
    }

    static func obligationLabel(_ task: TaskItem, now: Date, calendar: Calendar) -> String {
        guard let due = task.deadline else { return "" }
        return calendar.isDate(due, inSameDayAs: now) ? "今日が締切" : "締切を過ぎた"
    }

    /// For something on the schedule: what kind of thing it is, its time being shown beside it.
    static func timeLabel(_ item: AgendaItem) -> String {
        if item.isRoutine { return "ルーティン" }
        if item.isEvent { return "予定" }
        return ""
    }

    static func parentID(of item: AgendaItem, in book: Notebook) -> UUID? {
        guard case .task(let id) = item.source else { return nil }
        return book.tasks.first { $0.id == id }?.parentID
    }
}
