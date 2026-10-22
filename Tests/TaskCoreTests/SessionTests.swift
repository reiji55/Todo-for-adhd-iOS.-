import XCTest
@testable import TaskCore

final class SessionTests: XCTestCase {
    func testSwitchingKeepsBookmarksForBothTasks() {
        let first = TaskItem(title: "資料", resumeNote: "2ページ目まで")
        let second = TaskItem(title: "電話")
        var book = Notebook(tasks: [first, second])
        book.startTask(first.id)
        book.startTask(second.id)
        XCTAssertEqual(book.tasks[0].resumeNote, "2ページ目まで")
        book.pauseTask(note: "電話番号を確認した")
        XCTAssertEqual(book.tasks[1].resumeNote, "電話番号を確認した")
        XCTAssertEqual(book.tasks[0].resumeNote, "2ページ目まで")
        XCTAssertNil(book.activeSession)
    }

    func testTitleOnlyTaskCanStartAndFinishWithoutExtraInput() {
        let task = TaskItem(title: "予約する")
        var book = Notebook(tasks: [task])
        book.startTask(task.id)
        XCTAssertEqual(book.activeSession?.taskID, task.id)
        XCTAssertNil(book.activeSession?.stepID)
        book.finishAction()
        XCTAssertTrue(book.tasks[0].isComplete)
    }

    func testFinishingStepDoesNotSilentlyCompleteGoal() {
        let step = Step(title: "見出しを書く")
        let task = TaskItem(title: "企画書", steps: [step])
        var book = Notebook(tasks: [task])
        book.startTask(task.id)
        book.finishAction()
        XCTAssertTrue(book.tasks[0].steps[0].isDone)
        XCTAssertFalse(book.tasks[0].isComplete)
    }

    func testReorderingWhileWorkingCompletesOriginalStep() {
        let a = Step(title: "A"), b = Step(title: "B")
        let task = TaskItem(title: "工程あり", steps: [a, b])
        var book = Notebook(tasks: [task])
        book.startTask(task.id)
        book.tasks[0].steps = [b, a]
        book.finishAction()
        XCTAssertFalse(book.tasks[0].steps[0].isDone)
        XCTAssertTrue(book.tasks[0].steps[1].isDone)
    }

    func testOpeningCurrentSessionDoesNotResetTimer() {
        let task = TaskItem(title: "続き")
        var book = Notebook(tasks: [task])
        let start = Date(timeIntervalSince1970: 100)
        book.startTask(task.id, at: start)
        book.startTask(task.id, at: start.addingTimeInterval(600))
        XCTAssertEqual(book.activeSession?.startedAt, start)
    }

    func testSwitchWithoutNoteStillLeavesReturnPoint() {
        let a = TaskItem(title: "A"), b = TaskItem(title: "B")
        var book = Notebook(tasks: [a, b])
        book.startTask(a.id)
        book.startTask(b.id)
        XCTAssertFalse(book.tasks[0].resumeNote.isEmpty)
        XCTAssertEqual(book.activeSession?.taskID, b.id)
    }
}
