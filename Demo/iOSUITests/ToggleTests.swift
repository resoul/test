import XCTest

/// A switch and a check box (`TOGGLE_PROBE`; `ContainerProbe`): a tap turns each over, and
/// assistive tools see them as toggles with their values.
final class ToggleTests: XCTestCase {
    @MainActor
    func testATapTurnsASwitchAndACheckboxOver() {
        let app = XCUIApplication()
        app.launchEnvironment["TOGGLE_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Notifications off, all mixed"].waitForExistence(timeout: 60)
        )
        let toggle = app.descendants(matching: .any).matching(identifier: "Notifications")
            .firstMatch
        let box = app.descendants(matching: .any).matching(identifier: "Select all").firstMatch
        XCTAssertTrue(toggle.exists)
        // Assistive tools: a switch and a check box, with the values they show.
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(box.value as? String, "2")

        toggle.tap()
        XCTAssertTrue(app.staticTexts["Notifications on, all mixed"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")

        // Mixed becomes on, on becomes off.
        box.tap()
        XCTAssertTrue(app.staticTexts["Notifications on, all on"].waitForExistence(timeout: 5))
        box.tap()
        XCTAssertTrue(app.staticTexts["Notifications on, all off"].waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Notifications off, all off"].waitForExistence(timeout: 5))
    }
}
