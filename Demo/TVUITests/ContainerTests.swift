import XCTest

/// Tabs and a split on the remote (`TABS_PROBE`, `SPLIT_PROBE`; `ContainerProbe`): the focus
/// goes up to the tab bar and along it, a tab keeps its state, and a split does not hide its
/// sidebar.
final class ContainerTests: XCTestCase {
    @MainActor
    private func launch(_ probe: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[probe] = "1"
        app.launch()
        return app
    }

    @MainActor
    func testATabKeepsItsStateWhileAnotherIsPicked() {
        let app = launch("TABS_PROBE")
        XCTAssertTrue(app.staticTexts["Inbox list"].waitForExistence(timeout: 20))
        sleep(1)
        let remote = XCUIRemote.shared

        // Select opens the detail; Menu goes back to the list, and then to the tab bar.
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))

        // Up to the tab bar, along it to Search, and down into the tab.
        remote.press(.up)
        sleep(1)
        remote.press(.right)
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Inbox detail"].exists)

        // Back along the bar: the inbox is still on its detail.
        remote.press(.left)
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testASplitDoesNotHideItsSidebar() {
        let app = launch("SPLIT_PROBE")
        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Inbox folder"].waitForExistence(timeout: 5))
    }
}
