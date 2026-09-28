import XCTest

/// The window's toolbar: the stack's back button, and the buttons of the commands of the
/// screen that shows, which work as their menu items do.
final class ToolbarTests: XCTestCase {
    @MainActor
    func testTheToolbarCarriesOutTheScreensCommandsAndGoesBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OPEN_MESSAGES"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Not flagged"].waitForExistence(timeout: 20))

        let flag = app.toolbars.buttons["Flag Message"]
        XCTAssertTrue(flag.waitForExistence(timeout: 5))
        XCTAssertTrue(flag.isEnabled)
        flag.click()
        XCTAssertTrue(app.staticTexts["Flagged"].waitForExistence(timeout: 5))

        // The same command in the menu, with its checkmark.
        app.menuBars.menuBarItems["Screen"].click()
        let item = app.menuBars.menuItems["Flag Message"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(app.staticTexts["Not flagged"].waitForExistence(timeout: 5))

        app.toolbars.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Nodes, text, state and a breakpoint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.toolbars.buttons["Flag Message"].exists)
        XCTAssertTrue(app.toolbars.buttons["Edit Inbox"].exists)
    }
}
