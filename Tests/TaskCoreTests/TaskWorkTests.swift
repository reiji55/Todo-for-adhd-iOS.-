import XCTest
@testable import TaskCore

final class TaskWorkTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_790_000_000)

    func testStartInterruptSaveRestartCompleteAndUndo() throws {
        let task = TaskItem(title: "添付を確認する", memo: "通常のメモ", handoff: "AIへの依頼", createdAt: time)
        var state = SharedStoreState(notebook: Notebook(tasks: [task]))
        state.bridge = true
        try state.startReplicaIfNeeded()
        var next = state.notebook
        XCTAssertTrue(next.startTask(task.id, at: time))
        try state.edit(next)
        let run = TaskWork(taskID: task.id, startedAt: time)
        XCTAssertEqual(run.elapsed(at: time.addingTimeInterval(90)), 90)

        // Interrupting ends only the local run. Saving a note neither completes nor reschedules.
        next = state.notebook
        XCTAssertTrue(next.saveTaskContinuation(task.id, note: "  宛先は確認済み。次はPDF。\n"))
        try state.edit(next)
        state = try SharedStoreState.decode(state.encoded())
        XCTAssertFalse(state.notebook.needsStepConversion)
        XCTAssertNil(state.notebook.activeSession)
        XCTAssertFalse(state.notebook.tasks[0].isComplete)
        XCTAssertNil(state.notebook.tasks[0].plannedAt)
        XCTAssertEqual(state.notebook.tasks[0].continuationNote, "宛先は確認済み。次はPDF。")
        XCTAssertEqual(state.notebook.tasks[0].memo, "通常のメモ")
        XCTAssertEqual(state.notebook.tasks[0].handoff, "AIへの依頼")

        let restart = time.addingTimeInterval(600)
        next = state.notebook
        XCTAssertTrue(next.startTask(task.id, at: restart))
        try state.edit(next)
        XCTAssertEqual(TaskWork(taskID: task.id, startedAt: restart).elapsed(at: restart), 0)
        let beforeCompletion = state.notebook
        next.toggleTask(task.id, at: restart.addingTimeInterval(20))
        try state.edit(next)
        XCTAssertTrue(state.notebook.tasks[0].isComplete)
        XCTAssertEqual(state.notebook.tasks[0].continuationNote, "")
        XCTAssertEqual(state.notebook.tasks[0].memo, "通常のメモ")

        // TaskStore's undo restores the prior notebook through this same edit/persistence route.
        try state.edit(beforeCompletion)
        let restored = try SharedStoreState.decode(state.encoded())
        XCTAssertFalse(restored.notebook.tasks[0].isComplete)
        XCTAssertEqual(restored.notebook.tasks[0].continuationNote, "宛先は確認済み。次はPDF。")
        XCTAssertEqual(try restored.replica?.materialize().tasks[0].continuationNote, "宛先は確認済み。次はPDF。")
    }

    func testCompletingOneChildClearsOnlyItsNoteAndOnlyAdvancesOnePiece() {
        let parent = TaskItem(title: "案内メール", memo: "親の通常メモ", createdAt: time, continuationNote: "親の続き")
        var book = Notebook(tasks: [parent])
        book.addChild(TaskItem(title: "宛先", createdAt: time, continuationNote: "宛先の続き"), to: parent.id)
        book.addChild(TaskItem(title: "添付", createdAt: time, continuationNote: "添付の続き"), to: parent.id)
        let children = book.children(of: parent.id)
        book.toggleTask(children[0].id, at: time)
        XCTAssertFalse(book.tasks.first { $0.id == parent.id }!.isComplete)
        XCTAssertEqual(book.children(of: parent.id).filter(\.isComplete).count, 1)
        XCTAssertEqual(book.children(of: parent.id)[0].continuationNote, "")
        XCTAssertEqual(book.children(of: parent.id)[1].continuationNote, "添付の続き")
        XCTAssertEqual(book.tasks.first { $0.id == parent.id }?.continuationNote, "親の続き")
        book.toggleTask(parent.id, at: time)
        XCTAssertTrue(book.tasks.allSatisfy(\.isComplete))
        XCTAssertTrue(book.tasks.allSatisfy { $0.continuationNote.isEmpty })
        XCTAssertEqual(book.tasks.first { $0.id == parent.id }?.memo, "親の通常メモ")
    }

    func testOlderBackupsAndLegacyNotesRemainIndependent() throws {
        let legacy = TaskItem(title: "書類", memo: "本人のメモ", resumeNote: "旧バージョンの続き", createdAt: time)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: NotebookCodec.encode(Notebook(tasks: [legacy]))) as? [String: Any])
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "continuationNote")
        json["tasks"] = tasks
        var decoded = try NotebookCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.tasks[0].continuationNote, "")
        XCTAssertTrue(decoded.saveTaskContinuation(legacy.id, note: "新しい一時メモ"))
        XCTAssertTrue(decoded.convertStepsToChildren(at: time))
        XCTAssertEqual(decoded.tasks[0].memo, "本人のメモ\n続き：旧バージョンの続き")
        XCTAssertEqual(decoded.tasks[0].continuationNote, "新しい一時メモ")
        XCTAssertFalse(decoded.needsStepConversion)
        decoded.toggleTask(legacy.id, at: time)
        XCTAssertEqual(decoded.tasks[0].continuationNote, "")
        XCTAssertTrue(decoded.tasks[0].memo.contains("旧バージョンの続き"))
    }

    func testBlankInputEventsAndCompletedTasksDoNotWriteTemporaryNotes() {
        let task = TaskItem(title: "書類", createdAt: time, continuationNote: "残すメモ")
        let event = TaskItem(title: "予定", createdAt: time, isEvent: true)
        let done = TaskItem(title: "済み", createdAt: time, completedAt: time)
        var book = Notebook(tasks: [task, event, done])
        XCTAssertFalse(book.saveTaskContinuation(task.id, note: " \n "))
        XCTAssertEqual(book.tasks[0].continuationNote, "残すメモ")
        XCTAssertFalse(book.saveTaskContinuation(event.id, note: "予定に一時メモは作らない"))
        XCTAssertFalse(book.saveTaskContinuation(done.id, note: "完了済みには書かない"))
        XCTAssertFalse(book.startTask(event.id, at: time))
        XCTAssertFalse(book.startTask(done.id, at: time))
        XCTAssertNil(book.activeSession)
    }

    func testConcurrentPermanentMemoAndContinuationEditsBothSurvive() throws {
        let task = TaskItem(title: "資料", memo: "元のメモ", createdAt: time)
        let original = Notebook(tasks: [task])
        var base = SyncReplica()
        try base.apply(before: Notebook(), after: original, device: "seed", now: time)
        var a = base, b = base
        var permanent = original, temporary = original
        permanent.tasks[0].memo = "別端末で編集した通常メモ"
        temporary.saveTaskContinuation(task.id, note: "次は図を入れる")
        try a.apply(before: original, after: permanent, device: "a", now: time.addingTimeInterval(10))
        try b.apply(before: original, after: temporary, device: "b", now: time.addingTimeInterval(10))
        try a.merge(Array(b.records.values))
        let merged = try a.materialize()
        XCTAssertEqual(merged.tasks[0].memo, "別端末で編集した通常メモ")
        XCTAssertEqual(merged.tasks[0].continuationNote, "次は図を入れる")
        let edited = try SyncReplica.editedTask(original: task, edited: permanent.tasks[0], current: merged.tasks[0])
        XCTAssertEqual(edited.continuationNote, "次は図を入れる", "an already open editor must not erase the new note")
    }

    func testCompletionFromOlderClientClearsStaleNoteAndSyncsTheClear() throws {
        let task = TaskItem(title: "資料", memo: "消さない", createdAt: time, continuationNote: "消す")
        var state = SharedStoreState(notebook: Notebook(tasks: [task]))
        state.bridge = true
        try state.startReplicaIfNeeded()
        let original = state.notebook
        var remote = try XCTUnwrap(state.replica)
        var completed = original
        completed.tasks[0].completedAt = time
        // Models an older app which does not know to clear continuationNote.
        try remote.apply(before: original, after: completed, device: "old-app", now: time.addingTimeInterval(50))
        try state.receive(Array(remote.records.values))
        XCTAssertEqual(state.notebook.tasks[0].continuationNote, "")
        XCTAssertEqual(state.notebook.tasks[0].memo, "消さない")
        XCTAssertTrue(state.hasPendingChanges)
        XCTAssertEqual(try state.replica?.materialize().tasks[0].continuationNote, "")
        let restored = try SharedStoreState.decode(state.encoded())
        XCTAssertEqual(restored.notebook.tasks[0].continuationNote, "")
    }

    func testRoutineContinuationAndRecordedTimeAreUnaffectedByTaskCompletion() {
        let task = TaskItem(title: "資料", createdAt: time, continuationNote: "資料の続き")
        let routine = Routine(title: "読書", createdAt: time, durations: ["2026-11-09": 600], resumeNote: "42ページから")
        var book = Notebook(tasks: [task], routines: [routine])
        book.toggleTask(task.id, at: time)
        XCTAssertEqual(book.routines, [routine])
    }
}
