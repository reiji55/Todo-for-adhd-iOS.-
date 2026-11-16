import XCTest
@testable import TaskCore

final class ChainTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func later(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func cancel() -> (Notebook, TaskItem) {
        let apply = TaskItem(title: "解約の申込みをする", project: "引っ越し", createdAt: now)
        return (Notebook(tasks: [apply]), apply)
    }

    func testANextTaskWaitsForTheOneBeforeItAndThenComesUp() {
        var (book, apply) = cancel()
        let deposit = TaskItem(title: "保証金の返還を確認する", createdAt: later(1))
        XCTAssertTrue(book.addTask(deposit, after: apply.id))
        XCTAssertEqual(book.chain(containing: deposit.id).map(\.title), ["解約の申込みをする", "保証金の返還を確認する"])
        XCTAssertEqual(book.tasks.first { $0.id == deposit.id }?.project, "引っ越し", "a new link takes the project of the one it joins")
        XCTAssertEqual(book.nextInChain(after: apply.id)?.id, deposit.id)
        XCTAssertTrue(book.isWaiting(book.tasks.first { $0.id == deposit.id }!))

        let board = TaskBoard()
        XCTAssertEqual(board.candidates(book.tasks, energy: .any, now: later(5), limit: 10).map(\.task.title), ["解約の申込みをする"],
                       "the next one is not suggested while the one before it is open")
        book.toggleTask(apply.id, at: later(10))
        let after = board.candidates(book.tasks, energy: .any, now: later(11), limit: 10)
        XCTAssertEqual(after.map(\.task.title), ["保証金の返還を確認する"])
        XCTAssertEqual(after.first?.label, "「解約の申込みをする」の次")
    }

    func testAddingBeforeAndBetweenKeepsTheOrder() {
        var (book, apply) = cancel()
        let deposit = TaskItem(title: "保証金の返還を確認する", createdAt: later(1))
        let keys = TaskItem(title: "鍵を返す日を決める", createdAt: later(2))
        let notice = TaskItem(title: "管理会社の連絡先を調べる", createdAt: later(3))
        book.addTask(deposit, after: apply.id)
        book.addTask(keys, after: apply.id)
        book.addTask(notice, before: apply.id)
        XCTAssertEqual(book.chain(containing: keys.id).map(\.title),
                       ["管理会社の連絡先を調べる", "解約の申込みをする", "鍵を返す日を決める", "保証金の返還を確認する"])
    }

    func testRemovingOrUnlinkingATaskJoinsTheOnesAroundIt() {
        var (book, apply) = cancel()
        let deposit = TaskItem(title: "保証金の返還を確認する", createdAt: later(1))
        let keys = TaskItem(title: "鍵を返す日を決める", createdAt: later(2))
        book.addTask(deposit, after: apply.id)
        book.addTask(keys, after: deposit.id)
        var removed = book
        removed.removeTask(deposit.id)
        XCTAssertEqual(removed.chain(containing: apply.id).map(\.title), ["解約の申込みをする", "鍵を返す日を決める"])
        book.unlink(deposit.id)
        XCTAssertEqual(book.chain(containing: apply.id).map(\.title), ["解約の申込みをする", "鍵を返す日を決める"])
        XCTAssertEqual(book.chain(containing: deposit.id).map(\.title), ["保証金の返還を確認する"])
        book.dissolveChain(containing: apply.id)
        XCTAssertTrue(book.tasks.allSatisfy { $0.follows == nil })
        XCTAssertEqual(book.tasks.count, 3, "no task is lost")
    }

    func testGatheringAndScatteringGoBothWays() throws {
        var (book, apply) = cancel()
        let due = later(60 * 24 * 7)
        let deposit = TaskItem(title: "保証金の返還を確認する", deadline: due, isMust: true, createdAt: later(1))
        let other = TaskItem(title: "あとのこと", createdAt: later(3))
        book.addTask(deposit, after: apply.id)
        book.addTask(other, after: deposit.id)

        let parentID = try XCTUnwrap(book.gatherChain(containing: deposit.id, title: "賃貸の解約"))
        let parent = try XCTUnwrap(book.tasks.first { $0.id == parentID })
        XCTAssertEqual(book.children(of: parentID).map(\.title), ["解約の申込みをする", "保証金の返還を確認する", "あとのこと"])
        XCTAssertEqual(parent.deadline, due)
        XCTAssertTrue(parent.isMust)
        XCTAssertEqual(parent.project, "引っ越し")
        XCTAssertTrue(book.tasks.filter { $0.parentID == parentID }.allSatisfy { $0.follows == nil })
        XCTAssertNoThrow(try NotebookCodec.validate(book))

        let first = try XCTUnwrap(book.scatterPieces(of: parentID))
        XCTAssertNil(book.tasks.first { $0.id == parentID }, "the gathering task goes")
        XCTAssertEqual(book.chain(containing: first).map(\.title), ["解約の申込みをする", "保証金の返還を確認する", "あとのこと"])
        XCTAssertEqual(book.tasks.first { $0.title == "あとのこと" }?.deadline, due, "its deadline passes to the last piece")
        XCTAssertTrue(book.tasks.allSatisfy { $0.parentID == nil })
        XCTAssertEqual(book.tasks.count, 3)
    }

    func testATaskWithPiecesCannotBeGatheredAgain() {
        var (book, apply) = cancel()
        book.addChild(TaskItem(title: "書類を探す"), to: apply.id)
        book.addTask(TaskItem(title: "保証金の返還を確認する"), after: apply.id)
        XCTAssertNil(book.gatherChain(containing: apply.id, title: "まとめ"), "one level only")
    }

    func testMakingAProjectNamesEveryTaskAndTakingItOffKeepsTheOrder() {
        var (book, apply) = cancel()
        let deposit = TaskItem(title: "保証金の返還を確認する", createdAt: later(1))
        book.addTask(deposit, after: apply.id)
        book.makeProject(ofChainContaining: apply.id, named: "賃貸の解約", at: later(2))
        XCTAssertTrue(book.chain(containing: apply.id).allSatisfy { $0.project == "賃貸の解約" })
        XCTAssertEqual(book.projects.map(\.name), ["賃貸の解約"])
        ProjectBook.remove(ProjectBook.key("賃貸の解約"), from: &book)
        XCTAssertEqual(book.chain(containing: apply.id).map(\.title), ["解約の申込みをする", "保証金の返還を確認する"])
        XCTAssertTrue(book.projects.isEmpty)
    }

    func testCrossedEditsFromTwoDevicesAreReadWithoutLosingOrRepeatingTasks() throws {
        let a = TaskItem(title: "A", createdAt: now)
        let b = TaskItem(title: "B", createdAt: later(1), follows: a.id)
        let c = TaskItem(title: "C", createdAt: later(2), follows: a.id)
        XCTAssertEqual(Notebook(tasks: [a, b, c]).chain(containing: c.id).map(\.title), ["A", "B", "C"])
        // A loop, which only crossing edits can make.
        var x = TaskItem(title: "X", createdAt: now)
        let y = TaskItem(title: "Y", createdAt: later(1), follows: x.id)
        x.follows = y.id
        XCTAssertEqual(Set(Notebook(tasks: [x, y]).chain(containing: x.id).map(\.title)), ["X", "Y"])
    }

    func testTheLinkSyncsAndClearingItSyncsToo() throws {
        var (book, apply) = cancel()
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: now)
        let before = book
        book.addTask(TaskItem(title: "保証金の返還を確認する", createdAt: later(1)), after: apply.id)
        try replica.apply(before: before, after: book, device: "phone", now: later(1))
        XCTAssertEqual(try replica.materialize().chain(containing: apply.id).count, 2)
        let linked = book
        book.dissolveChain(containing: apply.id)
        try replica.apply(before: linked, after: book, device: "phone", now: later(2))
        XCTAssertTrue(try replica.materialize().tasks.allSatisfy { $0.follows == nil })
    }
}
