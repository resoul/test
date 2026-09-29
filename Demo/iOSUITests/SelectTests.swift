import XCTest

/// The option menu (`SELECT_PROBE`; see `SelectProbe`): a touch opens the system's menu of the
/// options, choosing one says so and the button shows it.
final class SelectTests: XCTestCase {
    @MainActor
    func testTheMenuOpensAndWhatIsChosenIsShown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SELECT_PROBE"] = "1"
        app.launch()

        let select = app.buttons["Date"]
        XCTAssertTrue(select.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Sorted by Date"].exists)

        select.tap()
        let sender = app.buttons["Sender"]
        XCTAssertTrue(sender.waitForExistence(timeout: 10), "the menu has the options")
        XCTAssertTrue(app.buttons["Subject"].exists)
        sender.tap()

        XCTAssertTrue(app.staticTexts["Sorted by Sender"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["Sender"].waitForExistence(timeout: 5),
            "the button shows the choice"
        )
        XCTAssertFalse(app.buttons["Date"].exists)
    }
}
