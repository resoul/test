import XCTest

/// A new message shown over the demo's screen (`OPEN_COMPOSE`): Menu on the remote closes it
/// and leaves the screen under it, not the app.
final class PresentationTests: XCTestCase {
    @MainActor
    func testMenuClosesThePresentationAndTheScreenStays() {
        let app = XCUIApplication()
        app.launchEnvironment["OPEN_COMPOSE"] = "1"
        app.launch()
        let heading = app.staticTexts["New Message"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        sleep(1)

        XCUIRemote.shared.press(.menu)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: heading)
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.staticTexts["Ada Lovelace"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testMenuOnAnAlertChoosesCancel() {
        let app = XCUIApplication()
        app.launchEnvironment["OPEN_MESSAGES"] = "0"
        app.launchEnvironment["ASK_DELETE"] = "1"
        app.launch()
        let alert = app.alerts["Delete the message?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        sleep(1)

        XCUIRemote.shared.press(.menu)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: alert)
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.staticTexts["Notes on the Analytical Engine"].exists)
    }
}
