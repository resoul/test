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
