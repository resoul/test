import XCTest

/// The option menu (`SELECT_PROBE`; see `SelectProbe`): a click opens the pop-up button's menu of
/// the options, choosing one says so.
final class SelectTests: XCTestCase {
    @MainActor
    func testThePopUpOpensAndWhatIsChosenIsShown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SELECT_PROBE"] = "1"
        app.launch()

        let popUp = app.popUpButtons.firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 20))
        XCTAssertEqual(popUp.value as? String, "Date")
        XCTAssertTrue(app.staticTexts["Sorted by Date"].exists)

        popUp.click()
        let sender = app.menuItems["Sender"]
        XCTAssertTrue(sender.waitForExistence(timeout: 10), "the menu has the options")
        sender.click()

        XCTAssertTrue(app.staticTexts["Sorted by Sender"].waitForExistence(timeout: 5))
        XCTAssertEqual(popUp.value as? String, "Sender")
    }
}
