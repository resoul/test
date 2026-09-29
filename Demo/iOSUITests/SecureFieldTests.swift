import XCTest

/// A password field (`FIELDS_PROBE`; see `FieldsProbe`): it is a secure text field for the
/// system, what is typed reaches the model, and Return goes on to the next field.
final class SecureFieldTests: XCTestCase {
    @MainActor
    func testAPasswordFieldIsSecureTakesWhatIsTypedAndReturnGoesToTheNextField() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FIELDS_PROBE"] = "1"
        app.launch()

        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        XCTAssertTrue(app.textFields["Name"].exists)
        XCTAssertFalse(app.textFields["Password"].exists)

        password.tap()
        password.typeText("123456")
        XCTAssertTrue(app.staticTexts["Password has 6 characters"].waitForExistence(timeout: 5))
        // The field's value is dots, not the digits.
        XCTAssertNotEqual(password.value as? String, "123456")

        // Return, with Next on the key, moves the keyboard to the phone field.
        password.typeText("\n")
        let phone = app.textFields["Phone"]
        let focused = { phone.value(forKey: "hasKeyboardFocus") as? Bool ?? false }
        for _ in 0..<20 where !focused() {
            usleep(250_000)
        }
        XCTAssertTrue(focused())
    }
}
