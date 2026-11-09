import XCTest

@MainActor
final class HormeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ scenario: String, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTab", "2", "-uiEnergy", "any", "-uiScenario", scenario,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        if dark { app.launchArguments += ["-uiDark"] }
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
    }

    func testInlineStartInterruptNoteRestartCompleteUndo() {
        let app = launch("task")
        let start = app.buttons["startNowItem"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        reveal(start, in: app)
        capture(app, "task-before-start-light")
        start.tap()
        let interrupt = app.buttons["interruptTask"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["始める"].exists, "work stays inside the existing card")
        capture(app, "task-working-light")
        interrupt.tap()
        let input = app.textFields["taskContinuationInput"]
        // SwiftUI's vertically expanding TextField may be exposed as a text view.
        let editor = input.exists ? input : app.textViews["taskContinuationInput"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        reveal(editor, in: app)
        capture(app, "task-interrupted-note-input")
        editor.tap()
        editor.typeText("Next: PDF")
        let save = app.buttons["saveTaskContinuation"]
        reveal(save, in: app)
        save.tap()
        XCTAssertFalse(editor.exists)
        for _ in 0..<3 where !start.isHittable { app.scrollViews.firstMatch.swipeDown() }
        start.tap()
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5))
        capture(app, "task-restarted-with-note")
        app.buttons["completeActiveTask"].tap()
        let undo = app.buttons["取り消す"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Next: PDF")).firstMatch.exists)
        capture(app, "task-completion-undone")
    }

    func testEventOnlyOffersDoneAndUndo() {
        let app = launch("event")
        let done = app.buttons["completeEvent"]
        XCTAssertTrue(done.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["startNowItem"].exists)
        XCTAssertFalse(app.buttons["入れ替える"].exists)
        capture(app, "event-done-only")
        done.tap()
        let undo = app.buttons["取り消す"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
    }

    func testRoutineKeepsExistingFocusAndTimer() {
        let app = launch("routine")
        let start = app.buttons["startNowItem"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()
        XCTAssertTrue(app.navigationBars["今やるひとつ"].waitForExistence(timeout: 10))
        capture(app, "routine-existing-focus")
        app.buttons["一覧へ"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.label.contains("計測中"))
        start.tap()
        XCTAssertTrue(app.navigationBars["今やるひとつ"].waitForExistence(timeout: 5))
        app.buttons["中断"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.label.contains("始める"))
    }

    func testFiveDatesStayFixedAndShowNotesInDarkMode() {
        let app = launch("memo", dark: true)
        XCTAssertTrue(app.buttons["startNowItem"].waitForExistence(timeout: 30))
        capture(app, "today-with-notes-dark")
        let timetable = app.buttons["openTimetable"]
        reveal(timetable, in: app)
        timetable.tap()
        let today = app.buttons["timetableDay0"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        let center = today.frame.midX
        for offset in -2...2 { XCTAssertTrue(app.buttons["timetableDay\(offset)"].exists) }
        capture(app, "timetable-five-dates-dark")
        app.buttons["timetableDay-2"].tap()
        XCTAssertTrue(app.staticTexts["一昨日の時間割"].waitForExistence(timeout: 5))
        XCTAssertEqual(today.frame.midX, center, accuracy: 1)
        app.buttons["timetableDay2"].tap()
        XCTAssertTrue(app.staticTexts["明後日の時間割"].waitForExistence(timeout: 5))
        XCTAssertEqual(today.frame.midX, center, accuracy: 1)
        app.buttons["timetableDay0"].tap()
        XCTAssertTrue(app.staticTexts["今日の時間割"].waitForExistence(timeout: 5))
    }
}
