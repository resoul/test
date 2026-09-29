import XCTest

/// Tabs and a split in a window (`TABS_PROBE`, `SPLIT_PROBE`; `ContainerProbe`): a tab keeps its
/// state while another is picked, and the window's toolbar follows the tab that shows; a
/// split shows the sidebar beside the content.
final class ContainerTests: XCTestCase {
    @MainActor
    private func launch(_ probe: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[probe] = "1"
        app.launch()
        return app
    }

    /// A tab of the tab control on top of the content: a radio button of its group.
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let radio = app.radioButtons[name]
        return radio.exists ? radio : app.buttons[name]
    }

    @MainActor
    func testATabKeepsItsStateWhileAnotherIsPicked() {
        continueAfterFailure = false
        let app = launch("TABS_PROBE")
        XCTAssertTrue(app.staticTexts["Inbox list"].waitForExistence(timeout: 20))
        app.buttons["Open detail"].click()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        // The inbox is a stack: its toolbar has the back button.
        XCTAssertTrue(app.toolbars.buttons["Back"].exists)

        tab("Search", in: app).click()
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Inbox detail"].exists)
        // A screen alone has none: the toolbar is the tab's that shows.
        XCTAssertFalse(app.toolbars.buttons["Back"].exists)

        tab("Settings", in: app).click()
        app.buttons["Count up"].click()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))

        tab("Inbox", in: app).click()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.toolbars.buttons["Back"].exists)
        tab("Settings", in: app).click()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheSplitShowsTheSidebarBesideTheContent() {
        continueAfterFailure = false
        let app = launch("SPLIT_PROBE")
        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Inbox folder"].waitForExistence(timeout: 5))

        app.buttons["Sent"].click()
        XCTAssertTrue(app.staticTexts["Sent folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Folders"].exists)
        app.buttons["Open message"].click()
        XCTAssertTrue(app.staticTexts["A message"].waitForExistence(timeout: 5))
        // The content is a stack: the window's toolbar has its back button.
        XCTAssertTrue(app.toolbars.buttons["Back"].exists)
    }
}
