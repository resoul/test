import XCTest

/// A password field (`FIELDS_PROBE`; see `FieldsProbe`): it is a secure text field for the
/// system, and what is typed reaches the model.
final class SecureFieldTests: XCTestCase {
    @MainActor
    func testAPasswordFieldIsSecureAndTakesWhatIsTyped() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FIELDS_PROBE"] = "1"
        app.launch()

        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        XCTAssertTrue(app.textFields["Name"].exists)

        password.click()
        password.typeText("123456")
        XCTAssertTrue(app.staticTexts["Password has 6 characters"].waitForExistence(timeout: 5))
    }
}
