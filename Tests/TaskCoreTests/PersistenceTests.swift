import XCTest
@testable import TaskCore

final class PersistenceTests: XCTestCase {
    func testRoundTripPreservesIndependentNotesAndActiveStep() throws {
        let step = Step(title: "一行書く")
        let task = TaskItem(title: "資料", memo: "自分のメモ", handoff: "AIへ依頼", resumeNote: "2ページ目", steps: [step])
        let book = Notebook(tasks: [task], ideas: [Idea(text: "思いつき")],
                            activeSession: Session(taskID: task.id, startedAt: Date(timeIntervalSince1970: 0), stepID: step.id))
        let decoded = try NotebookCodec.decode(NotebookCodec.encode(book))
        XCTAssertEqual(decoded.tasks[0].memo, "自分のメモ")
        XCTAssertEqual(decoded.tasks[0].handoff, "AIへ依頼")
        XCTAssertEqual(decoded.tasks[0].resumeNote, "2ページ目")
        XCTAssertEqual(decoded.activeSession?.stepID, step.id)
    }

    func testUnsupportedBackupAndDuplicateIDsRejected() throws {
        var book = Notebook()
        book.version = 9
        XCTAssertThrowsError(try NotebookCodec.decode(NotebookCodec.encode(book)))
        let task = TaskItem(title: "duplicate")
        book = Notebook(tasks: [task, task])
        XCTAssertThrowsError(try NotebookCodec.decode(NotebookCodec.encode(book)))
    }

    func testAtomicSaveAndRecoverWithoutDestroyingUnreadableData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = NotebookRepository(url: directory.appendingPathComponent("notebook.json"))
        try repo.save(Notebook(tasks: [TaskItem(title: "first")]))
        try repo.save(Notebook(tasks: [TaskItem(title: "second")]))
        XCTAssertEqual(try repo.load().tasks.first?.title, "second")
        try Data("broken".utf8).write(to: repo.url)
        XCTAssertThrowsError(try repo.load())
        XCTAssertThrowsError(try repo.save(Notebook()))
        XCTAssertEqual(try String(contentsOf: repo.url, encoding: .utf8), "broken")
        XCTAssertEqual(try repo.recoverPrevious().tasks.first?.title, "first")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.contains("unreadable-") })
    }

    func testStartingFreshKeepsUnreadableStateAndDoesNotMigrateAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SharedStoreRepository(directory: directory)
        try repo.legacy.save(Notebook(tasks: [TaskItem(title: "移行前")]))
        _ = try repo.load()
        try Data("broken".utf8).write(to: repo.url)
        XCTAssertThrowsError(try repo.load())
        XCTAssertTrue(try repo.startFresh().notebook.isEmpty)
        XCTAssertTrue(try repo.load().notebook.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.contains("unreadable-") })
    }
}
