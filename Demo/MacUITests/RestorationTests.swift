import XCTest

/// The state of the containers across launches (`TABS_PROBE`; `ContainerProbe`): the tab that
/// was picked, and the path of the stack in another tab, come back after the app is quit and
/// opened again.
final class RestorationTests: XCTestCase {
    @MainActor
    func testThePickedTabAndTheStacksPathComeBackAfterARelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TABS_PROBE"] = "1"
        // Windows and their state are kept when the app quits, whatever the system setting.
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Inbox list"].waitForExistence(timeout: 20))
        app.buttons["Open detail"].click()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        let radio = app.radioButtons["Search"]
        (radio.exists ? radio : app.buttons["Search"]).click()
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))
        sleep(2)

        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 20))
        let inbox = app.radioButtons["Inbox"]
        (inbox.exists ? inbox : app.buttons["Inbox"]).click()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
    }
}
