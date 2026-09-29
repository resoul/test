import XCTest

/// An email field (`FIELDS_PROBE`; see `FieldsProbe`): the address's form is checked when the
/// user leaves the field, the message is there while it is wrong, and goes as soon as it is right.
final class EmailFieldTests: XCTestCase {
    @MainActor
    func testTheFormIsCheckedOnLeavingTheFieldAndTheMessageGoesWhenItIsRight() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FIELDS_PROBE"] = "1"
        app.launch()

        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Email not checked"].exists)

        email.tap()
        email.typeText("ada")
        // Typing does not check yet.
        XCTAssertTrue(app.staticTexts["Email not checked"].exists)
        // Return, with Next, leaves the field: now it is checked.
        email.typeText("\n")
        let message = "Enter an email address such as name@example.com"
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))

        // Back in the field, at its end: made right, the message goes.
        email.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        email.typeText("@example.com")
        XCTAssertTrue(app.staticTexts["Email is fine"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[message].exists)
    }
}
