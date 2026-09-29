import XCTest

/// The platform's own text fields in the tree (`OPEN_FORM`): the keyboard does not cover the
/// field being edited, Return moves to the next field, and a drag of the text takes the
/// keyboard down with the finger.
final class KeyboardTests: XCTestCase {
    @MainActor
    func testTheKeyboardLeavesTheFieldShowingAndADragTakesItDown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OPEN_FORM"] = "1"
        app.launch()
        let name = app.textFields["Name"]
        let email = app.textFields["Email"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        // The fields are below the screen: the text scrolls them up.
        for _ in 0..<5 where !name.isHittable {
            app.swipeUp()
        }

        name.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertLessThanOrEqual(name.frame.maxY, keyboard.frame.minY)
        name.typeText("Ada")
        // Return with Next: Email takes the keyboard.
        name.typeText("\n")
        sleep(1)
        XCTAssertTrue(email.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
        email.typeText("ada@example.com")
        XCTAssertTrue(
            app.staticTexts["Signing up Ada at ada@example.com"].waitForExistence(timeout: 5)
        )
        XCTAssertLessThanOrEqual(email.frame.maxY, keyboard.frame.minY)

        // The text dragged down past the keyboard takes it away.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)),
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keyboard)
        wait(for: [gone], timeout: 5)
    }
}
