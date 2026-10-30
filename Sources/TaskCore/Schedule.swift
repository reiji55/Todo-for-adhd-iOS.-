import Foundation

/// A start time and length within a day, in minutes from midnight. It may run past midnight
/// (a 21:00–29:00 night shift ends at "29:00", as in task-3days).
public struct TimeSlot: Equatable, Hashable {
    public var start: Int
    public var duration: Int
    public init(start: Int, duration: Int) {
        self.start = max(0, min(start, 24 * 60 - 1))
        self.duration = max(5, min(duration, 24 * 60))
    }
    public var end: Int { start + duration }

    /// Stored form shared with tasks.txt and older app versions: "19:00-20:30".
    public var label: String { "\(Self.clock(start))-\(Self.clock(end))" }
    public var startLabel: String { Self.clock(start) }

    public static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Reads "19:00-20:30", "19:00〜20:30" or a bare "9:00" (one hour). Anything else ("終日", "午前") is no slot.
    public static func parse(_ text: String) -> TimeSlot? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { "-–~〜".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let start = minutes(parts[0]), start < 24 * 60 else { return nil }
        guard parts.count == 2 else { return TimeSlot(start: start, duration: 60) }
        guard let end = minutes(parts[1]), end > start else { return nil }
        return TimeSlot(start: start, duration: end - start)
    }

    private static func minutes(_ text: String) -> Int? {
        let fields = text.split(separator: ":")
        guard fields.count == 2, let h = Int(fields[0]), let m = Int(fields[1]),
              (0..<48).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

public extension TaskItem {
    /// Structured view of `scheduledTime`. Setting it rewrites the stored text, so clearing a time
    /// always wins over an older synced value.
    var slot: TimeSlot? {
        get { TimeSlot.parse(scheduledTime) }
        set { scheduledTime = newValue?.label ?? "" }
    }
}

/// A calendar day as "2026-10-30" in the device's calendar, used as a stable key for routine days.
public enum DayKey {
    public static func of(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let f = key.split(separator: "-").compactMap { Int($0) }
        guard f.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: f[0], month: f[1], day: f[2], hour: 12))
    }
}

/// One routine moved for a single day, e.g. Tuesday's 19:00 study done at 21:00 on Wednesday.
public struct RoutineMove: Codable, Equatable, Hashable {
    public var toDay: String
    /// "" keeps no fixed time on that day.
    public var time: String
    public init(toDay: String, time: String) { self.toDay = toDay; self.time = time }
}

/// Something done on a schedule. Shown beside tasks in the same rows, but defined once.
public struct Routine: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var project: String
    public var memo: String
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    public var weekdays: [Int]
    /// Same text form as a task's time: "19:00-20:30", or "" for any time that day.
    public var time: String
    public var notify: Bool
    /// Time held for something else (sleep, work). Shown hatched; never checked off or announced.
    public var isBlock: Bool
    public var isPaused: Bool
    public var createdAt: Date
    /// Days (DayKey of the original day) marked done.
    public var doneDays: [String]
    /// Keyed by the original day.
    public var moves: [String: RoutineMove]

    public init(id: UUID = UUID(), title: String, project: String = "", memo: String = "",
                weekdays: [Int] = Array(1...7), time: String = "", notify: Bool = true, isBlock: Bool = false,
                isPaused: Bool = false, createdAt: Date = Date(), doneDays: [String] = [], moves: [String: RoutineMove] = [:]) {
        self.id = id; self.title = title; self.project = project; self.memo = memo
        self.weekdays = weekdays; self.time = time; self.notify = notify; self.isBlock = isBlock
        self.isPaused = isPaused; self.createdAt = createdAt; self.doneDays = doneDays; self.moves = moves
    }

    public var slot: TimeSlot? {
        get { TimeSlot.parse(time) }
        set { time = newValue?.label ?? "" }
    }

    /// "毎日", "平日", "月・水・金".
    public var weekdayLabel: String {
        let set = Set(weekdays)
        if set == Set(1...7) { return "毎日" }
        if set == Set(2...6) { return "平日" }
        if set == [1, 7] { return "土日" }
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        return [2, 3, 4, 5, 6, 7, 1].filter(set.contains).map { names[$0 - 1] }.joined(separator: "・")
    }
}

extension Routine {
    enum CodingKeys: String, CodingKey {
        case id, title, project, memo, weekdays, time, notify, isBlock, isPaused, createdAt, doneDays, moves
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  project: try text(.project), memo: try text(.memo),
                  weekdays: try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? Array(1...7),
                  time: try text(.time), notify: try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true,
                  isBlock: try c.decodeIfPresent(Bool.self, forKey: .isBlock) ?? false,
                  isPaused: try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
                  createdAt: try c.decode(Date.self, forKey: .createdAt),
                  doneDays: try c.decodeIfPresent([String].self, forKey: .doneDays) ?? [],
                  moves: try c.decodeIfPresent([String: RoutineMove].self, forKey: .moves) ?? [:])
    }
}

/// A task or one day of a routine, as one row in the agenda and one block on the week grid.
public struct AgendaItem: Identifiable, Equatable {
    public enum Source: Equatable {
        case task(UUID)
        /// The routine and the day it is originally scheduled (the key for done and moves).
        case routine(UUID, originalDay: String)
    }
    public var source: Source
    public var title: String
    public var project: String
    public var slot: TimeSlot?
    public var isDone: Bool
    public var isMust: Bool
    public var isBlock: Bool
    public var id: String {
        switch source {
        case .task(let id): return "task-\(id.uuidString)"
        case .routine(let id, let day): return "routine-\(id.uuidString)-\(day)"
        }
    }
    public var isRoutine: Bool { if case .routine = source { return true } else { return false } }
}

public enum Agenda {
    /// Tasks planned for the day plus routines that fall on it (after moves), timed ones first by start.
    /// Completed tasks are included so the person can see and undo them; callers filter when needed.
    public static func items(on day: Date, tasks: [TaskItem], routines: [Routine], calendar: Calendar = .current) -> [AgendaItem] {
        let key = DayKey.of(day, calendar: calendar)
        var result = tasks.filter { $0.plannedAt.map { calendar.isDate($0, inSameDayAs: day) } == true }.map { task in
            AgendaItem(source: .task(task.id), title: task.title, project: task.project, slot: task.slot,
                       isDone: task.isComplete, isMust: task.isMust, isBlock: false)
        }
        for routine in routines where !routine.isPaused {
            for original in occurrenceDays(of: routine, landingOn: key, near: day, calendar: calendar) {
                let move = routine.moves[original]
                result.append(AgendaItem(source: .routine(routine.id, originalDay: original), title: routine.title,
                                         project: routine.project, slot: TimeSlot.parse(move?.time ?? routine.time),
                                         isDone: routine.doneDays.contains(original), isMust: false, isBlock: routine.isBlock))
            }
        }
        return result.sorted(by: order)
    }

    /// Original days whose occurrence ends up on `key`: the day itself unless moved away, plus days moved here.
    static func occurrenceDays(of routine: Routine, landingOn key: String, near day: Date, calendar: Calendar) -> [String] {
        var days: [String] = []
        let weekday = calendar.component(.weekday, from: day)
        let started = calendar.startOfDay(for: routine.createdAt) <= calendar.startOfDay(for: day)
        if started, routine.weekdays.contains(weekday), routine.moves[key] == nil { days.append(key) }
        days += routine.moves.filter { $0.value.toDay == key && $0.key != key }.map(\.key).sorted()
        if let stay = routine.moves[key], stay.toDay == key { days.append(key) }
        return days
    }

    static func order(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        switch (a.slot, b.slot) {
        case let (x?, y?) where x.start != y.start: return x.start < y.start
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            if a.isMust != b.isMust { return a.isMust }
            return a.id < b.id
        }
    }

    /// Default grid hours for a set of items: content ±1 hour, at least 6:00–24:00.
    public static func hourRange(for items: [AgendaItem]) -> ClosedRange<Int> {
        let slots = items.compactMap(\.slot)
        guard let earliest = slots.map(\.start).min(), let latest = slots.map(\.end).max() else { return 6...24 }
        let first = min(6, earliest / 60 - 1)
        let last = max(24, Int((Double(latest) / 60).rounded(.up)) + 1)
        return max(0, first)...min(30, last)
    }
}

public extension Notebook {
    /// Moves one day of a routine; moving it back to its own day at its usual time clears the move.
    mutating func moveRoutine(_ id: UUID, originalDay: String, toDay: String, time: String) {
        guard let i = routines.firstIndex(where: { $0.id == id }) else { return }
        if toDay == originalDay && time == routines[i].time { routines[i].moves[originalDay] = nil }
        else { routines[i].moves[originalDay] = RoutineMove(toDay: toDay, time: time) }
    }

    mutating func toggleRoutine(_ id: UUID, originalDay: String) {
        guard let i = routines.firstIndex(where: { $0.id == id }), !routines[i].isBlock else { return }
        if let j = routines[i].doneDays.firstIndex(of: originalDay) { routines[i].doneDays.remove(at: j) }
        else { routines[i].doneDays.append(originalDay) }
    }

    /// Moves a task to a day and time, keeping any deadline as it is.
    mutating func moveTask(_ id: UUID, to day: Date, slot: TimeSlot?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].plannedAt = day
        tasks[i].slot = slot
    }
}
