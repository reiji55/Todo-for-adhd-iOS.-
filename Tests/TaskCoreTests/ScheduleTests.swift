import XCTest
@testable import TaskCore

final class ScheduleTests: XCTestCase {
    var calendar: Calendar!
    var friday: Date!
    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
    }
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: friday)! }

    func testTimeTextIsReadAndWrittenAsSlots() {
        XCTAssertEqual(TimeSlot.parse("19:00-20:30"), TimeSlot(start: 1140, duration: 90))
        XCTAssertEqual(TimeSlot.parse("7:00〜19:00")?.duration, 720)
        XCTAssertEqual(TimeSlot.parse("21:00-29:00")?.end, 29 * 60)
        XCTAssertEqual(TimeSlot.parse("9:30"), TimeSlot(start: 570, duration: 60))
        XCTAssertNil(TimeSlot.parse("終日"))
        XCTAssertNil(TimeSlot.parse("午前"))
        XCTAssertNil(TimeSlot.parse("20:00-19:00"))
        var task = TaskItem(title: "単語", scheduledTime: "午前")
        XCTAssertNil(task.slot)
        task.slot = TimeSlot(start: 1155, duration: 45)
        XCTAssertEqual(task.scheduledTime, "19:15-20:00")
        task.slot = nil
        XCTAssertEqual(task.scheduledTime, "")
    }

    func testRoutinesJoinTasksInTimeOrderOnTheirWeekdays() {
        let study = Routine(title: "TOEIC", weekdays: [2, 3, 4, 5, 6], time: "19:00-20:30", createdAt: day(-30))
        let sleep = Routine(title: "睡眠", time: "0:00-6:00", isBlock: true, createdAt: day(-30))
        let task = TaskItem(title: "電話", plannedAt: friday, scheduledTime: "10:00-10:30")
        let untimed = TaskItem(title: "買い物", plannedAt: friday)
        let items = Agenda.items(on: friday, tasks: [untimed, task], routines: [study, sleep], calendar: calendar)
        XCTAssertEqual(items.map(\.title), ["睡眠", "電話", "TOEIC", "買い物"])
        // Saturday: weekday-only routine drops out.
        XCTAssertEqual(Agenda.items(on: day(1), tasks: [], routines: [study, sleep], calendar: calendar).map(\.title), ["睡眠"])
    }

    func testRoutineDoesNotAppearBeforeItWasCreated() {
        let routine = Routine(title: "新習慣", createdAt: day(2))
        XCTAssertTrue(Agenda.items(on: friday, tasks: [], routines: [routine], calendar: calendar).isEmpty)
        XCTAssertEqual(Agenda.items(on: day(2), tasks: [], routines: [routine], calendar: calendar).count, 1)
    }

    func testMovingOneDayOfARoutineLeavesOtherDaysAlone() {
        var book = Notebook(routines: [Routine(title: "TOEIC", time: "19:00-20:30", createdAt: day(-30))])
        let id = book.routines[0].id
        let friKey = DayKey.of(friday, calendar: calendar), satKey = DayKey.of(day(1), calendar: calendar)
        book.moveRoutine(id, originalDay: friKey, toDay: satKey, time: "9:00-10:30")
        let fri = Agenda.items(on: friday, tasks: [], routines: book.routines, calendar: calendar)
        let sat = Agenda.items(on: day(1), tasks: [], routines: book.routines, calendar: calendar)
        XCTAssertTrue(fri.isEmpty)
        XCTAssertEqual(sat.map { $0.slot?.startLabel }, ["9:00", "19:00"])
        XCTAssertEqual(Agenda.items(on: day(2), tasks: [], routines: book.routines, calendar: calendar).first?.slot?.startLabel, "19:00")

        // Checking the moved day marks its original day, so Saturday's own occurrence stays open.
        book.toggleRoutine(id, originalDay: friKey)
        let after = Agenda.items(on: day(1), tasks: [], routines: book.routines, calendar: calendar)
        XCTAssertEqual(after.map(\.isDone), [true, false])

        // Moving it back to its own day and time removes the move.
        book.moveRoutine(id, originalDay: friKey, toDay: friKey, time: "19:00-20:30")
        XCTAssertTrue(book.routines[0].moves.isEmpty)
        // A time change on the same day is a move that stays put.
        book.moveRoutine(id, originalDay: friKey, toDay: friKey, time: "21:00-22:30")
        XCTAssertEqual(Agenda.items(on: friday, tasks: [], routines: book.routines, calendar: calendar).first?.slot?.startLabel, "21:00")
    }

    func testBlocksCannotBeCheckedOff() {
        var book = Notebook(routines: [Routine(title: "仕事", time: "7:00-19:00", isBlock: true, createdAt: day(-1))])
        book.toggleRoutine(book.routines[0].id, originalDay: DayKey.of(friday, calendar: calendar))
        XCTAssertTrue(book.routines[0].doneDays.isEmpty)
    }

    func testMovingATaskKeepsItsDeadline() {
        var book = Notebook(tasks: [TaskItem(title: "提出", plannedAt: friday, scheduledTime: "10:00-11:00", deadline: day(3))])
        book.moveTask(book.tasks[0].id, to: day(1), slot: TimeSlot(start: 13 * 60, duration: 60))
        XCTAssertTrue(calendar.isDate(book.tasks[0].plannedAt!, inSameDayAs: day(1)))
        XCTAssertEqual(book.tasks[0].scheduledTime, "13:00-14:00")
        XCTAssertEqual(book.tasks[0].deadline, day(3))
    }

    func testRoutineDaysSyncIndependently() throws {
        let routine = Routine(title: "TOEIC", time: "19:00-20:30", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let base = Notebook(routines: [routine])
        var phone = SyncReplica()
        try phone.apply(before: Notebook(), after: base, device: "phone")
        var pad = SyncReplica()
        try pad.merge(Array(phone.records.values))

        var onPhone = base; onPhone.toggleRoutine(routine.id, originalDay: "2026-10-29")
        try phone.apply(before: base, after: onPhone, device: "phone")
        var onPad = base
        onPad.toggleRoutine(routine.id, originalDay: "2026-10-30")
        onPad.moveRoutine(routine.id, originalDay: "2026-10-31", toDay: "2026-11-01", time: "9:00-10:30")
        try pad.apply(before: base, after: onPad, device: "pad")

        try phone.merge(Array(pad.records.values))
        try pad.merge(Array(phone.records.values))
        let merged = try phone.materialize()
        XCTAssertEqual(merged, try pad.materialize())
        XCTAssertEqual(merged.routines[0].doneDays, ["2026-10-29", "2026-10-30"])
        XCTAssertEqual(merged.routines[0].moves["2026-10-31"], RoutineMove(toDay: "2026-11-01", time: "9:00-10:30"))

        // Unchecking removes the day everywhere.
        var unchecked = merged; unchecked.toggleRoutine(routine.id, originalDay: "2026-10-29")
        try phone.apply(before: merged, after: unchecked, device: "phone")
        XCTAssertEqual(try phone.materialize().routines[0].doneDays, ["2026-10-30"])
    }

    func testOlderTasksWithKindStillLoadAndNotifyDefaultsOn() throws {
        let json = """
        {"version": 1, "tasks": [{"id": "00000000-0000-0000-0000-000000000001", "title": "古い", "kind": "ルーチン",
          "scheduledTime": "19:00-20:30", "createdAt": "2026-10-01T00:00:00Z"}]}
        """
        let book = try NotebookCodec.decode(Data(json.utf8))
        XCTAssertTrue(book.tasks[0].notify)
        XCTAssertEqual(book.tasks[0].slot?.start, 1140)
        XCTAssertTrue(book.routines.isEmpty)
    }

    func testHourRangeFitsContent() {
        let night = AgendaItem(source: .task(UUID()), title: "夜勤", project: "", slot: TimeSlot(start: 21 * 60, duration: 8 * 60),
                               isDone: false, isMust: false, isBlock: false)
        XCTAssertEqual(Agenda.hourRange(for: []), 6...24)
        XCTAssertEqual(Agenda.hourRange(for: [night]), 6...30)
    }

    func testRemindersSkipDoneBlockedAndOptedOutItems() {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
        let call = TaskItem(title: "電話", plannedAt: friday, scheduledTime: "10:00-10:30", createdAt: day(-1))
        let quiet = TaskItem(title: "静かに", plannedAt: friday, scheduledTime: "11:00-11:30", createdAt: day(-1), notify: false)
        let past = TaskItem(title: "もう過ぎた", plannedAt: friday, scheduledTime: "8:00-8:30", createdAt: day(-1))
        let due = TaskItem(title: "提出", deadline: day(1), createdAt: day(-1))
        let study = Routine(title: "TOEIC", weekdays: [2, 3, 4, 5, 6], time: "19:00-20:30", createdAt: day(-30))
        let sleep = Routine(title: "睡眠", time: "0:00-6:00", isBlock: true, createdAt: day(-30))
        var book = Notebook(tasks: [call, quiet, past, due], routines: [study, sleep])
        book.toggleRoutine(study.id, originalDay: DayKey.of(friday, calendar: calendar))

        // Friday to Monday: Friday's study is already done, the weekend has none, Monday's is announced.
        let plan = ReminderPlan.requests(for: book, now: morning, options: ReminderOptions(leadMinutes: 5), days: 4, calendar: calendar)
        XCTAssertEqual(plan.map(\.title), ["電話", "提出", "TOEIC"])
        XCTAssertEqual(plan[0].date, calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9, minute: 55)))
        XCTAssertEqual(plan[0].body, "5分後 10:00-10:30")
        XCTAssertEqual(plan[1].body, "今日が締切です")
        XCTAssertEqual(calendar.component(.weekday, from: plan[2].date), 2)
        XCTAssertEqual(plan[2].body, "5分後 19:00-20:30・ルーティン")

        let off = ReminderPlan.requests(for: book, now: morning,
                                        options: ReminderOptions(tasks: false, routines: false, deadlines: false), days: 4, calendar: calendar)
        XCTAssertTrue(off.isEmpty)
    }

    func testPlainTextReadsWithoutTheApp() {
        let study = Routine(title: "金フレ", project: "TOEIC", weekdays: [6], time: "19:00-20:30", createdAt: day(-30))
        let call = TaskItem(title: "電話", plannedAt: friday, isMust: true, handoff: "番号を調べて", createdAt: day(-1))
        let left = TaskItem(title: "返却", plannedAt: day(-2), createdAt: day(-3))
        let text = PlainText.today(friday, book: Notebook(tasks: [call, left], routines: [study]), calendar: calendar)
        XCTAssertTrue(text.hasPrefix("10月30日(金)\n[ ] 19:00-20:30 金フレ〔ルーティン・TOEIC〕\n[ ] 時間未定 電話〔必須〕"), text)
        XCTAssertTrue(text.contains("AIへの引き継ぎ：番号を調べて"))
        XCTAssertTrue(text.contains("前の日から残っているもの\n[ ] 10月28日(水) 返却"))
    }
}
