import Foundation

/// One thing the いま card can show, and why it is there.
public struct NowPick: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// Its time is now: a timed task, a routine or an event whose slot holds the present minute.
        case inSlot
        /// Must be done today: due today or earlier, or ★.
        case obligation
        /// A suggestion, in the order the Today screen uses.
        case candidate
        /// Nothing else is left today: the next timed thing.
        case upcoming
    }
    public var item: AgendaItem
    public var kind: Kind
    /// Why it is here, in a few words ("今日が締切", "★必須", "続き"). Empty when its time says enough.
    public var label: String
    /// The task this one is a piece of.
    public var parentID: UUID?
    public var id: String { item.id }

    public init(item: AgendaItem, kind: Kind, label: String, parentID: UUID? = nil) {
        self.item = item; self.kind = kind; self.label = label; self.parentID = parentID
    }
}

/// What the いま card offers, by the Today screen's own rules: what is happening now, then what must be
/// done today, then suggestions. Something set for a later time today waits for its time. Things passed
/// over with 入れ替える go to the back, in the order they were passed over; passing over changes no data.
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
        var picks: [NowPick] = []
        var seen = Set<String>()
        func add(_ pick: NowPick) {
            if seen.insert(pick.id).inserted { picks.append(pick) }
        }

        for item in open {
            guard let slot = item.slot, slot.start <= minute, minute < slot.end else { continue }
            add(NowPick(item: item, kind: .inSlot, label: timeLabel(item), parentID: parentID(of: item, in: book)))
        }
        for task in board.obligations(book.tasks, now: now) {
            let label = obligationLabel(task, now: now, calendar: calendar)
            if book.hasChildren(task.id) {
                // A task in pieces is done piece by piece; the next open piece stands for it.
                guard let piece = book.nextChild(of: task.id), !waits(piece) else { continue }
                add(NowPick(item: AgendaItem(task: piece), kind: .obligation, label: label, parentID: task.id))
            } else if !waits(task) {
                add(NowPick(item: AgendaItem(task: task), kind: .obligation, label: label))
            }
        }
        for candidate in board.candidates(book.tasks, energy: energy, now: now, limit: 50) where !waits(candidate.task) {
            add(NowPick(item: AgendaItem(task: candidate.task), kind: .candidate, label: candidate.label,
                        parentID: candidate.task.parentID))
        }
        if picks.isEmpty, let next = open.first(where: { ($0.slot?.start ?? -1) > minute }) {
            add(NowPick(item: next, kind: .upcoming, label: timeLabel(next), parentID: parentID(of: next, in: book)))
        }
        let rank = Dictionary(passed.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { _, last in last })
        let fresh = picks.filter { rank[$0.id] == nil }
        let later = picks.filter { rank[$0.id] != nil }.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        return fresh + later
    }

    /// The first thing the next day holds: its earliest timed item, or else something planned for it.
    public static func firstOfNextDay(after now: Date, in book: Notebook, calendar: Calendar = .current) -> AgendaItem? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return Agenda.items(on: next, tasks: book.tasks, routines: book.routines, calendar: calendar)
            .first { !$0.isDone && !$0.isBlock }
    }

    static func obligationLabel(_ task: TaskItem, now: Date, calendar: Calendar) -> String {
        if let due = task.deadline, calendar.startOfDay(for: due) <= calendar.startOfDay(for: now) {
            return calendar.isDate(due, inSameDayAs: now) ? "今日が締切" : "締切を過ぎた"
        }
        return "★必須"
    }

    /// For something on the schedule: what kind of thing it is, its time being shown beside it.
    static func timeLabel(_ item: AgendaItem) -> String {
        if item.isRoutine { return "ルーティン" }
        if item.isEvent { return "予定" }
        return item.isMust ? "★必須" : ""
    }

    static func parentID(of item: AgendaItem, in book: Notebook) -> UUID? {
        guard case .task(let id) = item.source else { return nil }
        return book.tasks.first { $0.id == id }?.parentID
    }
}
