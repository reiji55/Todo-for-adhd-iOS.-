import XCTest
@testable import TaskCore

final class PeriodTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()
    private func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func appointment() -> TaskItem {
        TaskItem(title: "12月中にアポ", deadline: day(12, 31), createdAt: day(11, 1), periodStart: day(12, 1))
    }

    func testAPeriodTaskIsQuietUntilItsFirstDayThenSuggestedWithTheDaysLeft() {
        let task = appointment()
        let board = TaskBoard(calendar: calendar)
        XCTAssertTrue(board.candidates([task], energy: .any, now: day(11, 30), limit: 5).isEmpty, "not before its first day")
        let first = board.candidates([task], energy: .any, now: day(12, 1), limit: 5)
        XCTAssertEqual(first.map(\.task.title), ["12月中にアポ"])
        XCTAssertEqual(first.first?.label, "期間中・あと30日")
        XCTAssertEqual(board.candidates([task], energy: .any, now: day(12, 30), limit: 5).first?.label, "明日が締切")
        XCTAssertTrue(board.isObligation(task, now: day(12, 31)), "its last day is its deadline")
    }

    func testThePeriodComesBeforeUntouchedTasksButAfterWhatIsPlannedForToday() {
        let board = TaskBoard(calendar: calendar)
        let old = TaskItem(title: "前から", createdAt: day(10, 1))
        let today = TaskItem(title: "今日の予定", plannedAt: day(12, 5), createdAt: day(11, 20))
        let order = board.candidates([old, today, appointment()], energy: .any, now: day(12, 5), limit: 5).map(\.task.title)
        XCTAssertEqual(order, ["今日の予定", "12月中にアポ", "前から"])
    }

    func testPeriodTasksOnADayAreThoseWhoseStretchHoldsIt() {
        var done = appointment()
        done.completedAt = day(12, 3)
        let later = TaskItem(title: "年末の大掃除", deadline: day(12, 30), createdAt: day(11, 2), periodStart: day(12, 20))
        let book = Notebook(tasks: [appointment(), later, done, TaskItem(title: "ふつう")])
        XCTAssertEqual(book.periodTasks(on: day(12, 5), calendar: calendar).map(\.title), ["12月中にアポ"])
        XCTAssertEqual(book.periodTasks(on: day(12, 25), calendar: calendar).map(\.title), ["年末の大掃除", "12月中にアポ"])
        XCTAssertTrue(book.periodTasks(on: day(11, 30), calendar: calendar).isEmpty)
        XCTAssertEqual(appointment().period?.text(calendar: calendar), "12/1〜12/31")
        XCTAssertEqual(appointment().period?.length(calendar: calendar), 31)
    }

    func testAPieceWaitsForTheStretchOfTheTaskItIsAPieceOf() {
        let parent = appointment()
        let piece = TaskItem(title: "候補日を出す", createdAt: day(11, 2), parentID: parent.id)
        let board = TaskBoard(calendar: calendar)
        XCTAssertTrue(board.candidates([parent, piece], energy: .any, now: day(11, 20), limit: 5).isEmpty)
        XCTAssertEqual(board.candidates([parent, piece], energy: .any, now: day(12, 2), limit: 5).map(\.task.title), ["候補日を出す"])
        XCTAssertEqual(Notebook(tasks: [parent, piece]).period(of: piece), parent.period)
    }

    func testTheStartSyncsAndTakingItOffSyncsToo() throws {
        var book = Notebook(tasks: [TaskItem(title: "12月中にアポ", deadline: day(12, 31), createdAt: day(11, 1))])
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: day(11, 1))
        let before = book
        book.tasks[0].periodStart = day(12, 1)
        try replica.apply(before: before, after: book, device: "phone", now: day(11, 2))
        XCTAssertEqual(try replica.materialize().tasks.first?.periodStart, day(12, 1))
        let set = book
        book.tasks[0].periodStart = nil
        try replica.apply(before: set, after: book, device: "phone", now: day(11, 3))
        XCTAssertNil(try replica.materialize().tasks.first?.periodStart)
    }

    func testDataFromBeforePeriodsStillOpens() throws {
        let json = #"{"id":"0E6F5D7C-6B0B-4C59-9C1B-1A6A2F6D7F10","title":"古いタスク","createdAt":"2026-11-01T03:00:00Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertNil(task.periodStart)
        XCTAssertNil(task.period)
    }
}
