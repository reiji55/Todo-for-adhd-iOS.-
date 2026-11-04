import XCTest
@testable import TaskCore

final class FamilyTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)
    private let today = Date(timeIntervalSince1970: 1_790_100_000)

    func testFirstChildTakesTheParentsDayAndTime() {
        let parent = TaskItem(title: "提案書", plannedAt: today, scheduledTime: "14:00-15:00", deadline: today, isMust: true,
                              project: "仕事", createdAt: created)
        var book = Notebook(tasks: [parent])
        book.addChild(TaskItem(title: "見出し", createdAt: created), to: parent.id)
        book.addChild(TaskItem(title: "本文", createdAt: created), to: parent.id)
        let kids = book.children(of: parent.id)
        XCTAssertEqual(kids.map(\.title), ["見出し", "本文"])
        XCTAssertEqual(kids[0].plannedAt, today)
        XCTAssertEqual(kids[0].scheduledTime, "14:00-15:00")
        XCTAssertNil(kids[1].plannedAt)
        XCTAssertEqual(kids.map(\.project), ["仕事", "仕事"])
        let updated = book.tasks.first { $0.id == parent.id }!
        XCTAssertNil(updated.plannedAt)
        XCTAssertEqual(updated.scheduledTime, "")
        XCTAssertEqual(updated.deadline, today)
        XCTAssertTrue(updated.isMust)
    }

    func testParentIsDoneExactlyWhenEveryChildIs() {
        let parent = TaskItem(title: "引っ越し", createdAt: created)
        var book = Notebook(tasks: [parent])
        book.addChild(TaskItem(title: "段ボール", createdAt: created), to: parent.id)
        book.addChild(TaskItem(title: "住所変更", createdAt: created), to: parent.id)
        let kids = book.children(of: parent.id)
        book.toggleTask(kids[0].id, at: today)
        XCTAssertFalse(book.tasks.first { $0.id == parent.id }!.isComplete)
        book.toggleTask(kids[1].id, at: today)
        XCTAssertTrue(book.tasks.first { $0.id == parent.id }!.isComplete)
        // Reopening one piece reopens the whole.
        book.toggleTask(kids[0].id, at: today)
        XCTAssertFalse(book.tasks.first { $0.id == parent.id }!.isComplete)
        // A new piece on a finished parent reopens it too.
        book.toggleTask(kids[0].id, at: today)
        book.addChild(TaskItem(title: "鍵を返す", createdAt: created), to: parent.id)
        XCTAssertFalse(book.tasks.first { $0.id == parent.id }!.isComplete)
    }

    func testCheckingOffAParentFinishesTheRestAndUndoingReopensOnlyThose() {
        let parent = TaskItem(title: "引っ越し", createdAt: created)
        var book = Notebook(tasks: [parent])
        for title in ["段ボール", "本棚", "住所変更"] { book.addChild(TaskItem(title: title, createdAt: created), to: parent.id) }
        let first = book.children(of: parent.id)[0]
        book.toggleTask(first.id, at: created)
        book.toggleTask(parent.id, at: today)
        XCTAssertTrue(book.children(of: parent.id).allSatisfy(\.isComplete))
        book.toggleTask(parent.id, at: today)
        let kids = book.children(of: parent.id)
        XCTAssertTrue(kids[0].isComplete, "finished before the parent was checked off; stays finished")
        XCTAssertFalse(kids[1].isComplete)
        XCTAssertFalse(kids[2].isComplete)
        XCTAssertFalse(book.tasks.first { $0.id == parent.id }!.isComplete)
    }

    func testRemovingTheLastChildLeavesAnOrdinaryTask() {
        let parent = TaskItem(title: "提案書", createdAt: created)
        var book = Notebook(tasks: [parent])
        book.addChild(TaskItem(title: "見出し", createdAt: created), to: parent.id)
        let child = book.children(of: parent.id)[0]
        book.removeTask(child.id)
        XCTAssertFalse(book.hasChildren(parent.id))
        XCTAssertEqual(book.tasks.map(\.id), [parent.id])
        // Removing a parent takes its children with it.
        book.addChild(TaskItem(title: "本文", createdAt: created), to: parent.id)
        book.removeTask(parent.id)
        XCTAssertTrue(book.tasks.isEmpty)
    }

    func testStepsBecomeTheSameChildrenOnEveryDevice() {
        let done = Step(title: "宛先を確認する", isDone: true), open = Step(title: "送る")
        let task = TaskItem(title: "提出書類", plannedAt: today, scheduledTime: "9:00-10:00", isMust: true,
                            project: "役所", resumeNote: "封筒は机の上", steps: [done, open], createdAt: created)
        var a = Notebook(tasks: [task], activeSession: Session(taskID: task.id, startedAt: created, stepID: open.id))
        var b = a
        XCTAssertTrue(a.convertStepsToChildren(at: today))
        b.convertStepsToChildren(at: today)
        XCTAssertEqual(a, b)
        XCTAssertNil(a.activeSession)
        let kids = a.children(of: task.id)
        XCTAssertEqual(kids.map(\.id), [done.id, open.id])
        XCTAssertTrue(kids[0].isComplete)
        XCTAssertEqual(kids[1].plannedAt, today, "the next piece keeps the day the task was planned for")
        XCTAssertEqual(kids[1].scheduledTime, "9:00-10:00")
        let parent = a.tasks.first { $0.id == task.id }!
        XCTAssertTrue(parent.steps.isEmpty)
        XCTAssertNil(parent.plannedAt)
        XCTAssertEqual(parent.memo, "続き：封筒は机の上")
        XCTAssertFalse(a.convertStepsToChildren(at: today), "running it again changes nothing")
    }

    func testAFinishedTasksStepsAllBecomeFinishedChildren() {
        let task = TaskItem(title: "提出書類", steps: [Step(title: "宛先"), Step(title: "送る")], createdAt: created, completedAt: today)
        var book = Notebook(tasks: [task])
        book.convertStepsToChildren(at: today)
        XCTAssertTrue(book.children(of: task.id).allSatisfy(\.isComplete))
        XCTAssertEqual(book.tasks.first { $0.id == task.id }?.completedAt, today)
    }

    func testAParentIsRequiredFromItsFirstChildsDayAndOnlyChildrenAreSuggested() {
        let calendar = Calendar(identifier: .gregorian)
        let board = TaskBoard(calendar: calendar)
        let later = today.addingTimeInterval(3 * 86_400)
        let parent = TaskItem(title: "提案書", isMust: true, createdAt: created)
        var book = Notebook(tasks: [parent])
        book.addChild(TaskItem(title: "見出し", plannedAt: later, createdAt: created), to: parent.id)
        XCTAssertTrue(board.obligations(book.tasks, now: today).isEmpty, "★ waits for the first piece's day")
        XCTAssertFalse(board.obligations(book.tasks, now: later).isEmpty)
        book.addChild(TaskItem(title: "本文", createdAt: created), to: parent.id)
        let suggested = board.candidates(book.tasks, energy: .any, now: today, limit: 5).map(\.task.title)
        XCTAssertFalse(suggested.contains("提案書"))
        XCTAssertTrue(suggested.contains("本文"))
    }

    func testChildrenTravelThroughSync() throws {
        let parent = TaskItem(title: "提案書", createdAt: created)
        var book = Notebook(tasks: [parent])
        book.addChild(TaskItem(title: "見出し", plannedAt: today, createdAt: created), to: parent.id)
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: created)
        let restored = try replica.materialize()
        XCTAssertEqual(restored.children(of: parent.id).map(\.title), ["見出し"])
        XCTAssertEqual(restored.children(of: parent.id).first?.parentID, parent.id)
    }

    func testRoutineKeepsWhereItLeftOff() throws {
        let routine = Routine(title: "金フレ", weekdays: [2], time: "19:00-19:30", createdAt: created, resumeNote: "120番まで")
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: Notebook(routines: [routine]), device: "seed", now: created)
        XCTAssertEqual(try replica.materialize().routines.first?.resumeNote, "120番まで")
    }
}
