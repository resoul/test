import XCTest

/// A view of the platform inside the tree (`HOSTED_PROBE`; see `HostedProbe`): a system
/// button that presses, and that goes out of sight with the scroll around it and comes back —
/// moved by buttons of the tree, not the wheel, which XCUITest turns on a Mac by amounts that
/// do not tell how far the page went.
final class HostedViewTests: XCTestCase {
    @MainActor
    func testASystemButtonInTheTreePressesAndScrollsAwayWithItsScroll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSTED_PROBE"] = "1"
        app.launch()

        let button = app.buttons["Hosted button"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Count 0"].exists)
        button.click()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))

        // Scrolled to the end of the page, the button is far above the window: its view keeps its
        // size, the frame is where the scroll has it, and what shows of it is cut to nothing.
        let window = app.windows.firstMatch
        app.buttons["Page end"].click()
        XCTAssertTrue(app.staticTexts["End of page"].waitForExistence(timeout: 5))
        for _ in 0..<20 where button.frame.intersects(window.frame) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(
            button.frame.intersects(window.frame),
            "button \(button.frame), window \(window.frame)"
        )
        XCTAssertTrue(app.staticTexts["End of page"].frame.intersects(window.frame))

        // And back: it is in the window again, and presses.
        app.buttons["Page start"].click()
        for _ in 0..<20 where !button.frame.intersects(window.frame) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(button.frame.intersects(window.frame))
        button.click()
        XCTAssertTrue(app.staticTexts["Count 2"].waitForExistence(timeout: 5))
    }
}
