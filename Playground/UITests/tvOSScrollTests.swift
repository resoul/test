import XCTest

final class TVScrollTests: XCTestCase {
    @MainActor
    func testRemoteRevealsAndActivatesOffscreenCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S33_ScrollNodeInteraction", "--r08-test"]
        app.launch()
        let baseline = app.buttons["Baseline card, row 1"]
        XCTAssertTrue(baseline.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.right)
        let focused = NSPredicate(format: "hasFocus == true")
        expectation(for: focused, evaluatedWith: baseline)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.down)
        let target = app.buttons["Target card, row 10"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        expectation(for: focused, evaluatedWith: target)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: target)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.up)
        expectation(for: focused, evaluatedWith: baseline)
        waitForExpectations(timeout: 5)
    }

    /// R12: table rows take remote focus, focus movement reveals rows below the screen, and the
    /// remote's select chooses the focused row.
    @MainActor
    func testRemoteFocusWalksTableRowsAndSelectChoosesTheRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S37_TableNodeInbox"]
        app.launch()
        let first = app.descendants(matching: .any)["message-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        let focused = NSPredicate(format: "hasFocus == true")
        for _ in 0..<3 where !first.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        let target = app.descendants(matching: .any)["message-20"]
        var presses = 0
        while !(target.exists && target.hasFocus), presses < 40 {
            XCUIRemote.shared.press(.down)
            presses += 1
        }
        expectation(for: focused, evaluatedWith: target)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        let status = app.descendants(matching: .any)["r12c-status"]
        expectation(for: NSPredicate(format: "value CONTAINS 'selected 20'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
    }

    /// R13: the remote moves focus across the pager's tabs, select changes the page, and focus
    /// moves down into the selected page's table rows.
    @MainActor
    func testRemoteSelectsPagesThroughTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S38_PagerTabs"]
        app.launch()
        let status = app.descendants(matching: .any)["r13-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let focused = NSPredicate(format: "hasFocus == true")
        let tabFeed = app.descendants(matching: .any)["tab-feed"]
        XCTAssertTrue(tabFeed.waitForExistence(timeout: 10))
        var presses = 0
        while !tabFeed.hasFocus, presses < 8 {
            XCUIRemote.shared.press(presses < 3 ? .up : .right)
            presses += 1
        }
        expectation(for: focused, evaluatedWith: tabFeed)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        expectation(
            for: NSPredicate(format: "value CONTAINS 'selected=feed '"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 5)

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        let tabMail = app.descendants(matching: .any)["tab-mail"]
        expectation(for: focused, evaluatedWith: tabMail)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        expectation(
            for: NSPredicate(format: "value CONTAINS 'selected=mail '"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.down)
        let row = app.descendants(matching: .any)["feed-0"]
        expectation(for: focused, evaluatedWith: row)
        waitForExpectations(timeout: 5)
        print("R13-TV \(status.value as? String ?? "nil")")
    }
}
