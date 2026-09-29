import XCTest

/// The multi-line editor and the limit of a field (`EDITOR_PROBE`; see `EditorProbe`): typing
/// reaches the model, the editor grows line by line up to four and stops, and a field that takes
/// four characters does not take a fifth.
final class TextEditorTests: XCTestCase {
    @MainActor
    func testTheEditorGrowsWithItsLinesAndStopsAtItsMost() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_PROBE"] = "1"
        app.launch()

        let notes = app.textViews["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Notes: 0 characters"].exists)
        let empty = notes.frame.height

        notes.tap()
        notes.typeText("hello")
        XCTAssertTrue(app.staticTexts["Notes: 5 characters"].waitForExistence(timeout: 5))

        // Three more lines: four in all, the most, higher than the two it began with.
        notes.typeText("\none\ntwo\nthree")
        for _ in 0..<20 where notes.frame.height <= empty {
            usleep(250_000)
        }
        XCTAssertGreaterThan(notes.frame.height, empty)
        let four = notes.frame.height

        // More lines than the most: it does not grow any more.
        notes.typeText("\nfour\nfive\nsix\nseven")
        usleep(1_000_000)
        XCTAssertEqual(notes.frame.height, four, accuracy: 1)
    }

    @MainActor
    func testAFieldWithALimitTakesNoMoreThanItsLimit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_PROBE"] = "1"
        app.launch()

        let code = app.textFields["Code"]
        XCTAssertTrue(code.waitForExistence(timeout: 20))
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.staticTexts["Code: 1234"].waitForExistence(timeout: 5))
        XCTAssertEqual(code.value as? String, "1234")
    }

    @MainActor
    func testAnEditorLowOnThePageIsKeptAboveTheKeyboardAsItGrows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_PROBE"] = "1"
        app.launchEnvironment["EDITOR_LOW"] = "1"
        app.launch()

        let notes = app.textViews["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 20))
        notes.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15))
        let above = { notes.frame.maxY <= keyboard.frame.minY + 1 }
        for _ in 0..<20 where !above() {
            usleep(250_000)
        }
        XCTAssertTrue(above(), "notes \(notes.frame), keyboard \(keyboard.frame)")

        // More lines: the editor is taller, and its end is still above the keyboard.
        let least = notes.frame.height
        notes.typeText("one\ntwo\nthree\nfour\nfive")
        for _ in 0..<20 where !(notes.frame.height > least + 60 && above()) {
            usleep(250_000)
        }
        XCTAssertGreaterThan(notes.frame.height, least + 60)
        XCTAssertTrue(above(), "notes \(notes.frame), keyboard \(keyboard.frame)")
    }
}
