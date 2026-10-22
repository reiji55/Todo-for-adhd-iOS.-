import XCTest
@testable import TaskCore

final class TaskBoardTests: XCTestCase {
    var calendar: Calendar!
    var board: TaskBoard!
    var now: Date!
    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        board = TaskBoard(calendar: calendar)
        now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
    }
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    func testMustAndDeadlineCannotBeHiddenByEnergyOrDeferral() {
        let must = TaskItem(title: "提出", plannedAt: now, isMust: true, effort: .heavy,
                            suggestionDeferredUntil: day(3))
        let overdue = TaskItem(title: "支払い", deadline: day(-1), effort: .heavy)
        let light = TaskItem(title: "紙を整理", effort: .light)
        let all = [must, overdue, light]
        XCTAssertEqual(Set(board.obligations(all, now: now).map(\.id)), Set([must.id, overdue.id]))
        for energy in Energy.allCases {
            XCTAssertEqual(board.candidates(all, energy: energy, now: now).map(\.id), [light.id])
            XCTAssertEqual(board.obligations(all, now: now).count, 2)
        }
    }

    func testFutureMustAppearsOnPlannedDayNotToday() {
        let task = TaskItem(title: "明日の必須", plannedAt: day(1), isMust: true)
        XCTAssertFalse(board.isObligation(task, now: now))
        XCTAssertTrue(board.isObligation(task, now: day(1)))
        XCTAssertTrue(board.isObligation(task, now: day(2)))
        XCTAssertEqual(board.scheduled([task], for: day(1)).count, 1)
    }

    func testPastDeadlineOverridesFuturePlan() {
        let task = TaskItem(title: "日程矛盾", plannedAt: day(3), deadline: day(-1))
        XCTAssertTrue(board.isObligation(task, now: now))
    }

    func testTaskWithNoStepsCanBeSuggestedAndStarted() {
        let task = TaskItem(title: "電話をかける")
        XCTAssertEqual(task.actionTitle, task.title)
        XCTAssertEqual(board.candidates([task], energy: .low, now: now).map(\.id), [task.id])
    }

    func testSuggestionOrderExplainsPriorityAndExcludesFuturePlan() {
        let continuation = TaskItem(title: "続き", resumeNote: "3行目まで", createdAt: day(-5))
        let plan = TaskItem(title: "今日", plannedAt: now)
        let due = TaskItem(title: "明日締切", deadline: day(1), effort: .heavy)
        let future = TaskItem(title: "来週", plannedAt: day(7))
        let casual = TaskItem(title: "日付なし", effort: .light, createdAt: day(-30))
        let candidates = board.candidates([casual, future, continuation, plan, due], energy: .low, now: now)
        XCTAssertEqual(candidates.map(\.id), [due.id, plan.id, continuation.id])
        XCTAssertEqual(candidates.map(\.reason), ["明日が締切", "今日やる予定", "続きのメモがあります"])
    }

    func testEnergyOnlyReordersWithinSamePriority() {
        let heavy = TaskItem(title: "設計", effort: .heavy, createdAt: day(-5))
        let light = TaskItem(title: "電話", effort: .light, createdAt: day(-1))
        XCTAssertEqual(board.candidates([heavy, light], energy: .low, now: now).first?.id, light.id)
        XCTAssertEqual(board.candidates([heavy, light], energy: .high, now: now).first?.id, heavy.id)
        XCTAssertEqual(board.candidates([heavy, light], energy: .low, now: now).count, 2)
    }

    func testSnoozeOnlyAffectsSuggestionsAndExpires() {
        let task = TaskItem(title: "今日は一旦パス", plannedAt: now,
                            suggestionDeferredUntil: now.addingTimeInterval(3600))
        XCTAssertTrue(board.candidates([task], energy: .any, now: now).isEmpty)
        XCTAssertEqual(board.scheduled([task], for: now).count, 1)
        XCTAssertEqual(board.candidates([task], energy: .any, now: now.addingTimeInterval(3601)).count, 1)
    }

    func testDayBoundaryUsesDeviceCalendarNotUTC() {
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 59))!
        let due = TaskItem(title: "22日締切", deadline: day(1))
        XCTAssertFalse(board.isObligation(due, now: late))
        XCTAssertTrue(board.isObligation(due, now: late.addingTimeInterval(60)))
    }

    func testCompletedTasksAppearInNeitherObligationsNorSuggestions() {
        let task = TaskItem(title: "済み", deadline: day(-1), isMust: true, completedAt: now)
        XCTAssertTrue(board.obligations([task], now: now).isEmpty)
        XCTAssertTrue(board.candidates([task], energy: .any, now: now).isEmpty)
    }

    func testStableTieBreakerAndLimit() {
        let a = TaskItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "A", createdAt: now)
        let b = TaskItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "B", createdAt: now)
        XCTAssertEqual(board.candidates([b, a], energy: .any, now: now, limit: 1).map(\.id), [a.id])
        XCTAssertTrue(board.candidates([a], energy: .any, now: now, limit: -1).isEmpty)
    }
}
