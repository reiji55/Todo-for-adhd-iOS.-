import XCTest
@testable import TaskCore

final class IdeaBundleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testNotesWithOneLabelAreOneBundleAndCanBeTakenOutOrUntied() {
        let move = Idea(text: "机を窓際に", createdAt: now)
        let light = Idea(text: "照明を替える", createdAt: now.addingTimeInterval(60))
        let save = Idea(text: "積立を見直す", createdAt: now.addingTimeInterval(120))
        var book = Notebook(ideas: [save, light, move])
        book.bundleIdeas([move.id, light.id], label: " 部屋 ")
        XCTAssertEqual(book.ideaBundles.map(\.label), ["部屋"])
        XCTAssertEqual(book.ideaBundles.first?.ideas.map(\.text), ["机を窓際に", "照明を替える"], "in the order written")

        book.bundleIdeas([save.id], label: "部屋")
        XCTAssertEqual(book.ideaBundles.first?.ideas.count, 3, "dropped on a bundle, it joins it")
        book.bundleIdeas([save.id], label: "")
        XCTAssertEqual(book.ideaBundles.first?.ideas.count, 2, "taken out, it is on its own again")

        book.renameBundle("部屋", to: "模様替え")
        XCTAssertEqual(book.ideaBundles.map(\.label), ["模様替え"])
        book.renameBundle("模様替え", to: "")
        XCTAssertTrue(book.ideaBundles.isEmpty)
        XCTAssertEqual(book.ideas.count, 3, "no note is lost")
    }

    func testTheLabelSyncsAndOldNotesOpenWithout() throws {
        var book = Notebook(ideas: [Idea(text: "机を窓際に", createdAt: now)])
        var replica = SyncReplica()
        try replica.apply(before: Notebook(), after: book, device: "seed", now: now)
        let before = book
        book.bundleIdeas(book.ideas.map(\.id), label: "部屋")
        try replica.apply(before: before, after: book, device: "phone", now: now.addingTimeInterval(1))
        XCTAssertEqual(try replica.materialize().ideas.first?.bundle, "部屋")

        let json = #"{"id":"0E6F5D7C-6B0B-4C59-9C1B-1A6A2F6D7F10","text":"古い付箋","createdAt":"2026-11-01T03:00:00Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Idea.self, from: Data(json.utf8)).bundle, "")
    }

    func testListsGoNewestFirstUntilPutInOrderAndANewOneGoesOnTop() {
        let old = StockList(name: "行きたいところ", createdAt: now)
        let newer = StockList(name: "読みたい本", createdAt: now.addingTimeInterval(60))
        var book = Notebook(lists: [old, newer])
        XCTAssertEqual(book.orderedLists.map(\.name), ["読みたい本", "行きたいところ"])
        book.reorderLists([old.id, newer.id])
        XCTAssertEqual(book.orderedLists.map(\.name), ["行きたいところ", "読みたい本"])
        book.lists.append(StockList(name: "買うもの", createdAt: now.addingTimeInterval(120), rank: book.topListRank))
        XCTAssertEqual(book.orderedLists.map(\.name), ["買うもの", "行きたいところ", "読みたい本"])
        let copy = book.duplicateList(old.id, name: "行きたいところのコピー", at: now.addingTimeInterval(180))
        XCTAssertEqual(book.orderedLists.first?.id, copy)
    }

    func testACheckedThingStaysInItsPlace() {
        let list = StockList(name: "買うもの", createdAt: now)
        let milk = ListItem(listID: list.id, title: "牛乳", createdAt: now)
        let bread = ListItem(listID: list.id, title: "パン", createdAt: now.addingTimeInterval(1))
        var book = Notebook(lists: [list], listItems: [milk, bread])
        book.setItemDone(milk.id, true, at: now.addingTimeInterval(2))
        XCTAssertEqual(book.openGroups(in: list.id, includingDone: true).first?.items.map(\.title), ["牛乳", "パン"])
        XCTAssertEqual(book.openGroups(in: list.id).first?.items.map(\.title), ["パン"])
    }
}
