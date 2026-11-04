import XCTest
@testable import TaskCore

final class ProjectTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 100)
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func seeded(_ book: Notebook) throws -> SyncReplica {
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: epoch)
        return replica
    }

    func testProjectWithCheckpointsSurvivesSyncInOrder() throws {
        let project = Project(name: "TOEIC", goal: "本番で500点", deadline: created, milestones: [
            Milestone(title: "単語帳を1周", kind: .check, isDone: true, createdAt: created),
            Milestone(title: "予想問題を解く", kind: .count, target: 5, current: 3, unit: "回", createdAt: created),
            Milestone(title: "模試", kind: .number, target: 450, current: 420, unit: "点", createdAt: created)
        ], origin: "TOEICやる", createdAt: created, overview: "転職の条件。単語は毎日、長文は時間を計って")
        let book = Notebook(boardCards: [BoardCard(title: "単語のやり方", createdAt: created, project: "TOEIC")], projects: [project])
        let restored = try seeded(book).materialize()
        XCTAssertEqual(restored.projects, [project])
        XCTAssertEqual(restored.boardCards[0].project, "TOEIC")
    }

    func testEditsToDifferentCheckpointsOnTwoDevicesBothSurvive() throws {
        let first = Milestone(title: "予想問題", kind: .count, target: 5, createdAt: created)
        let second = Milestone(title: "模試", kind: .number, target: 450, createdAt: created)
        let book = Notebook(projects: [Project(name: "TOEIC", milestones: [first, second], createdAt: created)])
        var a = try seeded(book), b = a
        var onA = book; onA.projects[0].milestones[0].current = 1
        var onB = book; onB.projects[0].milestones[1].current = 420; onB.projects[0].goal = "500点"
        try a.apply(before: book, after: onA, device: "a", now: Date(timeIntervalSince1970: 200))
        try b.apply(before: book, after: onB, device: "b", now: Date(timeIntervalSince1970: 300))
        try a.merge(Array(b.records.values))
        let merged = try a.materialize().projects[0]
        XCTAssertEqual(merged.milestones.map(\.current), [1, 420])
        XCTAssertEqual(merged.goal, "500点")
    }

    func testRemovingACheckpointRemovesItAfterSync() throws {
        let book = Notebook(projects: [Project(name: "引っ越し", milestones: [Milestone(title: "物件"), Milestone(title: "解約")],
                                               createdAt: created)])
        var replica = try seeded(book)
        var edited = book; edited.projects[0].milestones.removeFirst()
        try replica.apply(before: book, after: edited, device: "a", now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try replica.materialize().projects[0].milestones.map(\.title), ["解約"])
    }

    func testCountsAddHandTapsDoneTasksAndRoutineDaysSinceTheCheckpoint() {
        let calendar = Calendar(identifier: .gregorian)
        let start = DayKey.date("2026-11-01", calendar: calendar)!
        let count = Milestone(title: "予想問題", kind: .count, target: 5, current: 1, createdAt: start)
        let tasks = Milestone(title: "Part7", kind: .tasks, createdAt: start)
        var routine = Routine(title: "金フレ", project: "TOEIC", milestoneID: count.id)
        routine.doneDays = ["2026-10-31", "2026-11-01", "2026-11-02"]
        let book = Notebook(tasks: [
            TaskItem(title: "第3回", project: "TOEIC", completedAt: start, milestoneID: count.id),
            TaskItem(title: "第4回", project: "TOEIC", milestoneID: count.id),
            TaskItem(title: "10問", project: "TOEIC", completedAt: start, milestoneID: tasks.id),
            TaskItem(title: "解き直し", project: "TOEIC", milestoneID: tasks.id),
            TaskItem(title: "復習", project: "TOEIC", milestoneID: tasks.id)
        ], routines: [routine], projects: [Project(name: "TOEIC", milestones: [count, tasks])])
        XCTAssertEqual(ProjectBook.value(of: count, in: book, calendar: calendar), 4)
        XCTAssertEqual(ProjectBook.progress(of: count, in: book, calendar: calendar), 0.8, accuracy: 0.001)
        XCTAssertEqual(ProjectBook.progress(of: tasks, in: book), 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(ProjectBook.progress(of: "toeic", in: book)!, (0.8 + 1.0 / 3) / 2, accuracy: 0.01)
        XCTAssertEqual(ProjectBook.next(of: book.projects[0], in: book)?.title, "予想問題")
    }

    func testNumbersCapAtTheTargetAndProjectsWithoutCheckpointsUseTheirTasks() {
        let score = Milestone(title: "模試", kind: .number, target: 450, current: 500)
        let book = Notebook(tasks: [TaskItem(title: "a", project: "仕事", completedAt: epoch), TaskItem(title: "b", project: "仕事")],
                            projects: [Project(name: "TOEIC", milestones: [score])])
        XCTAssertEqual(ProjectBook.progress(of: score, in: book), 1)
        XCTAssertEqual(ProjectBook.progress(of: "仕事", in: book), 0.5)
        XCTAssertNil(ProjectBook.progress(of: "部屋", in: book))
    }

    func testEntriesListSavedProjectsThenNamesInUse() {
        let book = Notebook(tasks: [TaskItem(title: "a", project: "仕事"), TaskItem(title: "b", project: "仕事 "),
                                    TaskItem(title: "c", project: "古い", completedAt: epoch), TaskItem(title: "d", project: "toeic")],
                            boardCards: [BoardCard(title: "手順", project: "引っ越し"), BoardCard(title: "瞑想手法")],
                            routines: [Routine(title: "片付け", project: "部屋", isPaused: true)],
                            projects: [Project(name: "TOEIC")])
        XCTAssertEqual(ProjectBook.entries(book).map(\.name), ["TOEIC", "仕事", "引っ越し"])
        XCTAssertNotNil(ProjectBook.entries(book)[0].project)
    }

    func testCardsJoinTheProjectTheirTasksNameMost() {
        let toeic = BoardCard(title: "TOEIC対策"), alone = BoardCard(title: "瞑想手法")
        var book = Notebook(tasks: [TaskItem(title: "a", project: "TOEIC"), TaskItem(title: "b", project: "TOEIC対策"),
                                    TaskItem(title: "c", project: "toeic")],
                            boardCards: [toeic, alone], routines: [Routine(title: "金フレ", project: "TOEIC")])
        ProjectBook.moveCardsIntoProjects(&book)
        XCTAssertEqual(book.boardCards.map(\.project), ["TOEIC", ""])
        XCTAssertEqual(book.tasks.map(\.project), ["TOEIC", "TOEIC", "toeic"])
        XCTAssertEqual(book.routines[0].project, "TOEIC")
        let again = book
        ProjectBook.moveCardsIntoProjects(&book)
        XCTAssertEqual(book, again)
    }

    func testRenameAndRemoveReachEverythingWithTheName() {
        let milestone = Milestone(title: "予想問題", kind: .count, target: 5)
        var book = Notebook(tasks: [TaskItem(title: "a", project: "TOEIC", milestoneID: milestone.id)],
                            boardCards: [BoardCard(title: "やり方", project: "toeic")],
                            routines: [Routine(title: "金フレ", project: "TOEIC", milestoneID: milestone.id)],
                            projects: [Project(name: "TOEIC", milestones: [milestone])])
        ProjectBook.rename("toeic", to: "英語", in: &book)
        XCTAssertEqual([book.projects[0].name, book.tasks[0].project, book.boardCards[0].project, book.routines[0].project],
                       ["英語", "英語", "英語", "英語"])
        ProjectBook.remove("英語", from: &book)
        XCTAssertTrue(book.projects.isEmpty)
        XCTAssertEqual(book.tasks[0].project, "")
        XCTAssertNil(book.tasks[0].milestoneID)
        XCTAssertNil(book.routines[0].milestoneID)
        XCTAssertEqual(book.boardCards[0].project, "")
    }

    func testOlderSavesWithoutProjectsStillOpen() throws {
        let json = #"{"version":1,"tasks":[],"ideas":[],"boardCards":[{"id":"7D2A0A39-4E52-4A39-9F1F-0B4C3C7C0A11","title":"手順","createdAt":"2026-10-01T00:00:00Z"}],"routines":[]}"#
        let book = try NotebookCodec.decode(Data(json.utf8))
        XCTAssertEqual(book.projects, [])
        XCTAssertEqual(book.boardCards[0].project, "")
    }
}
