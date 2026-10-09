import XCTest

/// The screens around the camera permission (`PERMISSION_FLOW`; see `PermissionFlowProbe`): the
/// explanation comes before the system's window, a refusal leaves a screen that offers Settings and
/// does not ask again, and the status is read again when the app comes back to the front.
final class PermissionFlowTests: XCTestCase {
    @MainActor
    func testTheExplanationComesFirstARefusalOffersSettingsAndNothingAsksAgain() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PERMISSION_FLOW"] = "1"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Before the person has read anything, no window.
        XCTAssertTrue(app.staticTexts["Scan with the camera"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Continue"].exists)
        XCTAssertFalse(app.buttons["Open Settings"].exists)
        XCTAssertFalse(
            springboard.alerts.firstMatch.waitForExistence(timeout: 3),
            "a window came before the explanation"
        )

        // Continue asks, and a no leaves the refusal screen.
        app.buttons["Continue"].tap()
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "no window for the camera")
        alert.buttons["Don’t Allow"].tap()
        XCTAssertTrue(
            app.staticTexts["The camera is off for this app"].waitForExistence(timeout: 20)
        )
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["Continue"].exists, "a refused kind offered to ask again")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
