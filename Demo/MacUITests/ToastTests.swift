import XCTest

/// Toasts (`TOAST_PROBE`; see `ToastProbe`): the button of the tree, through the app's command,
/// shows a toast with an action over the window; the action is carried out once and takes the
/// toast away; the button that closes it does too.
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
        show.click()
        XCTAssertTrue(app.staticTexts["Message deleted"].waitForExistence(timeout: 10))
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.exists)

        undo.click()
        XCTAssertTrue(app.staticTexts["Undone 1 times"].waitForExistence(timeout: 5))
        let gone = NSPredicate(format: "exists == false")
        wait(
            for: [expectation(for: gone, evaluatedWith: app.staticTexts["Message deleted"])],
            timeout: 5
        )
    }

    @MainActor
    func testAPersistentToastStaysAndItsButtonClosesIt() {
        continueAfterFailure = false
        let app = launch()
        let showLong = app.buttons["Show long toast"]
        XCTAssertTrue(showLong.waitForExistence(timeout: 20))

        showLong.click()
        let toast = app.staticTexts["Could not save"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        sleep(5)
        XCTAssertTrue(toast.exists, "a persistent toast stays")

        app.buttons["Dismiss"].click()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: toast)], timeout: 5)
    }
}
