import XCTest

/// An email field (`FIELDS_PROBE`; see `FieldsProbe`): the address's form is checked when the
/// user leaves the field. Digits are typed, which a keyboard layout without Latin letters types
/// too; an address of digits alone is not an address.
final class EmailFieldTests: XCTestCase {
    @MainActor
    func testTheFormIsCheckedOnLeavingTheField() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FIELDS_PROBE"] = "1"
        app.launch()

        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Email not checked"].exists)

        email.click()
        email.typeText("123")
        XCTAssertTrue(app.staticTexts["Email not checked"].exists)
        email.typeText("\n")
        XCTAssertTrue(
            app.staticTexts["Enter an email address such as name@example.com"]
                .waitForExistence(timeout: 5)
        )
    }
}
