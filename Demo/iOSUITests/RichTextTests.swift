import XCTest

/// Styled text (`RICH_PROBE`; see `RichProbe`): the text is read as its words, and a touch on a
/// link opens it while a touch elsewhere in the text does nothing.
final class RichTextTests: XCTestCase {
    @MainActor
    func testATouchOnALinkOpensItAndTheStyledTextIsOneElement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RICH_PROBE"] = "1"
        app.launch()

        let link = app.staticTexts["Open the page"]
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Opened nothing"].exists)
        let styled = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Plain, bold, italic'")
        )
        XCTAssertEqual(styled.count, 1, "the styled text is read once, as one element")
        XCTAssertTrue(styled.firstMatch.label.contains("A quotation"))
        XCTAssertTrue(styled.firstMatch.label.contains("let answer = 6 * 7"))

        // A touch on the styled text — no link in it — opens nothing.
        styled.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
        XCTAssertTrue(app.staticTexts["Opened nothing"].exists)

        link.tap()
        XCTAssertTrue(
            app.staticTexts["Opened https://example.com/opened"].waitForExistence(timeout: 5)
        )
    }
}
