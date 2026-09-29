import XCTest

/// The state of the containers across launches (`TABS_PROBE`; `ContainerProbe`): the tab that
/// was picked, and the path of the stack in another tab, come back after the app is closed and
/// opened again.
final class RestorationTests: XCTestCase {
    @MainActor
    func testThePickedTabAndTheStacksPathComeBackAfterARelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["TABS_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Inbox list"].waitForExistence(timeout: 60))
        app.buttons["Open detail"].tap()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))

        // The system asks the scene for its state when the app goes to the background.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()
        app.launch()

        // Back on the tab that was picked, and the inbox on the screen it was on.
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 60))
        app.tabBars.buttons["Inbox"].tap()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
    }
}
