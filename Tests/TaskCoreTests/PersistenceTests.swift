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

    func testOlderSaveWithoutNewerFieldsStillLoads() throws {
        let json = """
        {"version": 1, "tasks": [{"id": "00000000-0000-0000-0000-000000000001", "title": "古い保存",
          "createdAt": "2026-10-01T00:00:00Z", "steps": [{"id": "00000000-0000-0000-0000-000000000002", "title": "一手"}]}]}
        """
        let book = try NotebookCodec.decode(Data(json.utf8))
        XCTAssertEqual(book.tasks.first?.title, "古い保存")
        XCTAssertEqual(book.tasks.first?.effort, .medium)
        XCTAssertEqual(book.tasks.first?.handoff, "")
        XCTAssertEqual(book.tasks.first?.steps.first?.isDone, false)
        XCTAssertTrue(book.ideas.isEmpty)
    }

    func testSettingAsideUnreadableDataAllowsStartingOver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = NotebookRepository(url: directory.appendingPathComponent("notebook.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: repo.url)
        XCTAssertFalse(repo.hasPrevious)
        try repo.setAsideUnreadable()
        XCTAssertTrue(try repo.load().tasks.isEmpty)
        try repo.save(Notebook(tasks: [TaskItem(title: "再出発")]))
        XCTAssertEqual(try repo.load().tasks.first?.title, "再出発")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.contains("unreadable-") })
    }

    func testTaskTextImportKeepsAIHandoffSeparateFromNextActionAndMergesOnce() {
        let input = """
        # 2026-10-21
        - [ ] 10:00-11:00 | 前進 | 転職 | 資料を準備
          memo: 本人用のメモ
          next: AIに検索を頼む
          must: 1
        # いつでも
        - [ ] 牛乳を買う
        - [x] 終日 | - | - | 完了済み
        """
        let result = TaskTextImporter.parse(input)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.tasks.count, 3)
        XCTAssertEqual(result.tasks[0].handoff, "AIに検索を頼む")
        XCTAssertTrue(result.tasks[0].steps.isEmpty)
        XCTAssertTrue(result.tasks[0].isMust)
        XCTAssertEqual(result.tasks[0].kind, "前進")
        XCTAssertEqual(result.tasks[0].scheduledTime, "10:00-11:00")
        XCTAssertNil(result.tasks[1].plannedAt)
        XCTAssertTrue(result.tasks[2].isComplete)
        let twice = TaskTextImporter.merge(TaskTextImporter.parse(input).tasks, into: result.tasks)
        XCTAssertEqual(twice.count, 3)
    }

    func testInvalidDateDoesNotSilentlyBecomeAnotherDay() {
        let result = TaskTextImporter.parse("# 2026-02-30\n- [ ] 変換しない")
        XCTAssertTrue(result.tasks.isEmpty)
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testJapaneseHandoffLabelIsPreserved() {
        let result = TaskTextImporter.parse("# いつでも\n- [ ] 調べ物\n  引き継ぎ: 候補を探す")
        XCTAssertEqual(result.tasks.first?.handoff, "候補を探す")
    }
}
