import XCTest

/// The multi-line editor and the limit of a field (`EDITOR_PROBE`; see `EditorProbe`): typing
/// reaches the model, and a field that takes four characters does not take a fifth. Digits are
/// typed, which a keyboard layout without Latin letters types too.
final class TextEditorTests: XCTestCase {
    @MainActor
    func testTheEditorTakesWhatIsTypedAndAFieldWithALimitTakesNoMore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_PROBE"] = "1"
        app.launch()

        let notes = app.textViews["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 20))
        notes.click()
        notes.typeText("12345")
        XCTAssertTrue(app.staticTexts["Notes: 5 characters"].waitForExistence(timeout: 5))

        let code = app.textFields["Code"]
        code.click()
        code.typeText("123456")
        XCTAssertTrue(app.staticTexts["Code: 1234"].waitForExistence(timeout: 5))
    }
}
