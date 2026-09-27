import XCTest

/// The ten thousand lines as the accessibility of the running demo reports them: the lines
/// laid out are in the list's container, with their frames where they show.
final class ListAccessibilityTests: XCTestCase {
    /// Scrolls the list until `element` rests whole in the lower half of the window, and
    /// waits for it to come to rest: a tap on content still gliding only stops it. Titles
    /// stick to the top of the list and take the touches there, and `isHittable` does not
    /// tell an element under them from one in the open: the lower half has none.
    @MainActor
    private func bringWithinReach(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<20 {
            var last = element.frame
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = element.frame
                if now == last { break }
                last = now
            }
            let frame = element.frame
            if frame.minY >= window.midY, frame.maxY <= window.maxY { return }

            if frame.minY < window.midY {
                let middle = app.windows.firstMatch.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                )
                middle.press(
                    forDuration: 0.1,
                    thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 200))
                )
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
    }

    @MainActor
    func testALineInTheListIsWhereItShows() {
        let app = XCUIApplication()
        app.launch()
        let jump = app.buttons["To line 5000"]
        XCTAssertTrue(jump.waitForExistence(timeout: 20))
        bringWithinReach(jump, in: app)
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

    @MainActor
    func testATransitionTakesTheCardOutAndBringsItBack() {
        let app = XCUIApplication()
        app.launch()
        let flip = app.buttons["Flip"]
        XCTAssertTrue(flip.waitForExistence(timeout: 20))
        bringWithinReach(flip, in: app)
        let card = app.staticTexts["Tap a transition"]
        XCTAssertTrue(card.exists)
        let place = card.frame

        flip.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))

        // Back where it was: the flip turns the layer, not the node's frame.
        flip.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame, place)
    }
}
