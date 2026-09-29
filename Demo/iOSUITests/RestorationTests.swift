import XCTest

/// The state of the containers across launches (`TABS_PROBE` with `RESTORATION_PROBE`; see
/// `ContainerProbe`): the tab that was picked, and the path of the stack in another tab, come
/// back after the app is closed and opened again. The state is kept between runs of the test,
/// so it starts from whatever the last run left and brings it to a known place first.
final class RestorationTests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABS_PROBE"] = "1"
        app.launchEnvironment["RESTORATION_PROBE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    func testThePickedTabAndTheStacksPathComeBackAfterARelaunch() {
        var app = launch()
        XCTAssertTrue(app.tabBars.buttons["Inbox"].waitForExistence(timeout: 60))

        // The inbox on its detail, whatever the last run left, and then the Search tab.
        app.tabBars.buttons["Inbox"].tap()
        if app.buttons["Open detail"].waitForExistence(timeout: 5) {
            app.buttons["Open detail"].tap()
        }
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))

        // The system asks the scene for its state when the app goes to the background.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()
        app = launch()

        // Back on the tab that was picked, and the inbox on the screen it was on.
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 60))
        app.tabBars.buttons["Inbox"].tap()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
    }
}
