import XCTest

/// The permission layer over the real system (`PERMISSION_LAYER`; see `PermissionLayerProbe`):
/// reading statuses shows no window, a missing usage string is an error and not the end of the app,
/// the system's own window is shown once, and what the person answers is what the screen reads
/// afterwards.
final class PermissionLayerTests: XCTestCase {
    @MainActor
    private func texts(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { $0.contains(": ") }
    }

    /// Taps `button` of the system's window, which must come.
    @MainActor
    private func answer(
        _ button: String,
        in springboard: XCUIApplication,
        _ message: String
    ) {
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "no window for \(message)")
        XCTAssertTrue(alert.buttons[button].exists, "\(message): \(alert.buttons.allElementsBoundByIndex.map { $0.label })")
        alert.buttons[button].tap()
    }

    @MainActor
    func testStatusesShowNoWindowAMissingStringIsAnErrorAndAnAnswerIsWhatIsRead() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PERMISSION_LAYER"] = "1"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Every status is read, and none of it shows a window.
        XCTAssertTrue(app.staticTexts["camera: notDetermined"].waitForExistence(timeout: 60), "\(texts(app))")
        for name in ["microphone", "photos", "photosAddOnly", "notifications", "location"] {
            XCTAssertTrue(app.staticTexts["\(name): notDetermined"].exists, "\(name): \(texts(app))")
        }
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3), "reading a status showed a window")

        // The demo has no string for adding photos: the system is not asked, the app does not end.
        app.buttons["Ask photosAddOnly"].tap()
        XCTAssertTrue(
            app.staticTexts["result: photosAddOnly: error missing NSPhotoLibraryAddUsageDescription"]
                .waitForExistence(timeout: 20),
            "\(texts(app))"
        )
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3), "a window came for a request that was refused")
        XCTAssertEqual(app.state, .runningForeground, "the app ended")

        // Notifications: one window; yes is read afterwards; asking again shows none.
        app.buttons["Ask notifications"].tap()
        answer("Allow", in: springboard, "notifications")
        XCTAssertTrue(app.staticTexts["notifications: granted(full)"].waitForExistence(timeout: 20), "\(texts(app))")
        app.buttons["Ask notifications"].tap()
        XCTAssertTrue(app.staticTexts["result: notifications: granted(full)"].waitForExistence(timeout: 20))
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3), "a second window came")

        // The camera: a no is a status, it stays, and asking again does not ask the system again.
        app.buttons["Ask camera"].tap()
        answer("Don’t Allow", in: springboard, "camera")
        XCTAssertTrue(app.staticTexts["camera: denied"].waitForExistence(timeout: 20), "\(texts(app))")
        app.buttons["Ask camera"].tap()
        XCTAssertTrue(app.staticTexts["result: camera: denied"].waitForExistence(timeout: 20), "\(texts(app))")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3), "a denied kind was asked again")

        // The microphone, the photo library and the location: each answered its own way.
        app.buttons["Ask microphone"].tap()
        answer("Allow", in: springboard, "microphone")
        XCTAssertTrue(app.staticTexts["microphone: granted(full)"].waitForExistence(timeout: 20), "\(texts(app))")

        app.buttons["Ask photos"].tap()
        answer("Allow Full Access", in: springboard, "photos")
        XCTAssertTrue(app.staticTexts["photos: granted(full)"].waitForExistence(timeout: 20), "\(texts(app))")

        app.buttons["Ask location"].tap()
        answer("Allow While Using App", in: springboard, "location")
        XCTAssertTrue(app.staticTexts["location: granted(whenInUse)"].waitForExistence(timeout: 20), "\(texts(app))")
    }
}
