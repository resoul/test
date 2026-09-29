import XCTest

/// The demo's stack of screens: a message opened from the inbox slides in over the screen,
/// and the back button, a swipe from the edge, or a swipe let go early behave as in any app.
/// `OPEN_MESSAGES` opens messages at launch.
final class StackTests: XCTestCase {
    @MainActor
    private func launch(opening messages: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let messages {
            app.launchEnvironment["OPEN_MESSAGES"] = messages
        }
        app.launch()
        return app
    }

    @MainActor
    private func swipeFromTheEdge(of app: XCUIApplication, to x: Double, holding: Bool) {
        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5))
        // Let go at once, the swipe throws the screen away; held still at the end, it only
        // goes as far as the finger.
        edge.press(
            forDuration: 0.1,
            thenDragTo: end,
            withVelocity: holding ? .slow : .fast,
            thenHoldForDuration: holding ? 0.5 : 0
        )
    }

    @MainActor
    func testTheBackButtonAndASwipeFromTheEdgeGoBack() {
        let app = launch(opening: "0,1")
        let second = app.staticTexts["The first actual bug, taped in"]
        let first = app.staticTexts["Notes on the Analytical Engine"]
        XCTAssertTrue(second.waitForExistence(timeout: 20))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(second.exists)

        swipeFromTheEdge(of: app, to: 0.9, holding: false)
        XCTAssertTrue(app.navigationBars["Layout demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
    }

    @MainActor
    func testASwipeLetGoEarlyLeavesTheMessageAsItWas() {
        let app = launch(opening: "0")
        let subject = app.staticTexts["Notes on the Analytical Engine"]
        XCTAssertTrue(subject.waitForExistence(timeout: 20))
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.buttons["Replied"].waitForExistence(timeout: 5))

        let began = Date()
        swipeFromTheEdge(of: app, to: 0.2, holding: true)
        // How long the gesture took: on an idle machine it is a fixed few seconds, and a
        // machine that is slow shows here.
        let note = XCTAttachment(
            string: String(format: "the swipe took %.2f s", Date().timeIntervalSince(began))
        )
        note.name = "the swipe - time"
        note.lifetime = .keepAlways
        add(note)
        sleep(1)
        // What the system did with the swipe: it finished the move (the inbox shows), or gave
        // it up and the message stayed, or the message is gone with the inbox not there.
        let outcome: String
        if app.navigationBars["Layout demo"].exists {
            outcome = "the system completed the move back"
        } else if subject.exists {
            outcome = "the system cancelled the move, the message stayed"
        } else {
            outcome = "neither the inbox nor the message shows"
        }
        attachEvidence("after the swipe: \(outcome)", of: app)
        XCTAssertTrue(subject.exists, outcome)
        XCTAssertTrue(app.buttons["Replied"].exists)
        XCTAssertTrue(app.navigationBars["Ada Lovelace"].exists)
    }

    @MainActor
    func testAMessageOpensFromTheInbox() {
        let app = launch()
        // A row of the table is one element, whose label holds its texts.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "On computable numbers"))
            .firstMatch
        XCTAssertTrue(app.navigationBars["Layout demo"].waitForExistence(timeout: 20))
        for _ in 0..<30 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        // Come to rest before the tap: a tap on content still gliding only stops it.
        sleep(1)
        let window = app.windows.firstMatch.frame
        if row.frame.minY < window.midY {
            let middle = app.windows.firstMatch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 200)))
            sleep(1)
        }
        row.tap()

        XCTAssertTrue(app.navigationBars["Alan Turing"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Layout demo"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAToolbarCommandIsAButtonOfTheNavigationBar() {
        let app = launch(opening: "0")
        XCTAssertTrue(app.staticTexts["Not flagged"].waitForExistence(timeout: 20))

        app.navigationBars.buttons["Flag Message"].tap()
        XCTAssertTrue(app.staticTexts["Flagged"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Flag Message"].tap()
        XCTAssertTrue(app.staticTexts["Not flagged"].waitForExistence(timeout: 5))

        // The inbox's command is enabled only from inside the inbox: nothing there is
        // pressed yet.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let edit = app.navigationBars["Layout demo"].buttons["Edit Inbox"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(edit.isEnabled)
    }

    @MainActor
    func testANewMessageIsASheetThatCancelAndASwipeDownClose() {
        let app = launch()
        let compose = app.navigationBars["Layout demo"].buttons["New Message"]
        XCTAssertTrue(compose.waitForExistence(timeout: 20))
        let heading = app.staticTexts["New Message"]
        let gone = NSPredicate(format: "exists == false")

        compose.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        wait(for: [expectation(for: gone, evaluatedWith: heading)], timeout: 5)

        compose.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(
                forDuration: 0.1,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            )
        wait(for: [expectation(for: gone, evaluatedWith: heading)], timeout: 5)
        // The stack under it stayed where it was.
        XCTAssertTrue(app.navigationBars["Layout demo"].exists)
    }

    @MainActor
    func testASheetOpensHalfwayAndIsDrawnUpToFull() {
        let app = launch(opening: "0")
        let info = app.navigationBars.buttons["Message Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 20))
        info.tap()
        let heading = app.staticTexts["Message Info"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        sleep(1)
        // Halfway: the sheet's top is in the lower half of the screen, and the message
        // under it is usable.
        XCTAssertGreaterThan(heading.frame.minY, window.height * 0.4)
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.buttons["Replied"].waitForExistence(timeout: 5))
        XCTAssertTrue(heading.exists)

        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: top)
        sleep(1)
        XCTAssertLessThan(heading.frame.minY, window.height * 0.3)
    }

    @MainActor
    func testAnAlertAsksBeforeTheMessageIsDeleted() {
        let app = launch(opening: "0")
        let subject = app.staticTexts["Notes on the Analytical Engine"]
        XCTAssertTrue(subject.waitForExistence(timeout: 20))
        let alert = app.alerts["Delete the message?"]
        let gone = NSPredicate(format: "exists == false")

        app.buttons["Delete"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        wait(for: [expectation(for: gone, evaluatedWith: alert)], timeout: 5)
        XCTAssertTrue(subject.exists)

        app.buttons["Delete"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(app.navigationBars["Layout demo"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Notes on the Analytical Engine"))
        XCTAssertEqual(row.count, 0)
    }
}
