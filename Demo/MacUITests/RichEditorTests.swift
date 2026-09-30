import XCTest

/// The rich text editor (`RICH_EDITOR_PROBE`; see `RichEditorProbe`): what is typed reaches the
/// model, Return in a quote adds a line and leaves it on an empty last line, and the quote
/// shortcut works on the selection and Undo takes it back. Digits are typed, and the
/// shortcut has a digit: under a keyboard layout without Latin letters XCTest types letters with
/// Command held, so letter shortcuts cannot be tested here; the caret moves and selects with
/// arrows.
final class RichEditorTests: XCTestCase {
    /// The editor with the caret after its one line: a click in the field's empty part puts it
    /// at the end of the text.
    @MainActor
    private func launch(quote: Bool = false) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["RICH_EDITOR_PROBE"] = "1"
        if quote { app.launchEnvironment["RICH_EDITOR_QUOTE"] = "1" }
        app.launch()
        let editor = app.textViews["Write here"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.click()
        return (app, editor)
    }

    @MainActor
    private func texts(_ app: XCUIApplication) -> String {
        "texts: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
    }

    @MainActor
    func testWhatIsTypedIsReadBackAsMarkdown() {
        continueAfterFailure = false
        let (app, editor) = launch()
        XCTAssertTrue(app.staticTexts["MD:Start"].exists)

        editor.typeText("123")
        XCTAssertTrue(app.staticTexts["MD:Start123"].waitForExistence(timeout: 5), texts(app))
    }

    @MainActor
    func testReturnInAQuoteAddsALineAndOnAnEmptyLastLineLeavesIt() {
        continueAfterFailure = false
        let (app, editor) = launch(quote: true)
        XCTAssertTrue(app.staticTexts["MD:> Quoted"].exists)

        editor.typeText("\n")
        XCTAssertTrue(
            app.staticTexts["MD:> Quoted\n>"].waitForExistence(timeout: 5),
            "the first Return adds a line to the quote; \(texts(app))"
        )
        editor.typeText("\n")
        editor.typeText("1")
        XCTAssertTrue(
            app.staticTexts["MD:> Quoted\n\n1"].waitForExistence(timeout: 5),
            "the second Return leaves the quote for a paragraph; \(texts(app))"
        )
    }

    @MainActor
    func testTheQuoteShortcutFormatsTheSelectionAndUndoTakesItBack() {
        continueAfterFailure = false
        let (app, editor) = launch()

        editor.typeKey(.leftArrow, modifierFlags: [.shift, .option])
        editor.typeKey("9", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            app.staticTexts["MD:> Start"].waitForExistence(timeout: 5),
            "Command-Shift-9 makes the block a quote; \(texts(app))"
        )

        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo'"))
            .firstMatch
        XCTAssertTrue(undo.exists, "the Edit menu has Undo; \(texts(app))")
        XCTAssertTrue(undo.isEnabled, "Undo is enabled after the format: \(undo.title)")
        undo.click()
        XCTAssertTrue(
            app.staticTexts["MD:Start"].waitForExistence(timeout: 5),
            "Undo takes the quote back; \(texts(app))"
        )
    }

    @MainActor
    func testTheFormatMenuMakesTheSelectionBold() {
        continueAfterFailure = false
        let (app, editor) = launch()

        editor.typeKey(.leftArrow, modifierFlags: [.shift, .option])
        app.menuBars.menuBarItems["Text Format"].click()
        let bold = app.menuBars.menuItems["Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5), "the Text Format menu has Bold")
        XCTAssertTrue(bold.isEnabled, "Bold applies to the selection in the editor")
        bold.click()
        XCTAssertTrue(
            app.staticTexts["MD:**Start**"].waitForExistence(timeout: 5),
            "the menu item makes the selection bold; \(texts(app))"
        )

        // Italic still applies to the bold selection; the menu is reached again to close it.
        app.menuBars.menuBarItems["Text Format"].click()
        XCTAssertTrue(app.menuBars.menuItems["Italic"].isEnabled, "Italic applies as well")
        app.typeKey(.escape, modifierFlags: [])
    }
}
