import XCTest

/// Tabs and a split (`TABS_PROBE`, `SPLIT_PROBE`; `ContainerProbe`): a tab keeps its state while
/// another is picked, and a split shows the sidebar first where room is short, and both
/// beside each other where there is room.
final class ContainerTests: XCTestCase {
    @MainActor
    private func launch(_ probe: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[probe] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let inBar = app.tabBars.buttons[name]
        return inBar.exists ? inBar : app.buttons[name]
    }

    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Seconds to wait for the first screen after launch: an iPad Simulator under load shows
    /// it much later than an iPhone one (defect 217).
    private let firstShow: TimeInterval = 60

    @MainActor
    func testATabKeepsItsStateWhileAnotherIsPicked() {
        let app = launch("TABS_PROBE")
        XCTAssertTrue(app.staticTexts["Inbox list"].waitForExistence(timeout: firstShow))
        app.buttons["Open detail"].tap()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))

        tab("Search", in: app).tap()
        XCTAssertTrue(app.staticTexts["Search screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Inbox detail"].exists)

        tab("Settings", in: app).tap()
        XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 5))
        app.buttons["Count up"].tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))

        // Back to the inbox: still on the detail it was on. Then the counter: still at one.
        tab("Inbox", in: app).tap()
        XCTAssertTrue(app.staticTexts["Inbox detail"].waitForExistence(timeout: 5))
        tab("Settings", in: app).tap()
        XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWhereRoomIsShortTheSplitShowsTheSidebarFirstAndGoesBackToIt() throws {
        try XCTSkipIf(isPad, "An iPad has room for both columns")
        let app = launch("SPLIT_PROBE")
        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: firstShow))
        XCTAssertFalse(app.staticTexts["Inbox folder"].exists)

        app.buttons["Sent"].tap()
        XCTAssertTrue(app.staticTexts["Sent folder"].waitForExistence(timeout: 5))
        app.buttons["Open message"].tap()
        XCTAssertTrue(app.staticTexts["A message"].waitForExistence(timeout: 5))

        // Back leaves the message, then the folder for the sidebar.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Sent folder"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Sent folder"].exists)
    }

    @MainActor
    func testWithRoomForBothTheSplitShowsTheSidebarBesideTheContent() throws {
        try XCTSkipUnless(isPad, "An iPhone has room for one column")
        let app = launch("SPLIT_PROBE")
        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: firstShow))
        XCTAssertTrue(app.staticTexts["Inbox folder"].waitForExistence(timeout: 5))

        app.buttons["Sent"].tap()
        XCTAssertTrue(app.staticTexts["Sent folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Folders"].exists)
    }
}
