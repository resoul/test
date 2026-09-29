import XCTest

/// The bar above the keyboard (`FIELDS_PROBE` with `KEYBOARD_BAR`; see `FieldsProbe`): Previous
/// and Next move the keyboard between the fields in the order they are read, the ones that lead
/// nowhere are off, and Done takes the keyboard away.
final class KeyboardBarTests: XCTestCase {
    @MainActor
    private func focused(_ element: XCUIElement) -> Bool {
        element.value(forKey: "hasKeyboardFocus") as? Bool ?? false
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        for _ in 0..<40 where !condition() {
            usleep(250_000)
        }
        return condition()
    }

    @MainActor
    func testTheBarMovesTheKeyboardBetweenFieldsAndDoneTakesItAway() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FIELDS_PROBE"] = "1"
        app.launchEnvironment["KEYBOARD_BAR"] = "1"
        app.launch()

        let name = app.textFields["Name"]
        let email = app.textFields["Email"]
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.tap()
        XCTAssertTrue(wait { self.focused(name) })

        let next = app.buttons["Next field"]
        let previous = app.buttons["Previous field"]
        let done = app.buttons["Done"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(previous.exists)
        XCTAssertTrue(done.exists)
        // The first of the fields has none before it.
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)

        next.tap()
        XCTAssertTrue(wait { self.focused(email) }, "Next goes to Email")
        next.tap()
        XCTAssertTrue(wait { self.focused(password) }, "and on to Password")
        previous.tap()
        XCTAssertTrue(wait { self.focused(email) }, "Previous goes back to Email")

        done.tap()
        XCTAssertTrue(wait { !self.app(app, hasKeyboard: true) }, "Done takes the keyboard away")
    }

    @MainActor
    private func app(_ app: XCUIApplication, hasKeyboard: Bool) -> Bool {
        app.keyboards.firstMatch.exists == hasKeyboard
    }
}
