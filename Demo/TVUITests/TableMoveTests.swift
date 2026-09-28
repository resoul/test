import XCTest

/// Moving rows of an edited table with the remote, on the `MoveProbe` screen
/// (`TV/MoveProbe`): Select on a row's handle lifts the row, down and up move it by one,
/// and Select puts it down; put down, the arrows move the focus again.
final class TableMoveTests: XCTestCase {
    @MainActor
    func testTheRemoteLiftsARowMovesItAndPutsItDown() {
        let app = XCUIApplication()
        app.launchEnvironment["MOVE_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Order: 0 1 2 3 4 5"].waitForExistence(timeout: 20))
        sleep(1)
        let remote = XCUIRemote.shared

        // The focus starts on the first row's handle.
        remote.press(.select)
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        // Aside, the lifted row stays where it is, and keeps the focus.
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Order: 1 2 0 3 4 5"].waitForExistence(timeout: 5))

        // Put down, down moves the focus to the next row's handle; that row goes up.
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        remote.press(.up)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Order: 1 2 3 0 4 5"].waitForExistence(timeout: 5))
    }
}
