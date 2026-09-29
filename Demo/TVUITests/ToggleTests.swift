import XCTest

/// A switch and a check box on the remote (`TOGGLE_PROBE`; `ContainerProbe`): Select turns
/// over the one in focus, and the focus goes down from one to the other.
final class ToggleTests: XCTestCase {
    @MainActor
    func testSelectTurnsOverTheFocusedSwitchAndCheckbox() {
        let app = XCUIApplication()
        app.launchEnvironment["TOGGLE_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Notifications off, all mixed"].waitForExistence(timeout: 20))
        sleep(1)
        let remote = XCUIRemote.shared

        // The switch is the first thing to take the focus.
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Notifications on, all mixed"].waitForExistence(timeout: 5))
        // Down to the check box: mixed becomes on.
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Notifications on, all on"].waitForExistence(timeout: 5))
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Notifications on, all off"].waitForExistence(timeout: 5))
    }
}
