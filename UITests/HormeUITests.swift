import XCTest

@MainActor
final class HormeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ scenario: String, dark: Bool = false, tab: Int = 2, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTab", String(tab), "-uiEnergy", "any", "-uiScenario", scenario,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchArguments += arguments
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

    private func input(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        return app.textFields[identifier].exists ? app.textFields[identifier] : app.textViews[identifier]
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

    func testIdeaFirstStepKeepsOptionalDetailsAndStartsOnToday() {
        let app = launch("idea", tab: 3, arguments: ["-uiOpenFirstIdea"])
        let convert = app.buttons["convertIdeaToTask"]
        XCTAssertTrue(convert.waitForExistence(timeout: 30))
        reveal(convert, in: app)
        XCTAssertTrue(app.buttons["convertIdeaToProject"].exists, "project conversion remains a separate visible path")
        capture(app, "idea-detail-keeps-project-conversion")
        convert.tap()
        _ = input("ideaFirstStep", in: app)
        let details = app.buttons["ideaTaskDetails"]
        XCTAssertEqual(details.value as? String, "閉じています")
        XCTAssertFalse(app.switches["アイデアを残す"].exists)
        capture(app, "idea-first-step-simple")
        details.tap()
        XCTAssertTrue(app.switches["アイデアを残す"].waitForExistence(timeout: 5))
        capture(app, "idea-first-step-optional-details")
        details.tap()
        app.buttons["createIdeaTaskAndStart"].tap()
        XCTAssertTrue(app.buttons["interruptTask"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["タスクにする"].exists)
        XCTAssertTrue(app.staticTexts["机を窓際に移したい"].exists)
        capture(app, "idea-first-step-running-on-today")
    }

    func testIdeaCanBecomeProjectAndStartItsFirstTask() {
        let app = launch("idea", tab: 3, arguments: ["-uiOpenFirstIdea"])
        let convert = app.buttons["convertIdeaToProject"]
        XCTAssertTrue(convert.waitForExistence(timeout: 30))
        reveal(convert, in: app)
        convert.tap()
        XCTAssertTrue(app.textFields["ideaProjectName"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["ideaProjectName"].value as? String, "机を窓際に移したい")
        capture(app, "idea-project-existing-options")
        app.buttons["addIdeaProject"].tap()
        let addStep = app.buttons["addProjectFirstStep"]
        XCTAssertTrue(addStep.waitForExistence(timeout: 15))
        reveal(addStep, in: app)
        capture(app, "new-project-first-step-empty")
        addStep.tap()
        let field = input("projectFirstStep", in: app)
        field.tap()
        field.typeText("Clear desk")
        capture(app, "project-create-first-step")
        app.buttons["createProjectTaskAndStart"].tap()
        XCTAssertTrue(app.buttons["interruptTask"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Clear desk"].exists)
        XCTAssertFalse(app.navigationBars["一手を追加"].exists)
        capture(app, "new-project-first-step-running")
    }

    func testProjectNextTaskStartsThroughExistingTodayCard() {
        let app = launch("project", tab: 4, arguments: ["-uiOpenFirstProject"])
        let start = app.buttons["startProjectNextTask"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        reveal(start, in: app)
        XCTAssertTrue(app.staticTexts["予想問題を1回分解く"].exists)
        capture(app, "project-mountain-next-step")
        start.tap()
        XCTAssertTrue(app.buttons["interruptTask"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["予想問題を1回分解く"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Part7の3問目から")).firstMatch.exists)
        capture(app, "project-next-step-running-on-today")
    }

    func testIdeaAndBoardUseMatchingLowerRightAddEntrances() {
        let ideas = launch("idea", tab: 3)
        let ideaAdd = ideas.buttons["addIdea"]
        XCTAssertTrue(ideaAdd.waitForExistence(timeout: 30))
        XCTAssertGreaterThan(ideaAdd.frame.midX, ideas.frame.width * 0.7)
        XCTAssertGreaterThan(ideaAdd.frame.midY, ideas.frame.height * 0.65)
        capture(ideas, "ideas-common-lower-right-add")
        let ideaPosition = ideaAdd.frame.origin
        ideas.terminate()

        let board = launch("project", tab: 4)
        let boardAdd = board.buttons["addBoardItem"]
        XCTAssertTrue(boardAdd.waitForExistence(timeout: 30))
        XCTAssertEqual(boardAdd.frame.minX, ideaPosition.x, accuracy: 1)
        XCTAssertEqual(boardAdd.frame.minY, ideaPosition.y, accuracy: 1)
        capture(board, "board-common-lower-right-add")
        boardAdd.tap()
        XCTAssertTrue(board.buttons["chooseBoardProject"].waitForExistence(timeout: 5))
        XCTAssertTrue(board.buttons["chooseBoardCard"].exists)
        capture(board, "board-contextual-add-sheet")
    }

    func testTimetableFoldsSecondarySectionsAndAlignsUntimedControl() {
        let app = launch("timetable")
        let timetable = app.buttons["openTimetable"]
        XCTAssertTrue(timetable.waitForExistence(timeout: 30))
        reveal(timetable, in: app)
        timetable.tap()
        let required = app.buttons["requiredFolder"]
        XCTAssertTrue(required.waitForExistence(timeout: 10))
        XCTAssertEqual(required.value as? String, "折りたたみ")
        XCTAssertFalse(app.staticTexts["提出期限の確認"].exists)
        capture(app, "timetable-folded-sections-light")
        required.tap()
        XCTAssertTrue(app.staticTexts["提出期限の確認"].waitForExistence(timeout: 5))
        required.tap()

        let timed = app.buttons["時間のあるタスクを完了"]
        reveal(timed, in: app)
        XCTAssertTrue(timed.exists)
        let railX = timed.frame.midX
        let untimed = app.buttons["洗濯物をたたむを完了"]
        reveal(untimed, in: app)
        XCTAssertTrue(untimed.exists)
        XCTAssertEqual(untimed.frame.midX, railX, accuracy: 1, "untimed controls share the timed rail axis")
        capture(app, "timetable-untimed-control-outside-card")
        let deadlines = app.buttons["deadlineFolder"]
        reveal(deadlines, in: app)
        XCTAssertTrue(deadlines.exists)
        XCTAssertEqual(deadlines.value as? String, "折りたたみ")
        deadlines.tap()
        XCTAssertTrue(app.staticTexts["来週の資料"].waitForExistence(timeout: 5))
        capture(app, "timetable-deadlines-expanded")
        app.terminate()

        let dark = launch("timetable", dark: true)
        let darkTimetable = dark.buttons["openTimetable"]
        XCTAssertTrue(darkTimetable.waitForExistence(timeout: 30))
        reveal(darkTimetable, in: dark)
        darkTimetable.tap()
        XCTAssertTrue(dark.buttons["requiredFolder"].waitForExistence(timeout: 10))
        capture(dark, "timetable-folded-sections-dark")
        reveal(dark.buttons["洗濯物をたたむを完了"], in: dark)
        capture(dark, "timetable-untimed-rail-dark")
    }
}
