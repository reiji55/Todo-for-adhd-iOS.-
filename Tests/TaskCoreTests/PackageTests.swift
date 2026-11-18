import XCTest
@testable import TaskCore

final class PackageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testAPackageSavedFromATaskPutsTheSamePiecesIntoAnother() throws {
        var book = Notebook(tasks: [TaskItem(title: "旅行の準備（京都）", createdAt: now)])
        let kyoto = book.tasks[0].id
        for name in ["荷造り", "レンタカーを手配", "宿の確認メール"] { book.addChild(TaskItem(title: name, createdAt: now), to: kyoto) }
        let id = try XCTUnwrap(book.savePackage(fromPiecesOf: kyoto, name: " 旅行の準備 ", at: now))
        XCTAssertEqual(book.packages.first?.name, "旅行の準備")
        XCTAssertEqual(book.packages.first?.items, ["荷造り", "レンタカーを手配", "宿の確認メール"])

        let sapporo = TaskItem(title: "旅行の準備（札幌）", plannedAt: now, createdAt: now)
        book.tasks.append(sapporo)
        XCTAssertEqual(book.applyPackage(id, to: sapporo.id, at: now.addingTimeInterval(60)), 3)
        XCTAssertEqual(book.children(of: sapporo.id).map(\.title), ["荷造り", "レンタカーを手配", "宿の確認メール"])
        XCTAssertNoThrow(try NotebookCodec.validate(book))

        // The same name writes over it.
        book.savePackage(name: "旅行の準備", items: ["荷造り", " ", "充電器"])
        XCTAssertEqual(book.packages.count, 1)
        XCTAssertEqual(book.packages.first?.items, ["荷造り", "充電器"])
    }

    func testRelatedTasksAreDueOnTheEventDayAndStayWhenTheEventGoes() throws {
        let trip = TaskItem(title: "京都旅行", plannedAt: now.addingTimeInterval(7 * 86400), project: "旅行", createdAt: now, isEvent: true)
        var book = Notebook(tasks: [trip], packages: [TaskPackage(name: "旅行の準備", items: ["荷造り", "レンタカーを手配"], createdAt: now)])
        XCTAssertEqual(book.applyPackage(book.packages[0].id, to: trip.id, at: now), 2)
        let related = book.relatedTasks(of: trip.id)
        XCTAssertEqual(related.map(\.title), ["荷造り", "レンタカーを手配"])
        XCTAssertTrue(related.allSatisfy { $0.deadline == trip.plannedAt && $0.project == "旅行" && !$0.isEvent && $0.parentID == nil })
        XCTAssertEqual(book.event(of: related[0])?.title, "京都旅行")

        // Checking the event off leaves its tasks as they are.
        book.toggleTask(trip.id, at: now)
        XCTAssertTrue(book.relatedTasks(of: trip.id).allSatisfy { !$0.isComplete })
        book.removeTask(trip.id)
        XCTAssertEqual(book.tasks.count, 2, "the tasks stay when the event goes")
        XCTAssertTrue(book.tasks.allSatisfy { $0.eventID == nil })
    }

    func testPackagesAndTheEventLinkSync() throws {
        var book = Notebook()
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: now)
        let before = book
        let trip = TaskItem(title: "京都旅行", plannedAt: now, createdAt: now, isEvent: true)
        book.tasks.append(trip)
        book.savePackage(name: "旅行の準備", items: ["荷造り"], at: now)
        book.applyPackage(book.packages[0].id, to: trip.id, at: now)
        try replica.apply(before: before, after: book, device: "phone", now: now.addingTimeInterval(1))
        let read = try replica.materialize()
        XCTAssertEqual(read.packages.map(\.name), ["旅行の準備"])
        XCTAssertEqual(read.relatedTasks(of: trip.id).map(\.title), ["荷造り"])
    }
}
