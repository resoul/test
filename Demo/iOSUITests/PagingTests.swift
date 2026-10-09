import XCTest

/// A list that asks for its next page as the end comes near (`PAGING_PROBE`; see `PagingProbe`).
/// Left alone it loads three pages of 30 rows and stops; swiping makes it ask again, up to the
/// fourth, which is the last.
final class PagingTests: XCTestCase {
    @MainActor
    func testTheListLoadsPagesAsTheEndComesNearAndStopsAtTheLastOne() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PAGING_PROBE"] = "1"
        app.launch()

        // The empty list asks for its first page, and the short list goes on to the limit of three.
        XCTAssertTrue(app.staticTexts["loaded: 90 · idle"].waitForExistence(timeout: 60))
        // Nothing more comes by itself.
        XCTAssertFalse(app.staticTexts["loaded: 120 · end"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["loaded: 90 · idle"].exists)

        // Scrolling to the end of what is loaded makes it ask for the last page.
        for _ in 0..<40 where !app.staticTexts["loaded: 120 · end"].exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["loaded: 120 · end"].waitForExistence(timeout: 20))

        // The end is the end: swiping further asks for nothing.
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(app.staticTexts["loaded: 120 · end"].exists)
    }
}

/// The page footer of a table (`PAGING_PROBE=table`; see `TablePagingProbe`): the second page fails
/// once, the footer says so with a button to try again, and after the third page it says there
/// is no more.
final class TablePageFooterTests: XCTestCase {
    @MainActor
    func testTheFooterShowsTheFailureOfAPageAndTheEnd() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PAGING_PROBE"] = "table"
        app.launch()

        // The first page arrives by itself, the second fails.
        XCTAssertTrue(
            app.staticTexts["rows: 20"].waitForExistence(timeout: 60),
            "texts: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        for _ in 0..<30 where !app.buttons["Retry"].exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["Couldn’t load more"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.staticTexts["rows: 20"].exists, "nothing was added")

        // Trying again loads it, and the list goes on to the last page.
        app.buttons["Retry"].tap()
        // The list may go on to the third page before a query sees the second.
        let grown = NSPredicate(format: "label == 'rows: 40' OR label == 'rows: 60'")
        XCTAssertTrue(app.staticTexts.matching(grown).firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<30 where !app.staticTexts["rows: 60"].exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["rows: 60"].waitForExistence(timeout: 20))
        for _ in 0..<30 where !app.staticTexts["That’s all"].exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["That’s all"].waitForExistence(timeout: 10))
    }
}
