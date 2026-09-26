import XCTest

/// The ten thousand lines as the accessibility of the running demo reports them: the lines
/// laid out are in the list's container, with their frames where they show.
final class ListAccessibilityTests: XCTestCase {
    @MainActor
    func testALineInTheListIsWhereItShows() {
        let app = XCUIApplication()
        app.launch()
        let jump = app.buttons["To line 5000"]
        XCTAssertTrue(jump.waitForExistence(timeout: 20))
        for _ in 0..<12 where !jump.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(jump.isHittable)
        jump.tap()

        let line = app.staticTexts["Line 5000"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let title = app.staticTexts["10,000 lines"]
        XCTAssertTrue(title.exists)
        // Right under the title that sticks to the top of the list, and on the screen.
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(line.frame), "line \(line.frame), screen \(screen)")
        XCTAssertGreaterThanOrEqual(line.frame.minY, title.frame.maxY - 1)
        XCTAssertLessThan(
            line.frame.minY,
            title.frame.maxY + 20,
            "line \(line.frame), title \(title.frame)"
        )
        XCTAssertTrue(line.isHittable)
    }
}
