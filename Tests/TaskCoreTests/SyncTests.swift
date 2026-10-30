import XCTest
@testable import TaskCore

final class SyncTests: XCTestCase {
    func testJoiningDoesNotDuplicateBoardsAndRoutinesAfterCloudDateRounding() throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000.75)
        var routine = Routine(title: "学習", createdAt: created)
        routine.doneDays = ["2026-10-29", "2026-10-30"]
        let local = Notebook(boardCards: [BoardCard(title: "手順", detail: "本文", createdAt: created)], routines: [routine])
        let remote = try seeded(local).materialize()
        let preview = ShareMergePreview(local: local, remote: remote)
        XCTAssertEqual(preview.combined.boardCards.count, 1)
        XCTAssertEqual(preview.combined.routines.count, 1)
        XCTAssertEqual(preview.combined.routines[0].doneDays, routine.doneDays)
    }

    func testJoiningPreservesDifferentBoardAndRoutineContentAsCopies() throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000.75)
        let remote = Notebook(boardCards: [BoardCard(title: "手順", detail: "元の本文", createdAt: created)],
                              routines: [Routine(title: "学習", time: "19:00-20:00", createdAt: created)])
        var local = try NotebookCodec.decode(NotebookCodec.encode(remote))
        local.boardCards[0].detail = "端末で追記した本文"
        local.routines[0].time = "20:00-21:00"
        let preview = ShareMergePreview(local: local, remote: remote)
        XCTAssertEqual(Set(preview.combined.boardCards.map(\.detail)), ["元の本文", "端末で追記した本文"])
        XCTAssertEqual(Set(preview.combined.boardCards.map(\.id)).count, 2)
        XCTAssertEqual(Set(preview.combined.routines.map(\.time)), ["19:00-20:00", "20:00-21:00"])
        XCTAssertEqual(Set(preview.combined.routines.map(\.id)).count, 2)
    }

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

    func testTwoOfflineConversionsOfOneIdeaProduceOneTask() throws {
        let idea = Idea(text: "原稿を書く\n見出しから", createdAt: epoch)
        let book = Notebook(ideas: [idea])
        var phone = book, pad = book
        XCTAssertTrue(phone.convertIdea(idea.id, plannedAt: nil))
        XCTAssertTrue(pad.convertIdea(idea.id, plannedAt: epoch))
        var a = try seeded(book), b = a
        try a.apply(before: book, after: phone, device: "a", now: epoch)
        try b.apply(before: book, after: pad, device: "b", now: epoch)
        try a.merge(Array(b.records.values))
        let result = try a.materialize()
        XCTAssertTrue(result.ideas.isEmpty); XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].id, idea.id); XCTAssertEqual(result.tasks[0].memo, "見出しから")
    }

    func testConversionNeverOverwritesAnExistingTaskWithSameID() {
        let idea = Idea(text: "別のアイデア")
        var book = Notebook(tasks: [TaskItem(id: idea.id, title: "既存")], ideas: [idea])
        XCTAssertFalse(book.convertIdea(idea.id, plannedAt: nil))
        XCTAssertEqual(book.ideas.count, 1); XCTAssertEqual(book.tasks.first?.title, "既存")
    }

    func testEditDuringNetworkRequestSurvivesOlderAcknowledgementAndReload() throws {
        let book = Notebook(tasks: [TaskItem(title: "最初", createdAt: epoch)])
        var state = SharedStoreState(notebook: book)
        state.replica = try seeded(book)
        state.connection = SyncConnection(accountID: "owner", zoneName: "HormeData", ownerName: "owner", isShared: false)
        var first = book; first.tasks[0].title = "送信中"
        try state.edit(first)
        let sent = try XCTUnwrap(state.replica)
        var second = first; second.tasks[0].title = "送信中に追加編集"
        try state.edit(second)
        try state.receive(Array(sent.records.values))
        let reloaded = try SharedStoreState.decode(state.encoded())
        XCTAssertEqual(reloaded.notebook.tasks[0].title, "送信中に追加編集")
        XCTAssertNotEqual(reloaded.replica?.records, sent.records)
        XCTAssertTrue(reloaded.hasPendingChanges)
    }

    func testSessionFollowsPreservedLocalCopyWhenJoiningConflictingTask() {
        let remoteTask = TaskItem(title: "共有先", createdAt: epoch)
        var localTask = remoteTask; localTask.title = "端末の内容"
        let local = Notebook(tasks: [localTask], activeSession: Session(taskID: localTask.id, startedAt: epoch, stepID: nil))
        let preview = ShareMergePreview(local: local, remote: Notebook(tasks: [remoteTask]))
        let localCopy = preview.combined.tasks.first { $0.title == "端末の内容" }
        XCTAssertNotEqual(localCopy?.id, remoteTask.id)
        XCTAssertEqual(preview.combined.activeSession?.taskID, localCopy?.id)
    }

    func testCreateThenDeleteBeforeConnectingNeverAppearsOnOtherDevice() throws {
        var a = SyncReplica(), b = SyncReplica()
        let book = Notebook(tasks: [TaskItem(title: "取り消す")])
        try a.apply(before: Notebook(), after: book, device: "a", now: epoch)
        try a.apply(before: book, after: Notebook(), device: "a", now: epoch)
        try b.merge(Array(a.records.values))
        XCTAssertTrue(try b.materialize().tasks.isEmpty)
        XCTAssertFalse(b.records.isEmpty, "Deletion evidence must remain durable")
    }

    func testFailedAtomicSaveLeavesCommittedStateAndLegacyIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SharedStoreRepository(directory: directory)
        let original = try repo.load()
        var edited = original; try edited.edit(Notebook(tasks: [TaskItem(title: "保存失敗")]))
        try FileManager.default.createDirectory(at: repo.previousURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try repo.save(edited))
        XCTAssertEqual(try repo.load(), original)
    }

    func testMultipleReplicasConvergeAcrossReorderedDuplicateDeliveries() throws {
        let book = Notebook(tasks: [TaskItem(title: "共有", steps: [Step(title: "一"), Step(title: "二")], createdAt: epoch)],
                            ideas: [Idea(text: "元の発想", createdAt: epoch)])
        let base = try seeded(book)
        var replicas = [base, base, base]
        for index in 0..<3 {
            var edited = book
            edited.tasks[0].memo = "メモ\(index)"
            if index == 0 { edited.tasks[0].steps[0].isDone = true }
            if index == 1 { edited.tasks[0].steps[1].isDone = true }
            if index == 2 { edited.ideas[0].text = "広がった発想" }
            try replicas[index].apply(before: book, after: edited, device: "device\(index)", now: epoch)
        }
        let messages = replicas.map { Array($0.records.values) }
        for index in 0..<3 {
            for turn in 0..<6 { try replicas[index].merge(messages[(index + turn) % 3]) }
        }
        XCTAssertEqual(replicas[0], replicas[1]); XCTAssertEqual(replicas[1], replicas[2])
        let result = try replicas[0].materialize()
        XCTAssertTrue(result.tasks[0].steps.allSatisfy(\.isDone))
        XCTAssertEqual(result.ideas[0].text, "広がった発想")
    }

    func testInvalidClockAndMissingLivenessAreRejected() throws {
        var state = SharedStoreState(notebook: Notebook(tasks: [TaskItem(title: "検証")]))
        state.replica = try seeded(state.notebook)
        state.connection = SyncConnection(accountID: "owner", zoneName: "data", ownerName: "owner", isShared: false)
        state.replica?.clock = -1
        XCTAssertThrowsError(try SharedStoreState.decode(state.encoded()))
        let missing = SyncRecord(id: "task_\(UUID().uuidString)")
        XCTAssertThrowsError(try SyncRecord.decode(missing.encoded(), expectedID: missing.id))
    }
}
