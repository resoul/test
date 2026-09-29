import XCTest

/// Styled text (`RICH_PROBE`; see `RichProbe`): the text is one element with its words, and a
/// click on a link opens it.
final class RichTextTests: XCTestCase {
    @MainActor
    func testAClickOnALinkOpensItAndTheStyledTextIsOneElement() {
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

        link.click()
        XCTAssertTrue(
            app.staticTexts["Opened https://example.com/opened"].waitForExistence(timeout: 5)
        )
    }
}
