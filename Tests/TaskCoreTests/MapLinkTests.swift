import XCTest
@testable import TaskCore

final class MapLinkTests: XCTestCase {
    func testGooglePlaceLinkGivesNameAndThePlacesOwnPoint() throws {
        let url = try XCTUnwrap(URL(string: "https://www.google.com/maps/place/%E6%9D%B1%E4%BA%AC%E9%A7%85/@35.6812362,139.7645445,17z/data=!3m1!4b1!4m6!3m5!1s0x60188bfbd89f700b:0x277c49ba34ed38!8m2!3d35.6812362!4d139.7671248"))
        let place = try XCTUnwrap(MapLink.parse(url))
        XCTAssertEqual(place.name, "東京駅")
        XCTAssertEqual(try XCTUnwrap(place.latitude), 35.6812362, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(place.longitude), 139.7671248, accuracy: 1e-6, "the place's own point, not the view's centre")
    }

    func testPlusSignsInNamesAreSpaces() throws {
        let url = try XCTUnwrap(URL(string: "https://www.google.com/maps/place/Blue+Bottle+Coffee/@35.65,139.70,15z"))
        XCTAssertEqual(MapLink.parse(url)?.name, "Blue Bottle Coffee")
        XCTAssertEqual(MapLink.parse(url)?.latitude, 35.65)
    }

    func testSearchLinksAndCoordinatesInQ() throws {
        let named = try XCTUnwrap(URL(string: "https://www.google.com/maps/search/?api=1&query=%E9%8E%8C%E5%80%89"))
        XCTAssertEqual(MapLink.parse(named)?.name, "鎌倉")
        XCTAssertNil(MapLink.parse(named)?.latitude)
        let point = try XCTUnwrap(URL(string: "https://maps.google.com/?q=35.0116,135.7681"))
        let place = try XCTUnwrap(MapLink.parse(point))
        XCTAssertEqual(place.name, "")
        XCTAssertEqual(place.latitude, 35.0116)
        XCTAssertEqual(place.longitude, 135.7681)
    }

    func testAppleMapsLink() throws {
        let url = try XCTUnwrap(URL(string: "https://maps.apple.com/?ll=35.7101,139.8107&q=%E6%9D%B1%E4%BA%AC%E3%82%B9%E3%82%AB%E3%82%A4%E3%83%84%E3%83%AA%E3%83%BC"))
        let place = try XCTUnwrap(MapLink.parse(url))
        XCTAssertEqual(place.name, "東京スカイツリー")
        XCTAssertEqual(place.latitude, 35.7101)
        XCTAssertEqual(place.longitude, 139.8107)
    }

    func testConsentPageCarriesTheRealLink() throws {
        let inner = "https://www.google.com/maps/place/Kyoto+Station/@34.985,135.758,17z"
        var components = URLComponents(string: "https://consent.google.com/m")!
        components.queryItems = [URLQueryItem(name: "continue", value: inner)]
        let place = try XCTUnwrap(MapLink.parse(try XCTUnwrap(components.url)))
        XCTAssertEqual(place.name, "Kyoto Station")
        XCTAssertEqual(place.latitude, 34.985)
    }

    func testShortLinksSayNothingUntilFollowed() throws {
        let url = try XCTUnwrap(URL(string: "https://maps.app.goo.gl/AbCdEf123"))
        XCTAssertTrue(MapLink.isMap(url))
        XCTAssertTrue(MapLink.isShort(url))
        XCTAssertNil(MapLink.parse(url))
        XCTAssertFalse(MapLink.isMap(try XCTUnwrap(URL(string: "https://www.amazon.co.jp/dp/B000"))))
    }

    func testListItemKeepsItsPointThroughCodingAndSync() throws {
        let list = StockList(name: "行きたい")
        let item = ListItem(listID: list.id, title: "東京駅", place: "東京駅", latitude: 35.68, longitude: 139.76)
        var book = Notebook()
        book.lists = [list]; book.listItems = [item]
        let decoded = try NotebookCodec.decode(NotebookCodec.encode(book))
        XCTAssertEqual(decoded.listItems.first?.latitude, 35.68)
        XCTAssertEqual(decoded.listItems.first?.longitude, 139.76)
        let older = try JSONDecoder.isoTest.decode(ListItem.self, from: Data(#"{"id":"\#(item.id.uuidString)","listID":"\#(list.id.uuidString)","title":"x","createdAt":"2026-11-01T00:00:00Z"}"#.utf8))
        XCTAssertNil(older.latitude, "items saved before places had points still open")
    }
}

private extension JSONDecoder {
    static var isoTest: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
