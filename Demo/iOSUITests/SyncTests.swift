import XCTest

/// The sync demo (`SYNC_PROBE`; see `SyncProbe`): a list in a database, fetched and followed live
/// from a server in memory. The status line says what the screen knows, and the rows are the
/// database's.
final class SyncTests: XCTestCase {
    @MainActor
    func testTheListIsFetchedFollowedLiveOrderedAndSurvivesTheNetworkGoingAway() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SYNC_PROBE"] = "1"
        app.launch()

        func status(_ text: String, timeout: TimeInterval = 20) -> Bool {
            app.staticTexts[text].waitForExistence(timeout: timeout)
        }
        func row(_ text: String, timeout: TimeInterval = 10) -> Bool {
            app.staticTexts[text].waitForExistence(timeout: timeout)
        }
        let all = { app.staticTexts.allElementsBoundByIndex.map(\.label) }
        // Fetched over HTTP into the database, shown from there, with the live channel up.
        XCTAssertTrue(
            status("Connection: live · Refresh: loaded · 3 items · Sort: title"),
            "texts: \(all())"
        )
        XCTAssertTrue(row("apple (rev 2)"), "the rows are ordered by title; texts: \(all())")

        // Another user changes the list on the server; it arrives over the socket.
        app.buttons["Another user adds"].tap()
        XCTAssertTrue(status("Connection: live · Refresh: loaded · 4 items · Sort: title"))
        XCTAssertTrue(row("From another user (rev 4)"))

        // The sort is a setting: the newest first.
        app.buttons["Sort: newest"].tap()
        XCTAssertTrue(status("Connection: live · Refresh: loaded · 4 items · Sort: newest"))

        // A file kept with the first item, on this device.
        app.buttons["Attach to first"].tap()
        XCTAssertTrue(
            row("From another user (rev 4) · note.txt 26 bytes"),
            "texts: \(all())"
        )

        // The network goes away: the screen says so, and what it showed stays.
        app.buttons["Go offline"].tap()
        XCTAssertTrue(status("Connection: reconnecting · Refresh: loaded · 4 items · Sort: newest"))
        app.buttons["Refresh"].tap()
        XCTAssertTrue(
            status(
                "Connection: reconnecting · Refresh: failed — There is no network connection. "
                    + "· 4 items · Sort: newest"
            ),
            "texts: \(all())"
        )

        // It comes back; the channel is remade and a refresh recovers.
        app.buttons["Go online"].tap()
        XCTAssertTrue(
            status("Connection: live · Refresh: failed — There is no network connection. · 4 items · Sort: newest"),
            "texts: \(all())"
        )
        app.buttons["Refresh"].tap()
        XCTAssertTrue(status("Connection: live · Refresh: loaded · 4 items · Sort: newest"))

        // Signing out leaves nothing.
        app.buttons["Sign out"].tap()
        XCTAssertTrue(status("Connection: offline · Refresh: loaded · 0 items · Sort: newest"), "texts: \(all())")
    }
}
