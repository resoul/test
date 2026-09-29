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
        XCTAssertTrue(button.isHittable)
        XCTAssertTrue(app.staticTexts["Count 0"].exists)
        button.tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))

        // Scrolled to the end of the page, the button is far above what shows.
        for _ in 0..<6 where !app.staticTexts["End of page"].isHittable {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["End of page"].isHittable)
        XCTAssertFalse(button.isHittable)

        // And back: it is where the scroll has it, and presses.
        for _ in 0..<6 where !button.isHittable {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.staticTexts["Count 2"].waitForExistence(timeout: 5))
    }
}
