import XCTest

/// A stack of screens on the remote, on the `StackProbe` screen (`TV/StackProbe`): Select
/// opens a message, Menu goes back one screen a press and to the button that opened it, and
/// at the root leaves the app.
final class StackTests: XCTestCase {
    @MainActor
    private func launch(opening messages: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["STACK_PROBE"] = "1"
        if let messages {
            app.launchEnvironment["OPEN_MESSAGES"] = messages
        }
        app.launch()
        return app
    }

    @MainActor
    func testMenuGoesBackToTheButtonThatOpenedTheMessageAndThenLeaves() {
        let app = launch()
        XCTAssertTrue(app.buttons["Open 1"].waitForExistence(timeout: 20))
        sleep(1)
        let remote = XCUIRemote.shared

        remote.press(.down)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Subject 1"].waitForExistence(timeout: 5))

        remote.press(.menu)
        XCTAssertTrue(app.buttons["Open 1"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.staticTexts["Subject 1"].exists)
        // The focus came back to the button that opened it.
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Subject 1"].waitForExistence(timeout: 5))

        remote.press(.menu)
        XCTAssertTrue(app.buttons["Open 1"].waitForExistence(timeout: 5))
        sleep(1)
        remote.press(.menu)
        let left = NSPredicate { _, _ in app.state != .runningForeground }
        wait(for: [expectation(for: left, evaluatedWith: nil)], timeout: 10)
    }

    @MainActor
    func testMenuGoesBackOneScreenAPress() {
        let app = launch(opening: "0,1")
        XCTAssertTrue(app.staticTexts["Subject 1"].waitForExistence(timeout: 20))
        sleep(1)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Subject 0"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.staticTexts["Subject 1"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
