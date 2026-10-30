import XCTest
@testable import TaskCore

final class SyncTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 100)
    private func seeded(_ book: Notebook) throws -> SyncReplica {
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: epoch)
        return replica
    }

    func testOfflineEditsToDifferentFieldsAndTasksConvergeInEitherOrder() throws {
        let book = Notebook(tasks: [TaskItem(title: "提出", steps: [Step(title: "宛先")]), TaskItem(title: "電話")])
        var a = try seeded(book), b = a
        var first = book, second = book
        first.tasks[0].title = "提出する"; first.tasks[0].steps[0].isDone = true
        second.tasks[0].memo = "午後"; second.tasks[1].completedAt = epoch
        try a.apply(before: book, after: first, device: "phone", now: epoch)
        try b.apply(before: book, after: second, device: "pad", now: epoch)
        let originalA = a
        try a.merge(Array(b.records.values)); try b.merge(Array(originalA.records.values))
        XCTAssertEqual(a.records, b.records)
        let merged = try a.materialize()
        let task = try XCTUnwrap(merged.tasks.first { $0.id == book.tasks[0].id })
        XCTAssertEqual(task.title, "提出する"); XCTAssertEqual(task.memo, "午後")
        XCTAssertTrue(task.steps[0].isDone)
        XCTAssertTrue(try XCTUnwrap(merged.tasks.first { $0.id == book.tasks[1].id }).isComplete)
    }

    func testDeletingTaskWinsAgainstStaleOfflineEditButExplicitUndoRestores() throws {
        let book = Notebook(tasks: [TaskItem(title: "削除")])
        var deleting = try seeded(book), editing = deleting
        var edited = book; edited.tasks[0].memo = "後から編集"
        try deleting.apply(before: book, after: Notebook(), device: "A", now: epoch)
        try editing.apply(before: book, after: edited, device: "B", now: epoch.addingTimeInterval(10))
        try deleting.merge(Array(editing.records.values))
        XCTAssertTrue(try deleting.materialize().tasks.isEmpty)
        try deleting.apply(before: Notebook(), after: book, device: "A", now: epoch.addingTimeInterval(20))
        XCTAssertEqual(try deleting.materialize().tasks.first?.title, "削除")
    }

    func testStepDeletionAndIndependentStepCompletionDoNotResurrectDeletedSteps() throws {
        let book = Notebook(tasks: [TaskItem(title: "手順", steps: [Step(title: "一"), Step(title: "二")])])
        var a = try seeded(book), b = a
        var one = book, two = book
        one.tasks[0].steps.removeFirst()
        two.tasks[0].steps[0].title = "編集した一"; two.tasks[0].steps[1].isDone = true
        try a.apply(before: book, after: one, device: "a", now: epoch)
        try b.apply(before: book, after: two, device: "b", now: epoch.addingTimeInterval(10))
        try a.merge(Array(b.records.values))
        let steps = try XCTUnwrap(a.materialize().tasks.first).steps
        XCTAssertEqual(steps.count, 1); XCTAssertEqual(steps.first?.title, "二"); XCTAssertEqual(steps.first?.isDone, true)
    }

    func testClearingOptionalDeadlineIsSynced() throws {
        let book = Notebook(tasks: [TaskItem(title: "締切", deadline: epoch)])
        var a = try seeded(book), b = a
        var changed = book; changed.tasks[0].deadline = nil
        try a.apply(before: book, after: changed, device: "a", now: epoch)
        try b.merge(Array(a.records.values))
        XCTAssertNil(try b.materialize().tasks.first?.deadline)
    }

    func testSameFieldConflictIsDeterministicAndRepeatedDeliveryIsIdempotent() throws {
        let book = Notebook(tasks: [TaskItem(title: "前")])
        var a = try seeded(book), b = a
        var one = book, two = book; one.tasks[0].title = "A"; two.tasks[0].title = "B"
        try a.apply(before: book, after: one, device: "a", now: epoch)
        try b.apply(before: book, after: two, device: "b", now: epoch)
        try a.merge(Array(b.records.values)); try b.merge(Array(a.records.values))
        XCTAssertEqual(a, b)
        try a.merge(Array(b.records.values))
        XCTAssertEqual(a, b); XCTAssertEqual(try a.materialize().tasks.first?.title, "B")
    }

    func testOpenEditorPreservesNewRemoteFieldsAndNewSteps() throws {
        let original = TaskItem(title: "編集", steps: [Step(title: "一")])
        var edited = original, current = original
        edited.title = "編集した題名"
        current.memo = "別端末のメモ"; current.steps[0].isDone = true; current.steps.append(Step(title: "追加"))
        let result = try SyncReplica.editedTask(original: original, edited: edited, current: current)
        XCTAssertEqual(result.title, edited.title); XCTAssertEqual(result.memo, current.memo)
        XCTAssertTrue(result.steps[0].isDone); XCTAssertEqual(result.steps.count, 2)
    }

    func testJoinKeepsUnrelatedTasksAndConflictingCopiesWithoutDuplicatingIdenticalTasks() {
        let same = TaskItem(title: "同じ"), conflict = TaskItem(title: "変更前")
        var changed = conflict; changed.memo = "端末だけにあるメモ"
        let remote = Notebook(tasks: [same, conflict])
        let preview = ShareMergePreview(local: Notebook(tasks: [same, changed, TaskItem(title: "ローカル")]), remote: remote)
        XCTAssertEqual(preview.combined.tasks.count, 4); XCTAssertEqual(preview.conflictingTasks, 1)
        XCTAssertTrue(preview.combined.tasks.contains { $0.memo == changed.memo && $0.id != conflict.id })
    }

    func testSessionIsRemovedWhenRemoteTaskWasCompletedOrDeleted() throws {
        let task = TaskItem(title: "実行")
        let book = Notebook(tasks: [task], activeSession: Session(taskID: task.id, startedAt: epoch, stepID: nil))
        var a = try seeded(book), b = a
        var done = book; done.tasks[0].completedAt = epoch; done.activeSession = nil
        try b.apply(before: book, after: done, device: "b", now: epoch)
        try a.merge(Array(b.records.values))
        XCTAssertNil(try a.materialize().activeSession)
    }

    func testAtomicMigrationAndPendingEditsSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SharedStoreRepository(directory: directory)
        let book = Notebook(tasks: [TaskItem(title: "既存", createdAt: epoch)])
        try repo.legacy.save(book)
        let legacyBytes = try Data(contentsOf: repo.legacy.url)
        var state = try repo.load()
        XCTAssertEqual(state.notebook, book)
        state.replica = try seeded(book)
        state.connection = SyncConnection(accountID: "one", zoneName: "data", ownerName: "owner", isShared: false)
        var edited = book; edited.tasks[0].memo = "未送信"
        try state.edit(edited); try repo.save(state)
        XCTAssertEqual(try repo.load(), state)
        XCTAssertEqual(try Data(contentsOf: repo.legacy.url), legacyBytes)
        try Data("damaged".utf8).write(to: repo.url)
        XCTAssertThrowsError(try repo.load()); XCTAssertThrowsError(try repo.save(state))
        let recovered = try repo.recoverPrevious()
        XCTAssertNil(recovered.connection); XCTAssertNil(recovered.replica)
        XCTAssertEqual(recovered.notebook.tasks.first?.title, "既存")
    }

    func testRemoteUnknownSchemaOrInvalidRecordFailsWithoutBeingIgnored() throws {
        var record = SyncRecord(id: "task_\(UUID().uuidString)")
        record.version = 2
        XCTAssertThrowsError(try SyncRecord.decode(record.encoded(), expectedID: record.id))
        var replica = SyncReplica()
        XCTAssertThrowsError(try replica.merge([record]))
    }
}
