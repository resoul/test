import XCTest

/// What the system says about permissions (`PERMISSION_PROBE`; see `PermissionProbe`), asked of the
/// real system on the Simulator: the status of each kind on a fresh install, and the system's own
/// window for notifications.
final class PermissionProbeTests: XCTestCase {
    @MainActor
    private func rows(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { $0.contains(": ") }
    }

    @MainActor
    func testStatusesOnAFreshInstallAndTheNotificationsWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PERMISSION_PROBE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["camera: notDetermined"].waitForExistence(timeout: 60), "\(rows(app))")
        // Every status is read without a window.
        print("PERMDIAG fresh:", rows(app))

        // The system's window for notifications.
        app.buttons["Ask notifications"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the notifications window did not appear")
        print("PERMDIAG alert label:", alert.label)
        print("PERMDIAG alert buttons:", alert.buttons.allElementsBoundByIndex.map { $0.label })
        alert.buttons["Allow"].tap()

        app.buttons["Refresh"].tap()
        XCTAssertTrue(app.staticTexts["notifications: authorized"].waitForExistence(timeout: 30), "\(rows(app))")
        print("PERMDIAG after allow:", rows(app))

        // Asking again shows no window: the answer is known.
        app.buttons["Ask notifications"].tap()
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 5), "a second window appeared")
        print("PERMDIAG after second ask:", rows(app))
    }
}
