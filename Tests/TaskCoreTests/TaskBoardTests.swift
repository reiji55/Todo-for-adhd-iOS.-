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

    func testWhatIsDueCannotBeHiddenByEnergyOrDeferral() {
        let overdue = TaskItem(title: "支払い", deadline: day(-1), effort: .heavy, suggestionDeferredUntil: day(3))
        let light = TaskItem(title: "紙を整理", effort: .light)
        let all = [overdue, light]
        for energy in Energy.allCases {
            XCTAssertEqual(board.obligations(all, now: now).map(\.id), [overdue.id])
            XCTAssertEqual(board.candidates(all, energy: energy, now: now).map(\.id), [light.id])
        }
    }

    func testStarAloneNeverMakesATaskDue() {
        let far = TaskItem(title: "申請書", deadline: day(10), isMust: true)
        let planned = TaskItem(title: "明日の必須", plannedAt: day(1), isMust: true)
        let undated = TaskItem(title: "いつか必須", isMust: true)
        for date in [now!, day(1), day(2)] {
            XCTAssertTrue(board.obligations([far, planned, undated], now: date).isEmpty)
        }
        XCTAssertTrue(board.isObligation(far, now: day(10)), "its deadline makes it due")
        XCTAssertEqual(board.scheduled([planned], for: day(1)).count, 1)
    }

    func testStarredTasksAreKeptTogetherNearestDeadlineFirst() {
        let later = TaskItem(title: "申請", deadline: day(5), isMust: true, createdAt: day(-3))
        let soon = TaskItem(title: "提出", deadline: day(2), isMust: true, createdAt: day(-1))
        let planned = TaskItem(title: "予約", plannedAt: day(1), isMust: true, createdAt: day(-2))
        let undated = TaskItem(title: "更新", isMust: true, createdAt: day(-4))
        let due = TaskItem(title: "支払い", deadline: now, isMust: true)
        let done = TaskItem(title: "済み", isMust: true, completedAt: now)
        let plain = TaskItem(title: "ふつう", deadline: day(1))
        let musts = board.musts([undated, later, done, planned, due, soon, plain], now: now)
        XCTAssertEqual(musts.map(\.title), ["提出", "申請", "予約", "更新"], "due today is shown above everything instead")
    }

    func testPastDeadlineOverridesFuturePlan() {
        let task = TaskItem(title: "日程矛盾", plannedAt: day(3), deadline: day(-1))
        XCTAssertTrue(board.isObligation(task, now: now))
    }

    func testTaskWithNoStepsCanBeSuggestedAndStarted() {
        let task = TaskItem(title: "電話をかける")
        XCTAssertEqual(task.actionTitle, task.title)
        XCTAssertEqual(board.candidates([task], energy: .any, now: now).map(\.id), [task.id])
    }

    func testSuggestionOrderExplainsPriorityAndExcludesFuturePlan() {
        let whole = TaskItem(title: "資料づくり", createdAt: day(-6))
        let finished = TaskItem(title: "構成", createdAt: day(-6), completedAt: day(-1), parentID: whole.id)
        let continuation = TaskItem(title: "続き", createdAt: day(-5), parentID: whole.id, rank: 1)
        let plan = TaskItem(title: "今日", plannedAt: now)
        let due = TaskItem(title: "明日締切", deadline: day(1), effort: .heavy)
        let future = TaskItem(title: "来週", plannedAt: day(7))
        let casual = TaskItem(title: "日付なし", effort: .light, createdAt: day(-30))
        let candidates = board.candidates([casual, future, whole, finished, continuation, plan, due], energy: .any, now: now)
        XCTAssertEqual(candidates.map(\.id), [due.id, plan.id, continuation.id])
        XCTAssertEqual(candidates.map(\.reason), ["明日が締切", "今日やる予定", "途中まで進んでいるタスクの続き"])
    }

    func testInterruptedTaskComesBackAsContinuationAfterWhatIsDue() {
        let plan = TaskItem(title: "今日", plannedAt: now, createdAt: day(-3))
        let due = TaskItem(title: "明日締切", deadline: day(1))
        let older = TaskItem(title: "前に中断", createdAt: day(-9), lastStartedAt: day(-2), continuationNote: "2章から")
        let latest = TaskItem(title: "さっき中断", createdAt: day(-8), lastStartedAt: day(0), continuationNote: "宛先は確認済み")
        let startedOnly = TaskItem(title: "メモなし", createdAt: day(-7), lastStartedAt: day(0))
        let candidates = board.candidates([startedOnly, plan, older, due, latest], energy: .any, now: now, limit: 9)
        XCTAssertEqual(candidates.map(\.task.title), ["明日締切", "さっき中断", "前に中断", "今日", "メモなし"],
                       "an interrupted task with a note returns before today's plan, the latest first")
        XCTAssertEqual(candidates[1].label, "続き")
    }

    func testAConditionOffersNothingHeavierAndStartsFromTheHeaviest() {
        let heavy = TaskItem(title: "設計", effort: .heavy, createdAt: day(-5))
        let medium = TaskItem(title: "資料", effort: .medium, createdAt: day(-4))
        let light = TaskItem(title: "電話", effort: .light, createdAt: day(-1))
        let plannedLight = TaskItem(title: "買い物", plannedAt: now, effort: .light, createdAt: day(-2))
        let all = [light, plannedLight, medium, heavy]
        func titles(_ energy: Energy) -> [String] { board.candidates(all, energy: energy, now: now, limit: 9).map(\.task.title) }
        XCTAssertEqual(titles(.high), ["設計", "資料", "買い物", "電話"], "heaviest first; today's plan first within a weight")
        XCTAssertEqual(titles(.normal), ["資料", "買い物", "電話"])
        XCTAssertEqual(titles(.low), ["買い物", "電話"])
        XCTAssertEqual(titles(.any), ["買い物", "設計", "資料", "電話"], "no condition: by standing, then longest untouched")
    }

    func testPiecesCountTheirParentsStarAndDeadline() {
        let soon = TaskItem(title: "提案書", deadline: day(1), createdAt: day(-3))
        let soonPiece = TaskItem(title: "見出し", createdAt: day(-3), parentID: soon.id)
        let starred = TaskItem(title: "引っ越し", deadline: day(20), isMust: true, createdAt: day(-3))
        let starredPiece = TaskItem(title: "段ボール", createdAt: day(-3), parentID: starred.id)
        let plain = TaskItem(title: "読書", createdAt: day(-9))
        let picks = board.candidates([plain, starred, starredPiece, soon, soonPiece], energy: .any, now: now, limit: 9)
        XCTAssertEqual(picks.map(\.task.title), ["見出し", "段ボール", "読書"])
        XCTAssertEqual(picks.map(\.label), ["明日が締切", "", "しばらく手つかず"])
        XCTAssertEqual(picks.map(\.isMust), [false, true, false])
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
