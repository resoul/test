import XCTest

/// The rich text editor (`RICH_EDITOR_PROBE`; see `RichEditorProbe`): what is typed reaches the
/// model, and Return in a quote adds a line and, on an empty last line, leaves the quote.
final class RichEditorTests: XCTestCase {
    /// Gives the editor the keyboard and puts the caret after its one line: a touch to the
    /// right of the words, once the keyboard is up (the first touch after launch may not take).
    @MainActor
    private func putCaretAtTheEnd(of editor: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 where !app.keyboards.firstMatch.exists {
            editor.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the editor has the keyboard")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)).tap()
    }

    @MainActor
    func testWhatIsTypedIsReadBackAsMarkdown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RICH_EDITOR_PROBE"] = "1"
        app.launch()

        let editor = app.textViews["Write here"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["MD:Start"].exists)

        putCaretAtTheEnd(of: editor, in: app)
        editor.typeText(" more")
        XCTAssertTrue(
            app.staticTexts["MD:Start more"].waitForExistence(timeout: 5),
            "texts: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
    }

    @MainActor
    func testReturnInAQuoteAddsALineAndOnAnEmptyLastLineLeavesIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RICH_EDITOR_PROBE"] = "1"
        app.launchEnvironment["RICH_EDITOR_QUOTE"] = "1"
        app.launch()

        let editor = app.textViews["Write here"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["MD:> Quoted"].exists)

        putCaretAtTheEnd(of: editor, in: app)
        editor.typeText("\n")
        XCTAssertTrue(
            app.staticTexts["MD:> Quoted\n>"].waitForExistence(timeout: 5),
            "the first Return adds a line to the quote"
        )
        editor.typeText("\n")
        editor.typeText("x")
        XCTAssertTrue(
            app.staticTexts["MD:> Quoted\n\nx"].waitForExistence(timeout: 5),
            "the second Return leaves the quote for a paragraph"
        )
    }
}
