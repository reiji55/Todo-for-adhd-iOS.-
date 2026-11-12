import XCTest
@testable import TaskCore

final class ListTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func later(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func shopping() -> (Notebook, StockList, [ListItem], TaskItem) {
        let list = StockList(name: "スーパー", createdAt: now)
        let items = [ListItem(listID: list.id, title: "卵", createdAt: now),
                     ListItem(listID: list.id, title: "牛乳", createdAt: later(1)),
                     ListItem(listID: list.id, title: "パン", createdAt: later(2))]
        let trip = TaskItem(title: "買い物：スーパー", createdAt: later(5), listID: list.id)
        return (Notebook(tasks: [trip], lists: [list], listItems: items), list, items, trip)
    }

    func testCheckingOffTheLastThingFinishesTheTripAndUndoReopensIt() {
        let (start, list, items, trip) = shopping()
        var book = start
        book.setItemDone(items[0].id, true, at: later(10))
        book.setItemDone(items[1].id, true, at: later(11))
        XCTAssertEqual(book.listProgress(of: book.tasks[0])?.done, 2)
        XCTAssertEqual(book.listProgress(of: book.tasks[0])?.total, 3)
        XCTAssertFalse(book.tasks[0].isComplete)
        book.setItemDone(items[2].id, true, at: later(12))
        XCTAssertEqual(book.tasks[0].completedAt, later(12), "the last check finishes the trip")
        XCTAssertEqual(book.doneItems(in: list.id).map(\.title), ["パン", "牛乳", "卵"], "history, latest first")
        book.setItemDone(items[2].id, false, at: later(13))
        XCTAssertFalse(book.tasks.first { $0.id == trip.id }!.isComplete, "undoing that check reopens the trip")
        XCTAssertEqual(book.openItems(in: list.id).map(\.title), ["パン"])
    }

    func testFinishingATripWithThingsLeftKeepsThemForNextTime() {
        let (start, list, items, trip) = shopping()
        var book = start
        book.setItemDone(items[0].id, true, at: later(10))
        book.toggleTask(trip.id, at: later(20))
        XCTAssertTrue(book.tasks[0].isComplete)
        XCTAssertEqual(book.openItems(in: list.id).map(\.title), ["牛乳", "パン"], "what was not bought stays on the list")
        // A later trip counts only from when it was made.
        let next = TaskItem(title: "買い物：スーパー", createdAt: later(30), listID: list.id)
        book.tasks.append(next)
        XCTAssertEqual(book.listProgress(of: next)?.done, 0)
        XCTAssertEqual(book.listProgress(of: next)?.total, 2)
        book.setItemDone(items[1].id, true, at: later(40))
        book.setItemDone(items[2].id, true, at: later(41))
        XCTAssertEqual(book.tasks.first { $0.id == next.id }?.completedAt, later(41))
        XCTAssertEqual(book.tasks.first { $0.id == trip.id }?.completedAt, later(20), "the earlier trip is left as it was")
    }

    func testAPlanMadeFromAThingMarksItAndItsCompletionMovesItToHistory() {
        let list = StockList(name: "行きたいところ", createdAt: now)
        let item = ListItem(listID: list.id, title: "美術館", place: "上野", createdAt: now)
        let visit = TaskItem(title: "美術館", plannedAt: later(60 * 24), createdAt: later(1), isEvent: true, listItemID: item.id)
        var book = Notebook(tasks: [visit], lists: [list], listItems: [item])
        XCTAssertEqual(book.plan(for: item.id)?.id, visit.id)
        book.toggleTask(visit.id, at: later(60 * 25))
        XCTAssertNil(book.plan(for: item.id))
        XCTAssertEqual(book.listItem(item.id)?.doneAt, later(60 * 25))
        book.toggleTask(visit.id, at: later(60 * 26))
        XCTAssertNil(book.listItem(item.id)?.doneAt, "undoing the plan puts the thing back on the list")
        XCTAssertEqual(book.plan(for: item.id)?.id, visit.id)
    }

    func testAnIdeaMovesOntoAListWithItsLinesAsTheMemo() {
        let list = StockList(name: "読みたい本", createdAt: now)
        let idea = Idea(text: "『百年の孤独』", createdAt: now, notes: [IdeaNote(text: "文庫版が出た", createdAt: now)])
        var book = Notebook(ideas: [idea], lists: [list])
        XCTAssertTrue(book.moveIdea(idea.id, toList: list.id, at: later(1)))
        XCTAssertTrue(book.ideas.isEmpty)
        XCTAssertEqual(book.openItems(in: list.id).first?.title, "『百年の孤独』")
        XCTAssertEqual(book.openItems(in: list.id).first?.memo, "文庫版が出た")
        XCTAssertFalse(book.moveIdea(idea.id, toList: list.id), "an idea already moved cannot move twice")
    }

    func testDuplicatingAndRemovingLists() {
        let (start, list, items, _) = shopping()
        var book = start
        book.setItemDone(items[0].id, true, at: later(10))
        let copy = book.duplicateList(list.id, name: "スーパー（週末）", at: later(20))!
        XCTAssertEqual(book.openItems(in: copy).map(\.title), ["牛乳", "パン"], "only what is still open is copied")
        book.removeList(list.id)
        XCTAssertNil(book.list(list.id))
        XCTAssertTrue(book.listItems.allSatisfy { $0.listID == copy })
        XCTAssertNil(book.listProgress(of: book.tasks[0]), "a task from a removed list no longer counts it")
    }

    func testListsSurviveSavingAndOlderSavesStillOpen() throws {
        let (book, _, _, _) = shopping()
        XCTAssertEqual(try NotebookCodec.decode(NotebookCodec.encode(book)), book)
        let old = Data(#"{"version":1,"tasks":[],"ideas":[],"boardCards":[]}"#.utf8)
        let decoded = try NotebookCodec.decode(old)
        XCTAssertTrue(decoded.lists.isEmpty && decoded.listItems.isEmpty)
    }

    func testTwoPeopleCheckingOffDifferentThingsBothCount() throws {
        let (book, list, items, _) = shopping()
        var seed = SyncReplica()
        try seed.apply(before: Notebook(), after: book, device: "seed", now: now)
        var a = seed, b = seed
        var first = book, second = book
        first.setItemDone(items[0].id, true, at: later(10))
        second.setItemDone(items[1].id, true, at: later(10))
        try a.apply(before: book, after: first, device: "phone", now: later(10))
        try b.apply(before: book, after: second, device: "partner", now: later(10))
        let originalA = a
        try a.merge(Array(b.records.values)); try b.merge(Array(originalA.records.values))
        XCTAssertEqual(a.records, b.records)
        let merged = try a.materialize()
        XCTAssertEqual(merged.openItems(in: list.id).map(\.title), ["パン"])
        XCTAssertEqual(merged.lists.map(\.name), ["スーパー"])
        XCTAssertEqual(merged.tasks.first?.listID, list.id)
    }

    func testJoiningKeepsADifferentListAsACopyWithItsThings() throws {
        let (remote, _, _, _) = shopping()
        var local = try NotebookCodec.decode(NotebookCodec.encode(remote))
        local.lists[0].name = "近所のスーパー"
        let preview = ShareMergePreview(local: local, remote: remote)
        XCTAssertEqual(Set(preview.combined.lists.map(\.name)), ["スーパー", "近所のスーパー"])
        let copy = try XCTUnwrap(preview.combined.lists.first { $0.name == "近所のスーパー" })
        XCTAssertEqual(preview.combined.openItems(in: copy.id).count, 3)
        XCTAssertEqual(preview.combined.listItems.count, 6)
    }

    func testHeadingsGroupWhatIsOpenWithoutHeadingFirst() throws {
        let list = StockList(name: "トルティーヤ", createdAt: now)
        let items = [ListItem(listID: list.id, title: "玉ねぎ", group: "共通", createdAt: now),
                     ListItem(listID: list.id, title: "合いびき肉", group: "タコミート", createdAt: later(1)),
                     ListItem(listID: list.id, title: "トルティーヤ", createdAt: later(2)),
                     ListItem(listID: list.id, title: "トマト", group: "共通", createdAt: later(3)),
                     ListItem(listID: list.id, title: "レタス", group: "タコミート", createdAt: later(4), doneAt: later(5))]
        let book = Notebook(lists: [list], listItems: items)
        let groups = book.openGroups(in: list.id)
        XCTAssertEqual(groups.map(\.heading), ["", "共通", "タコミート"])
        XCTAssertEqual(groups[1].items.map(\.title), ["玉ねぎ", "トマト"])
        XCTAssertEqual(groups[2].items.map(\.title), ["合いびき肉"], "done things are not listed under their heading")
        XCTAssertEqual(book.headings(in: list.id), ["共通", "タコミート"])
        // The heading travels and older records without it still open.
        XCTAssertEqual(try NotebookCodec.decode(NotebookCodec.encode(book)).listItems.map(\.group), items.map(\.group))
    }
}
