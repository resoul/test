import XCTest

/// The remote on the demo screen: focus moving down goes past the bottom of the screen, the
/// list scrolls to show the focused node, and Select presses it.
final class FocusScrollTests: XCTestCase {
    @MainActor
    func testFocusMovingDownScrollsToTheButtonBelowTheScreen() {
        let app = XCUIApplication()
        app.launch()
        let rename = app.buttons["Rename Ada"]
        XCTAssertTrue(rename.waitForExistence(timeout: 20))
        let screen = app.windows.firstMatch.frame
        // Under all the cards: off the screen to begin with.
        XCTAssertFalse(screen.contains(rename.frame))

        for _ in 0..<12 {
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.staticTexts["Augusta Ada King"].waitForExistence(timeout: 5))
        XCTAssertTrue(screen.contains(app.buttons["Rename Ada"].frame))
    }
}
