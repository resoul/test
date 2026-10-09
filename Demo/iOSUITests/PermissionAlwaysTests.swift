import XCTest

/// Location "always" over the real system (`PERMISSION_LAYER`): "when in use" first, and then the
/// system's offer to raise it, which the layer waits out. The text of the offer's buttons is read
/// from the window, because it is the system's and differs between versions.
///
/// The location answer is kept by the system between runs; reset it before this test with
/// `xcrun simctl privacy booted reset location dev.layout.demo`.
final class PermissionAlwaysTests: XCTestCase {
    @MainActor
    private func texts(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { $0.contains(": ") }
    }

    @MainActor
    func testTheOfferToRaiseWhenInUseToAlwaysIsWaitedOutAndItsAnswerIsRead() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PERMISSION_LAYER"] = "1"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        XCTAssertTrue(
            app.staticTexts["locationAlways: notDetermined"].waitForExistence(timeout: 60),
            "\(texts(app))"
        )

        // "When in use" is asked for first, as an app is advised to: the window offers it.
        app.buttons["Ask location"].tap()
        let first = springboard.alerts.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "no first window")
        let firstButtons = first.buttons.allElementsBoundByIndex.map { $0.label }
        let whileUsing = first.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'While Using'")
        ).firstMatch
        XCTAssertTrue(whileUsing.exists, "first window buttons: \(firstButtons)")
        whileUsing.tap()
        XCTAssertTrue(
            app.staticTexts["locationAlways: granted(whenInUse)"].waitForExistence(timeout: 30),
            "after the first window: \(texts(app))"
        )

        // The second request is the offer to raise it. Say what buttons it has.
        app.buttons["Ask locationAlways"].tap()
        let offer = springboard.alerts.firstMatch
        if offer.waitForExistence(timeout: 10) {
            let buttons = offer.buttons.allElementsBoundByIndex.map { $0.label }
            let raise = offer.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Always'")
            ).firstMatch
            XCTAssertTrue(raise.exists, "the offer's buttons: \(buttons)")
            raise.tap()
            XCTAssertTrue(
                app.staticTexts["result: locationAlways: granted(always)"]
                    .waitForExistence(timeout: 30),
                "after the offer: \(texts(app))"
            )
        } else {
            // The system showed no offer: the layer must still come back with the status as it is.
            XCTAssertTrue(
                app.staticTexts["result: locationAlways: granted(whenInUse)"]
                    .waitForExistence(timeout: 30),
                "no offer came and the layer did not answer: \(texts(app))"
            )
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Keeping "when in use" gives the system nothing to report, and asking again shows no window:
    /// the layer must come back each time with the status as it is, and not wait for ever.
    @MainActor
    func testKeepingWhenInUseAndAskingAgainBothComeBackWithWhenInUse() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PERMISSION_LAYER"] = "1"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(
            app.staticTexts["locationAlways: notDetermined"].waitForExistence(timeout: 60),
            "\(texts(app))"
        )

        app.buttons["Ask location"].tap()
        let first = springboard.alerts.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "no first window")
        first.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'While Using'")).firstMatch
            .tap()
        XCTAssertTrue(
            app.staticTexts["locationAlways: granted(whenInUse)"].waitForExistence(timeout: 30),
            "\(texts(app))"
        )

        app.buttons["Ask locationAlways"].tap()
        let offer = springboard.alerts.firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "no offer")
        let buttons = offer.buttons.allElementsBoundByIndex.map { $0.label }
        let keep = offer.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Keep'"))
            .firstMatch
        XCTAssertTrue(keep.exists, "the offer's buttons: \(buttons)")
        keep.tap()
        XCTAssertTrue(
            app.staticTexts["result: locationAlways: granted(whenInUse)"]
                .waitForExistence(timeout: 30),
            "after keeping: \(texts(app))"
        )

        // Asking once more: the system offers no second time; the layer says so after its watch.
        app.buttons["Ask location"].tap()
        XCTAssertFalse(
            springboard.alerts.firstMatch.waitForExistence(timeout: 3),
            "a window came for a kind that was answered"
        )
        app.buttons["Ask locationAlways"].tap()
        XCTAssertFalse(
            springboard.alerts.firstMatch.waitForExistence(timeout: 4),
            "the system offered a second time"
        )
        XCTAssertTrue(
            app.staticTexts["result: locationAlways: granted(whenInUse)"].exists,
            "\(texts(app))"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }
}
