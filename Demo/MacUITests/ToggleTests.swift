import XCTest

/// A switch and a check box (`TOGGLE_PROBE`; `ContainerProbe`): a click turns each over, and
/// the accessibility tree has them as check boxes with numbers for values.
final class ToggleTests: XCTestCase {
    @MainActor
    func testAClickTurnsASwitchAndACheckboxOver() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOGGLE_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Notifications off, all mixed"].waitForExistence(timeout: 20))
        let toggle = app.checkBoxes["Notifications"]
        let box = app.checkBoxes["Select all"]
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? Int, 0)
        XCTAssertEqual(box.value as? Int, 2)

        toggle.click()
        XCTAssertTrue(app.staticTexts["Notifications on, all mixed"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 1)
        box.click()
        XCTAssertTrue(app.staticTexts["Notifications on, all on"].waitForExistence(timeout: 5))
        box.click()
        XCTAssertTrue(app.staticTexts["Notifications on, all off"].waitForExistence(timeout: 5))
    }
}
