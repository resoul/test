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

        // Down until it shows: the list scrolls to the node the focus goes to, and the card
        // of the transitions lies between the node before it and it, so it shows once it
        // has the focus — and the focus goes no further, to the inbox under it. A press
        // while the list scrolls may be lost: each waits for the scroll.
        let shown = NSPredicate { _, _ in screen.contains(rename.frame) }
        for _ in 0..<30 where !screen.contains(rename.frame) {
            XCUIRemote.shared.press(.down)
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: shown, object: nil)],
                timeout: 1
            )
        }
        XCTAssertTrue(screen.contains(rename.frame))
        // It shows before the scroll to it ends; Select waits for the end too.
        Thread.sleep(forTimeInterval: 1)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.staticTexts["Augusta Ada King"].waitForExistence(timeout: 5))
        XCTAssertTrue(screen.contains(app.buttons["Rename Ada"].frame))
    }
}
