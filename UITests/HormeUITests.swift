import XCTest
import CoreGraphics

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

    private func scrollContainer(for element: XCUIElement, in app: XCUIApplication,
                                 preferred: XCUIElement? = nil) -> XCUIElement {
        if let preferred { return preferred }
        let identifier = element.exists ? element.identifier : ""
        if !identifier.isEmpty {
            let matching = app.scrollViews.containing(.any, identifier: identifier).firstMatch
            if matching.exists { return matching }
        }
        return app.scrollViews.firstMatch
    }

    /// An actual user-visible touch point, rather than AX's sometimes offscreen activation point.
    /// A wide last row may have a border under the raised Today circle while its label is fully clear.
    private func visiblePoint(_ element: XCUIElement, in app: XCUIApplication,
                              scroll: XCUIElement) -> CGPoint? {
        guard element.exists, element.isHittable, !element.frame.isEmpty else { return nil }
        var viewport = scroll.frame.intersection(app.frame)
        let scrollBottom = viewport.maxY
        for bar in app.navigationBars.allElementsBoundByIndex where bar.isHittable {
            viewport.origin.y = max(viewport.minY, bar.frame.maxY)
        }
        let tabNames = ["すべて", "週", "ストック", "ボード"]
        let regularTabs = app.buttons.matching(NSPredicate(format: "label IN %@", tabNames))
            .allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.height >= 40
                && $0.frame.minY > app.frame.height * 0.65 && $0.frame.maxY > app.frame.maxY - 24
        }
        var bottom = min(scrollBottom, regularTabs.map { $0.frame.minY - 8 }.min() ?? scrollBottom)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        viewport.size.height = max(0, bottom - viewport.minY)
        viewport = viewport.insetBy(dx: 4, dy: 4)
        let target = element.frame.intersection(viewport)
        guard target.width >= 8, target.height >= 8 else { return nil }
        let raisedToday = app.buttons.matching(NSPredicate(format: "label == %@", "今日"))
            .allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.height >= 60 && $0.frame.maxY > app.frame.maxY - 24
            }.map { $0.frame.insetBy(dx: -2, dy: -2) }
        let addButtons = app.buttons.matching(NSPredicate(format: "label == %@", "追加する"))
            .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY > app.frame.height * 0.55 }
            .map { $0.frame.insetBy(dx: -2, dy: -2) }
        let blocked = raisedToday + addButtons
        let points = [CGPoint(x: target.midX, y: target.midY),
                      CGPoint(x: target.minX + target.width * 0.25, y: target.midY),
                      CGPoint(x: target.minX + target.width * 0.75, y: target.midY)]
        return points.first { point in !blocked.contains { $0.contains(point) } }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scroll: XCUIElement? = nil) {
        let container = scrollContainer(for: element, in: app, preferred: scroll)
        for attempt in 0..<9 {
            if visiblePoint(element, in: app, scroll: container) != nil { return }
            let viewport = container.frame.intersection(app.frame).insetBy(dx: 4, dy: 24)
            guard viewport.width > 40 && viewport.height > 80 else {
                XCTFail("No scroll viewport for \(element.identifier)")
                return
            }
            let needsEarlierContent = element.exists && element.frame.midY < viewport.minY
            let down = needsEarlierContent || (!element.exists && attempt >= 5)
            let startY = viewport.minY + viewport.height * (down ? 0.3 : 0.7)
            let endY = viewport.minY + viewport.height * (down ? 0.7 : 0.3)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: viewport.midX, dy: endY)))
        }
        XCTFail("Could not reveal \(element.identifier) within the unobstructed viewport")
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication, scroll: XCUIElement? = nil) {
        let container = scrollContainer(for: element, in: app, preferred: scroll)
        reveal(element, in: app, scroll: container)
        guard let point = visiblePoint(element, in: app, scroll: container) else {
            XCTFail("No unobstructed touch point for \(element.identifier)")
            return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
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
        tapVisible(start, in: app)
        let interrupt = app.buttons["interruptTask"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["始める"].exists, "work stays inside the existing card")
        capture(app, "task-working-light")
        tapVisible(interrupt, in: app)
        let input = app.textFields["taskContinuationInput"]
        // SwiftUI's vertically expanding TextField may be exposed as a text view.
        let editor = input.exists ? input : app.textViews["taskContinuationInput"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        reveal(editor, in: app)
        capture(app, "task-interrupted-note-input")
        tapVisible(editor, in: app)
        editor.typeText("Next: PDF")
        let save = app.buttons["saveTaskContinuation"]
        reveal(save, in: app)
        tapVisible(save, in: app)
        XCTAssertFalse(editor.exists)
        reveal(start, in: app)
        tapVisible(start, in: app)
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5))
        capture(app, "task-restarted-with-note")
        tapVisible(app.buttons["completeActiveTask"], in: app)
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
        tapVisible(done, in: app)
        let undo = app.buttons["取り消す"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
    }

    func testRoutineKeepsExistingFocusAndTimer() {
        let app = launch("routine")
        let start = app.buttons["startNowItem"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        tapVisible(start, in: app)
        XCTAssertTrue(app.navigationBars["今やるひとつ"].waitForExistence(timeout: 10))
        capture(app, "routine-existing-focus")
        app.buttons["一覧へ"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.label.contains("計測中"))
        tapVisible(start, in: app)
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
        tapVisible(timetable, in: app)
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
        tapVisible(convert, in: app)
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
        tapVisible(convert, in: app)
        XCTAssertTrue(app.textFields["ideaProjectName"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["ideaProjectName"].value as? String, "机を窓際に移したい")
        capture(app, "idea-project-existing-options")
        app.buttons["addIdeaProject"].tap()
        let addStep = app.buttons["addProjectFirstStep"]
        XCTAssertTrue(addStep.waitForExistence(timeout: 15))
        reveal(addStep, in: app)
        capture(app, "new-project-first-step-empty")
        tapVisible(addStep, in: app)
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
        // Leave Today with its timetable pushed. A genuinely new external start must dismiss that
        // destination once, unlike an ordinary return to the Today tab.
        let app = launch("project", arguments: ["-uiOpenFirstProject"])
        let timetable = app.buttons["openTimetable"]
        XCTAssertTrue(timetable.waitForExistence(timeout: 30))
        tapVisible(timetable, in: app)
        XCTAssertTrue(app.navigationBars["時間割"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == %@", "ボード")).firstMatch.tap()
        let start = app.buttons["startProjectNextTask"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        reveal(start, in: app)
        XCTAssertTrue(app.staticTexts["予想問題を1回分解く"].exists)
        capture(app, "project-mountain-next-step")
        tapVisible(start, in: app)
        XCTAssertTrue(app.buttons["interruptTask"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["時間割"].exists)
        XCTAssertTrue(app.buttons["interruptTask"].isHittable, "the explicitly requested running card must be on screen without a reveal")
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
        tapVisible(timetable, in: app)
        XCTAssertTrue(app.buttons["requiredFolder"].waitForExistence(timeout: 10))
        let schedule = app.scrollViews.containing(.button, identifier: "requiredFolder").firstMatch
        XCTAssertTrue(schedule.exists)
        // What is due today starts open, so it cannot be missed; it still folds and opens again.
        let required = schedule.buttons["requiredFolder"]
        XCTAssertEqual(required.value as? String, "展開中")
        XCTAssertTrue(schedule.staticTexts["提出期限の確認"].waitForExistence(timeout: 5))
        capture(app, "timetable-required-open-light")
        reveal(required, in: app, scroll: schedule)
        tapVisible(required, in: app, scroll: schedule)
        XCTAssertEqual(required.value as? String, "折りたたみ")
        XCTAssertFalse(schedule.staticTexts["提出期限の確認"].exists)
        reveal(required, in: app, scroll: schedule)
        tapVisible(required, in: app, scroll: schedule)
        XCTAssertEqual(required.value as? String, "展開中")

        // The hidden home/candidate view can expose another completion control for the same task.
        // Scope the geometry check to the visible full timetable, rather than accepting a background match.
        let timed = schedule.buttons["時間のあるタスクを完了"].firstMatch
        reveal(timed, in: app, scroll: schedule)
        XCTAssertTrue(timed.exists)
        let railX = timed.frame.midX
        let untimed = schedule.buttons["洗濯物をたたむを完了"].firstMatch
        reveal(untimed, in: app, scroll: schedule)
        XCTAssertTrue(untimed.exists)
        XCTAssertEqual(untimed.frame.midX, railX, accuracy: 1, "untimed controls share the timed rail axis")
        capture(app, "timetable-untimed-control-outside-card")
        let deadlines = schedule.buttons["deadlineFolder"]
        reveal(deadlines, in: app, scroll: schedule)
        XCTAssertTrue(deadlines.exists)
        XCTAssertEqual(deadlines.value as? String, "折りたたみ")
        tapVisible(deadlines, in: app, scroll: schedule)
        XCTAssertTrue(app.navigationBars["時間割"].exists, "expanding deadlines must stay on the timetable")
        XCTAssertEqual(deadlines.value as? String, "展開中")
        XCTAssertTrue(schedule.staticTexts["来週の資料"].waitForExistence(timeout: 5))
        reveal(schedule.staticTexts["来週の資料"], in: app, scroll: schedule)
        capture(app, "timetable-deadlines-expanded")
        app.terminate()

        let dark = launch("timetable", dark: true)
        let darkTimetable = dark.buttons["openTimetable"]
        XCTAssertTrue(darkTimetable.waitForExistence(timeout: 30))
        reveal(darkTimetable, in: dark)
        tapVisible(darkTimetable, in: dark)
        XCTAssertTrue(dark.buttons["requiredFolder"].waitForExistence(timeout: 10))
        capture(dark, "timetable-folded-sections-dark")
        let darkSchedule = dark.scrollViews.containing(.button, identifier: "requiredFolder").firstMatch
        reveal(darkSchedule.buttons["洗濯物をたたむを完了"].firstMatch, in: dark, scroll: darkSchedule)
        capture(dark, "timetable-untimed-rail-dark")
    }

    func testDayFlowScrollsOpensTimetableAndCandidateDrawerFiltersAndEdits() {
        let app = launch("timetable")
        let dayFlow = app.descendants(matching: .any).matching(identifier: "dayFlowTimeline").firstMatch
        XCTAssertTrue(dayFlow.waitForExistence(timeout: 30))
        let home = app.scrollViews.containing(.button, identifier: "openDayFlowTimetable").firstMatch
        reveal(dayFlow, in: app, scroll: home)
        let before = dayFlow.screenshot().pngRepresentation
        capture(app, "restored-day-flow-before-horizontal-scroll")
        dayFlow.swipeLeft()
        // At the end of the day the initial position can already be at the rightmost limit.
        if dayFlow.screenshot().pngRepresentation == before { dayFlow.swipeRight() }
        XCTAssertFalse(app.navigationBars["時間割"].exists, "horizontal scrolling must stay on Today")
        XCTAssertNotEqual(dayFlow.screenshot().pngRepresentation, before, "the horizontal time axis must visibly move")
        capture(app, "restored-day-flow-after-horizontal-scroll")
        tapVisible(dayFlow, in: app, scroll: home)
        XCTAssertTrue(app.navigationBars["時間割"].waitForExistence(timeout: 10))

        let drawer = app.buttons["toggleCandidateDrawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertEqual(drawer.label, "今できそうなものを開く")
        drawer.tap()
        XCTAssertEqual(drawer.label, "候補を閉じる")
        let energy = app.segmentedControls["candidateEnergy"].firstMatch
        XCTAssertTrue(energy.waitForExistence(timeout: 5))
        let panel = app.scrollViews.containing(.segmentedControl, identifier: "candidateEnergy").firstMatch
        XCTAssertTrue(panel.exists)
        let laundry = panel.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@",
                                                         "洗濯物をたたむ", "を完了")).firstMatch
        energy.buttons["軽めから"].tap()
        XCTAssertTrue(energy.buttons["軽めから"].isSelected)
        XCTAssertFalse(laundry.exists, "the medium-effort task must be excluded by the light filter")
        capture(app, "restored-candidate-drawer-light-filter")
        energy.buttons["いつも通り"].tap()
        XCTAssertTrue(energy.buttons["いつも通り"].isSelected)
        XCTAssertTrue(laundry.waitForExistence(timeout: 5))
        reveal(laundry, in: app, scroll: panel)
        capture(app, "restored-candidate-drawer-open")
        tapVisible(laundry, in: app, scroll: panel)
        XCTAssertTrue(app.navigationBars["タスクを編集"].waitForExistence(timeout: 10))
        let title = NSPredicate(format: "value == %@", "洗濯物をたたむ")
        XCTAssertTrue(app.textFields.matching(title).firstMatch.exists || app.textViews.matching(title).firstMatch.exists)
        capture(app, "restored-candidate-task-editor")
        app.buttons["キャンセル"].firstMatch.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        drawer.tap()
        XCTAssertEqual(drawer.label, "今できそうなものを開く")
        XCTAssertTrue(app.navigationBars["時間割"].exists)
    }
    func testClosedTodayIsNotAutomaticallyReopenedByIdeaStart() {
        // Open Today first so the existing Debug preview closes this day before moving to Ideas.
        let app = launch("idea", arguments: ["-uiDayClosed", "-uiOpenFirstIdea"])
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 30))
        let ideasTab = app.buttons.matching(NSPredicate(format: "label == %@", "ストック")).firstMatch
        XCTAssertTrue(ideasTab.exists)
        ideasTab.tap()
        let convert = app.buttons["convertIdeaToTask"]
        XCTAssertTrue(convert.waitForExistence(timeout: 15))
        tapVisible(convert, in: app)
        XCTAssertTrue(app.buttons["createIdeaTaskAndStart"].waitForExistence(timeout: 10))
        tapVisible(app.buttons["createIdeaTaskAndStart"], in: app)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "今日は終了しています")).firstMatch.exists)
        capture(app, "closed-day-start-keeps-existing-reopen-choice")
        alert.buttons["閉じる"].firstMatch.tap()
        let creation = app.navigationBars["タスクにする"]
        XCTAssertTrue(creation.exists, "the saved task must remain available after the rejected start")
        XCTAssertTrue(app.staticTexts["1件のタスクを追加しました"].exists)
        tapVisible(app.buttons["createIdeaTaskAndStart"], in: app)
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "今日は終了しています")).firstMatch.exists)
        alert.buttons["閉じる"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1件のタスクを追加しました"].exists, "retrying a rejected start must not add a second task")
        creation.buttons["閉じる"].firstMatch.tap()
        let todayTab = app.buttons.matching(NSPredicate(format: "label == %@", "今日")).firstMatch
        XCTAssertTrue(todayTab.waitForExistence(timeout: 10))
        todayTab.tap()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 10), "starting an idea must not silently reopen the closed day")
        XCTAssertFalse(app.buttons["interruptTask"].exists)
        capture(app, "closed-day-remains-closed-after-idea-start")
    }

    func testOrdinaryReturnToTodayKeepsOpenTimetableWhileTaskRuns() {
        let app = launch("task")
        let start = app.buttons["startNowItem"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        tapVisible(start, in: app)
        XCTAssertTrue(app.buttons["interruptTask"].waitForExistence(timeout: 5))
        let timetable = app.buttons["openTimetable"]
        tapVisible(timetable, in: app)
        XCTAssertTrue(app.navigationBars["時間割"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == %@", "すべて")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["すべて"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == %@", "今日")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["時間割"].waitForExistence(timeout: 10), "ordinary tab restoration must not pop the timetable")
        capture(app, "ordinary-today-return-keeps-timetable-navigation")
        app.navigationBars["時間割"].buttons.element(boundBy: 0).tap()
        let interrupt = app.buttons["interruptTask"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 10))
        reveal(interrupt, in: app)
        capture(app, "ordinary-today-return-keeps-local-task-work")
    }

}
