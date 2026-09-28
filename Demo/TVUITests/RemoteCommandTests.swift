import XCTest

/// The remote's buttons as commands, on the `CommandProbe` screen (`TV/CommandProbe`): Menu
/// goes back while the screen can and then leaves the app, Play/Pause and select held down
/// reach the screen, and a short select still presses the focused row.
final class RemoteCommandTests: XCTestCase {
    @MainActor
    func testTheRemotesButtonsReachTheScreenAndMenuAtTheTopLeavesTheApp() {
        let app = XCUIApplication()
        app.launchEnvironment["COMMAND_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Back 0 Play 0 Hold 0 Tap 0"].waitForExistence(timeout: 20))
        sleep(1)
        let remote = XCUIRemote.shared

        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Back 0 Play 0 Hold 0 Tap 1"].waitForExistence(timeout: 5))
        remote.press(.select, forDuration: 1.5)
        XCTAssertTrue(app.staticTexts["Back 0 Play 0 Hold 1 Tap 1"].waitForExistence(timeout: 5))
        remote.press(.playPause)
        XCTAssertTrue(app.staticTexts["Back 0 Play 1 Hold 1 Tap 1"].waitForExistence(timeout: 5))
        remote.press(.menu)
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["Back 2 Play 1 Hold 1 Tap 1"].waitForExistence(timeout: 5))

        // Nothing goes back any more: Menu goes on to the system, and the app leaves the screen.
        remote.press(.menu)
        let left = NSPredicate { _, _ in app.state != .runningForeground }
        let leaving = expectation(for: left, evaluatedWith: nil)
        wait(for: [leaving], timeout: 10)
    }
}
