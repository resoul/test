import XCTest

/// A view of the platform inside the tree (`HOSTED_PROBE`; see `HostedProbe`): a system
/// button that presses, and that goes out of sight with the scroll around it and comes back.
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

        // Scrolled to the end of the page, the button is cut to nothing: no frame to press.
        let window = app.windows.firstMatch
        for _ in 0..<8 where button.frame.height > 0 {
            window.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertEqual(button.frame.height, 0)

        // And back: it has its size again, and presses.
        for _ in 0..<8 where button.frame.height == 0 {
            window.scroll(byDeltaX: 0, deltaY: 300)
        }
        XCTAssertGreaterThan(button.frame.height, 0)
        button.click()
        XCTAssertTrue(app.staticTexts["Count 2"].waitForExistence(timeout: 5))
    }
}
