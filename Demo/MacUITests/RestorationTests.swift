import XCTest

/// The state of the containers across launches (`TABS_PROBE` with `RESTORATION_PROBE`; see
/// `ContainerProbe`): the tab that was picked, and the path of the stack in another tab, come
/// back after the app is quit with Command-Q and opened again. The state is kept between runs
/// of the test, so it starts from whatever the last run left and brings it to a known place
/// first.
final class RestorationTests: XCTestCase {
    @MainActor
    private func click(_ name: String, in app: XCUIApplication) {
        let radio = app.radioButtons[name]
        (radio.exists ? radio : app.buttons[name]).click()
    }

    @MainActor
    func testThePickedTabAndTheStacksPathComeBackAfterARelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TABS_PROBE"] = "1"
        app.launchEnvironment["RESTORATION_PROBE"] = "1"
        // Windows and their state are kept when the app quits, whatever the system setting.
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "YES"]
        app.launch()
        XCTAssertTrue(app.radioButtons["Inbox"].waitForExistence(timeout: 20))

        // The inbox on its detail, whatever the last run left, and then the Search tab.
        click("Inbox", in: app)
        if app.buttons["Open detail"].waitForExistence(timeout: 3) {
            app.buttons["Open detail"].click()
        }
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        click("Search", in: app)
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))

        // Quit as a user does: the app is asked for its state on the way out, which a
        // terminated process is not.
        app.typeKey("q", modifierFlags: .command)
        let gone = NSPredicate { _, _ in app.state == .notRunning }
        wait(for: [expectation(for: gone, evaluatedWith: nil)], timeout: 20)
        app.launch()

        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 20))
        click("Inbox", in: app)
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
    }
}
