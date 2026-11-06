import XCTest
@testable import TaskCore

final class NowPlanTests: XCTestCase {
    var calendar: Calendar!
    var friday: Date!
    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
    }
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: friday)! }
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: hour, minute: minute))!
    }

    func testWhatIsHappeningNowComesFirstThenWhatIsDueThenSuggestions() {
        let call = TaskItem(title: "電話", plannedAt: friday, scheduledTime: "14:00-14:15", createdAt: day(-1))
        let address = TaskItem(title: "宛先を確認", isMust: true, createdAt: day(-1))
        let headings = TaskItem(title: "見出し", plannedAt: friday, scheduledTime: "15:00-16:00", createdAt: day(-1))
        let boxes = TaskItem(title: "段ボール", createdAt: day(-1))
        let lunch = TaskItem(title: "ランチ", plannedAt: friday, scheduledTime: "12:00-13:30", createdAt: day(-2), isEvent: true)
        let book = Notebook(tasks: [boxes, headings, address, call, lunch])

        let picks = NowPlan.picks(in: book, energy: .any, now: at(14, 5), calendar: calendar)
        XCTAssertEqual(picks.map(\.item.title), ["電話", "宛先を確認", "段ボール"], "見出し waits for 15:00; the lunch is over")
        XCTAssertEqual(picks.map(\.kind), [.inSlot, .candidate, .candidate], "★ alone is not due today")
        XCTAssertEqual(picks.map(\.label), ["", "", ""])
        XCTAssertEqual(picks.map(\.isMust), [false, true, false])

        // A timed task not done by its end stays as part of today's plan, ahead of ★.
        let later = NowPlan.picks(in: book, energy: .any, now: at(15, 10), calendar: calendar)
        XCTAssertEqual(later.map(\.item.title), ["見出し", "電話", "宛先を確認", "段ボール"])
        XCTAssertEqual(later.map(\.label), ["", "今日の予定", "", ""])
    }

    func testAPieceStandsForItsTaskAndPassingOverSendsThingsToTheBack() {
        let proposal = TaskItem(title: "提案書", deadline: friday, createdAt: day(-3))
        let outline = TaskItem(title: "見出し", createdAt: day(-3), completedAt: day(-1), parentID: proposal.id, rank: 0)
        let draft = TaskItem(title: "本文", createdAt: day(-3), parentID: proposal.id, rank: 1)
        let figures = TaskItem(title: "図", createdAt: day(-2), parentID: proposal.id, rank: 2)
        let boxes = TaskItem(title: "段ボール", createdAt: day(-1))
        let book = Notebook(tasks: [proposal, outline, draft, figures, boxes])
        let now = at(16, 20)

        let picks = NowPlan.picks(in: book, energy: .any, now: now, calendar: calendar)
        XCTAssertEqual(picks.map(\.item.title), ["本文", "図", "段ボール"])
        XCTAssertEqual(picks.map(\.label), ["今日が締切", "今日が締切", ""], "every piece of what is due today is due today")
        XCTAssertEqual(picks.map(\.parentID), [proposal.id, proposal.id, nil])

        let once = NowPlan.picks(in: book, energy: .any, now: now, passed: [AgendaItem(task: draft).id], calendar: calendar)
        XCTAssertEqual(once.map(\.item.title), ["図", "段ボール", "本文"])
        let twice = NowPlan.picks(in: book, energy: .any, now: now,
                                  passed: [AgendaItem(task: draft).id, AgendaItem(task: figures).id], calendar: calendar)
        XCTAssertEqual(twice.map(\.item.title), ["段ボール", "本文", "図"])
    }

    func testWithNothingLeftTheNextTimedThingIsOffered() {
        let study = Routine(title: "金フレ", weekdays: [6], time: "19:00-20:30", createdAt: day(-30))
        let sleep = Routine(title: "睡眠", time: "0:00-7:00", isBlock: true, createdAt: day(-30))
        let book = Notebook(routines: [study, sleep])

        let picks = NowPlan.picks(in: book, energy: .any, now: at(16, 40), calendar: calendar)
        XCTAssertEqual(picks.map(\.item.title), ["金フレ"])
        XCTAssertEqual(picks.first?.kind, .upcoming)
        XCTAssertEqual(picks.first?.label, "ルーティン")
        XCTAssertEqual(NowPlan.picks(in: book, energy: .any, now: at(19, 5), calendar: calendar).first?.kind, .inSlot)
        XCTAssertTrue(NowPlan.picks(in: book, energy: .any, now: at(21), calendar: calendar).isEmpty)
    }

    func testAConditionStartsFromTheHeaviestAndARoundStartsOver() {
        let report = TaskItem(title: "設計", effort: .heavy, createdAt: day(-5))
        let slides = TaskItem(title: "資料", effort: .medium, createdAt: day(-4))
        let call = TaskItem(title: "電話", effort: .light, createdAt: day(-3))
        let pay = TaskItem(title: "支払い", deadline: friday, effort: .heavy, createdAt: day(-2))
        let book = Notebook(tasks: [call, slides, report, pay])
        let now = at(10)
        func titles(_ energy: Energy, _ passed: [TaskItem] = []) -> [String] {
            NowPlan.picks(in: book, energy: energy, now: now, passed: passed.map { AgendaItem(task: $0).id }, calendar: calendar)
                .map(\.item.title)
        }
        XCTAssertEqual(titles(.high), ["支払い", "設計", "資料", "電話"], "what is due today comes first whatever the condition")
        XCTAssertEqual(titles(.normal), ["支払い", "資料", "電話"])
        XCTAssertEqual(titles(.low), ["支払い", "電話"])
        XCTAssertEqual(titles(.high, [pay, report]), ["資料", "電話", "支払い", "設計"], "passing over comes down to lighter ones")
        XCTAssertEqual(titles(.high, [pay, report, slides, call]), titles(.high), "once all are passed over, it starts over")
    }

    func testAFreeStretchRunsToTheNextThingAndHeldTimeIsNotFree() {
        let lunch = TaskItem(title: "ランチ", plannedAt: friday, scheduledTime: "12:00-13:30", createdAt: day(-2), isEvent: true)
        var call = TaskItem(title: "電話", plannedAt: friday, scheduledTime: "14:00-14:15", createdAt: day(-1))
        let sleep = Routine(title: "睡眠", time: "0:00-7:00", isBlock: true, createdAt: day(-30))
        var book = Notebook(tasks: [lunch, call], routines: [sleep])

        let morning = NowPlan.freeStretch(in: book, now: at(9), calendar: calendar)
        XCTAssertNil(morning?.held)
        XCTAssertEqual(morning?.until, 12 * 60)
        XCTAssertEqual(morning?.next?.title, "ランチ")
        XCTAssertEqual(morning?.key, NowPlan.freeStretch(in: book, now: at(11, 50), calendar: calendar)?.key, "one stretch, one key")
        XCTAssertNil(NowPlan.freeStretch(in: book, now: at(12, 30), calendar: calendar), "lunch is on now")
        XCTAssertEqual(NowPlan.freeStretch(in: book, now: at(6), calendar: calendar)?.held?.title, "睡眠")
        XCTAssertEqual(NowPlan.freeStretch(in: book, now: at(6), calendar: calendar)?.until, 7 * 60)
        XCTAssertNotEqual(NowPlan.freeStretch(in: book, now: at(13, 40), calendar: calendar)?.key, morning?.key)

        call.completedAt = at(13, 50)
        book = Notebook(tasks: [lunch, call], routines: [sleep])
        let afterCall = NowPlan.freeStretch(in: book, now: at(14, 5), calendar: calendar)
        XCTAssertNotNil(afterCall, "a thing done early frees its time")
        XCTAssertNil(afterCall?.until, "nothing more today")
    }

    func testTheNextDaysFirstThingIsItsEarliestTimedItem() {
        let tidy = TaskItem(title: "掃除", plannedAt: day(1), createdAt: day(-1))
        let dentist = TaskItem(title: "歯医者", plannedAt: day(1), scheduledTime: "10:00-11:00", createdAt: day(-1), isEvent: true)
        let book = Notebook(tasks: [tidy, dentist])
        XCTAssertEqual(NowPlan.firstOfNextDay(after: at(21), in: book, calendar: calendar)?.title, "歯医者")
        XCTAssertNil(NowPlan.firstOfNextDay(after: day(1), in: book, calendar: calendar))
    }

    func testEndingTheDayQuietsItsTasksAndRoutinesButNotItsEvents() {
        let call = TaskItem(title: "電話", plannedAt: friday, scheduledTime: "15:00-15:30", createdAt: day(-1))
        let dinner = TaskItem(title: "食事会", plannedAt: friday, scheduledTime: "18:00-20:00", createdAt: day(-1), isEvent: true)
        let due = TaskItem(title: "提出", deadline: day(1), createdAt: day(-1))
        let study = Routine(title: "TOEIC", weekdays: [6, 7], time: "19:00-20:30", createdAt: day(-30))
        let book = Notebook(tasks: [call, dinner, due], routines: [study])
        let now = at(14)

        let open = ReminderPlan.requests(for: book, now: now, options: ReminderOptions(), days: 2, calendar: calendar)
        XCTAssertEqual(open.map(\.title), ["電話", "食事会", "TOEIC", "提出", "TOEIC"])
        let closed = ReminderPlan.requests(for: book, now: now,
                                           options: ReminderOptions(closedDay: DayKey.of(friday, calendar: calendar)),
                                           days: 2, calendar: calendar)
        XCTAssertEqual(closed.map(\.title), ["食事会", "提出", "TOEIC"], "the next day rings as usual")
    }
}
