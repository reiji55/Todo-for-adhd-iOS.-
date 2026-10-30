import XCTest
@testable import TaskCore

final class BoardCardTests: XCTestCase {
    func testProjectLinksToCardByNameLikeTaskThreeDays() {
        let toeic = BoardCard(title: "TOEIC対策")
        let life = BoardCard(title: "生活")
        let cards = [toeic, life]
        XCTAssertEqual(BoardLink.card(for: TaskItem(title: "単語", project: "TOEIC"), in: cards)?.id, toeic.id)
        XCTAssertEqual(BoardLink.card(for: TaskItem(title: "単語", project: "toeic 対策"), in: cards)?.id, toeic.id)
        XCTAssertEqual(BoardLink.card(for: TaskItem(title: "片付け", project: "生活リズム"), in: cards)?.id, life.id)
        XCTAssertNil(BoardLink.card(for: TaskItem(title: "日付なし"), in: cards))
        XCTAssertNil(BoardLink.card(for: TaskItem(title: "一文字", project: "T"), in: cards))
    }

    func testExactTitleWinsOverEarlierPartialMatch() {
        let broad = BoardCard(title: "仕事の段取り")
        let exact = BoardCard(title: "仕事")
        XCTAssertEqual(BoardLink.card(forProject: "仕事", in: [broad, exact])?.id, exact.id)
    }

    func testEachTaskBelongsToOneCard() {
        let a = BoardCard(title: "TOEIC"), b = BoardCard(title: "TOEIC対策")
        let task = TaskItem(title: "単語", project: "TOEIC")
        XCTAssertEqual(BoardLink.tasks(for: a, in: [task], cards: [a, b]).count, 1)
        XCTAssertTrue(BoardLink.tasks(for: b, in: [task], cards: [a, b]).isEmpty)
    }

    func testBoardFileImportKeepsFieldsAndSkipsDuplicates() throws {
        let json = """
        {"updated": "2026-09-12T15:34:48+09:00", "cards": [
          {"id": "toeic", "title": "TOEIC対策", "created": "2026-09-09", "goal": "650点", "purpose": "本番の練習", "detail": "1. 単語\\n2. Part5"},
          {"id": "x", "title": "  ", "detail": "見出しなし"},
          {"id": "y", "title": "瞑想手法1"}
        ]}
        """
        let data = Data(json.utf8)
        XCTAssertTrue(BoardImporter.isBoardFile(data))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let result = try BoardImporter.parse(data, calendar: calendar)
        XCTAssertEqual(result.cards.count, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.cards[0].goal, "650点")
        XCTAssertEqual(result.cards[0].purpose, "本番の練習")
        XCTAssertEqual(result.cards[0].detail, "1. 単語\n2. Part5")
        XCTAssertEqual(calendar.component(.day, from: result.cards[0].createdAt), 9)
        let merged = BoardImporter.merge(result.cards, into: [BoardCard(title: "toeic 対策")])
        XCTAssertEqual(merged.map(\.title), ["toeic 対策", "瞑想手法1"])
    }

    func testBackupIsNeverMistakenForBoardFile() throws {
        let backup = try NotebookCodec.encode(Notebook(boardCards: [BoardCard(title: "手順")]))
        XCTAssertFalse(BoardImporter.isBoardFile(backup))
        XCTAssertFalse(BoardImporter.isBoardFile(Data("not json".utf8)))
    }

    func testCardsSurviveSaveAndOlderSavesStillLoad() throws {
        let card = BoardCard(title: "TOEIC対策", purpose: "なぜ", goal: "どこまで", detail: "手順")
        let decoded = try NotebookCodec.decode(NotebookCodec.encode(Notebook(boardCards: [card])))
        XCTAssertEqual(decoded.boardCards, [card])

        // Saved by 0.2.x: no boardCards, and tasks without some later fields.
        let older = """
        {"version": 1, "ideas": [], "tasks": [{"id": "00000000-0000-0000-0000-000000000001", "title": "古い保存",
          "createdAt": "2026-10-01T00:00:00Z", "steps": [{"id": "00000000-0000-0000-0000-000000000002", "title": "一手"}]}]}
        """
        let book = try NotebookCodec.decode(Data(older.utf8))
        XCTAssertTrue(book.boardCards.isEmpty)
        XCTAssertEqual(book.tasks.first?.effort, .medium)
        XCTAssertEqual(book.tasks.first?.steps.first?.isDone, false)
    }

    func testUntitledOrDuplicateCardsAreRejected() throws {
        XCTAssertThrowsError(try NotebookCodec.decode(NotebookCodec.encode(Notebook(boardCards: [BoardCard(title: " ")]))))
        let card = BoardCard(title: "重複")
        XCTAssertThrowsError(try NotebookCodec.decode(NotebookCodec.encode(Notebook(boardCards: [card, card]))))
    }
}
