import XCTest

/// A new message in a sheet of the window: the toolbar's button and the menu item open it,
/// Escape and Send close it. The item's Command-N is not typed: under a keyboard layout of
/// other letters the test types no N.
final class PresentationTests: XCTestCase {
    @MainActor
    func testANewMessageIsASheetThatEscapeAndSendClose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let compose = app.toolbars.buttons["New Message"]
        XCTAssertTrue(compose.waitForExistence(timeout: 20))
        let heading = app.sheets.staticTexts["New Message"]
        let gone = NSPredicate(format: "exists == false")

        compose.click()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        wait(for: [expectation(for: gone, evaluatedWith: heading)], timeout: 5)

        app.menuBars.menuBarItems["Screen"].click()
        app.menuBars.menuItems["New Message"].click()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        app.sheets.buttons["Send"].click()
        wait(for: [expectation(for: gone, evaluatedWith: heading)], timeout: 5)
    }
}
