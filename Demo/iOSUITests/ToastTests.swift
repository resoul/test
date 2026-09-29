import XCTest

/// Toasts (`TOAST_PROBE`; see `ToastProbe`): the button of the tree, through the app's command,
/// shows a toast with an action over the window; the action is carried out once and takes the
/// toast away; without a touch it goes by itself; one marked persistent stays.
final class ToastTests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOAST_PROBE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    func testTheActionOfAToastIsTakenOnceAndTakesTheToastAway() {
        continueAfterFailure = false
        let app = launch()

        let show = app.buttons["Show toast"]
        XCTAssertTrue(show.waitForExistence(timeout: 20))
        show.tap()
        XCTAssertTrue(app.staticTexts["Message deleted"].waitForExistence(timeout: 10))
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.exists)
        // The screen under it is still there, and takes touches around the toast.
        XCTAssertTrue(app.staticTexts["Undone 0 times"].exists)

        undo.tap()
        XCTAssertTrue(app.staticTexts["Undone 1 times"].waitForExistence(timeout: 5))
        let gone = NSPredicate(format: "exists == false")
        wait(
            for: [expectation(for: gone, evaluatedWith: app.staticTexts["Message deleted"])],
            timeout: 5
        )
    }

    @MainActor
    func testAToastGoesByItselfAndAPersistentOneStays() {
        continueAfterFailure = false
        let app = launch()
        let show = app.buttons["Show toast"]
        XCTAssertTrue(show.waitForExistence(timeout: 20))

        // Three seconds, as the probe says: it is there, and then it is not.
        show.tap()
        let toast = app.staticTexts["Message deleted"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: toast)], timeout: 12)

        // A persistent one is still there when that time is long past.
        app.buttons["Show long toast"].tap()
        let stays = app.staticTexts["Could not save"]
        XCTAssertTrue(stays.waitForExistence(timeout: 10))
        sleep(5)
        XCTAssertTrue(stays.exists)
    }
}
