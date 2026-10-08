import XCTest

final class TouchScrollTests: XCTestCase {
    @MainActor
    func testTouchScrollThenTapUsesCurrentOffset() {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S33_ScrollNodeInteraction", "--r08-test"]
        app.launch()
        let baseline = app.buttons["Baseline card, row 1"]
        XCTAssertTrue(baseline.waitForExistence(timeout: 15))
        baseline.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: baseline)
        waitForExpectations(timeout: 5)
        let start = baseline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -100))
        start.press(forDuration: 0.1, thenDragTo: end)
        let target = app.buttons["Target card, row 10"]
        for _ in 0..<6 where !target.isHittable {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            let bottom = top.withOffset(CGVector(dx: 0, dy: 270))
            bottom.press(forDuration: 0.1, thenDragTo: top)
        }
        XCTAssertTrue(target.isHittable)
        XCTAssertEqual(target.value as? String, "0")
        target.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: target)
        waitForExpectations(timeout: 5)
    }
    @MainActor
    func testDetachDuringRealDeceleration() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scene", "S33_ScrollNodeInteraction", "--r08-test", "--r08-detach-test",
        ]
        app.launch()
        let baseline = app.buttons["Baseline card, row 1"]
        XCTAssertTrue(baseline.waitForExistence(timeout: 15))
        let start = baseline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.5))
        let end = baseline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["Detached during deceleration"].waitForExistence(timeout: 5))
    }

    /// R12a: posts arrive on top while the finger holds a drag still; the read post must not
    /// move beyond the list's own anchor shifts (`drift`), UIKit must keep those shifts on the
    /// native offset during the drag (`native`), and the next page must arrive near the end.
    @MainActor
    func testListNodeKeepsReadPostWhileDraggingThroughArrivals() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S35_ListNodeFeed", "--r12a-test"]
        app.launch()
        let status = app.descendants(matching: .any)["r12a-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "value CONTAINS 'posts=40'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 5)

        let report = try XCTUnwrap(status.value as? String)
        add(XCTAttachment(string: report))
        print("R12A-REPORT \(report)")
        let fields = Dictionary(
            uniqueKeysWithValues: report.split(separator: " ").compactMap {
                pair -> (String, String)? in
                let parts = pair.split(separator: "=")
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
        )
        let held = try XCTUnwrap(Int(fields["held"] ?? ""), report)
        let drift = try XCTUnwrap(Double(fields["drift"] ?? ""), report)
        let native = try XCTUnwrap(Double(fields["native"] ?? ""), report)
        XCTAssertGreaterThanOrEqual(held, 2, report)
        XCTAssertLessThanOrEqual(drift, 0.5, report)
        XCTAssertLessThanOrEqual(native, 0.5, report)

        for _ in 0..<10 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                )
        }
        // Near the end the next page is requested; the exact count depends on fling distance.
        let pages = expectation(description: "at least one more page after the drag")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let value = status.value as? String ?? ""
            let requests =
                value.split(separator: " ").first { $0.hasPrefix("requests=") }
                .flatMap { Int($0.dropFirst("requests=".count)) } ?? 0
            if requests >= 3 {
                print("R12A-AFTER-SWIPES \(value)")
                pages.fulfill()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        wait(for: [pages], timeout: 1)
    }

    /// R12c: a real horizontal swipe on a table row inside the vertical scroll reveals the
    /// trailing actions; Delete removes only that row; a tap selects; vertical scrolling still
    /// works afterwards.
    @MainActor
    func testTableRowSwipeRevealsActionsAndDeleteRemovesTheRow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S37_TableNodeInbox"]
        app.launch()
        let status = app.descendants(matching: .any)["r12c-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["message-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let header = app.descendants(matching: .any)["section-Today"]
        let first = app.descendants(matching: .any)["message-0"]
        print("R12C-FRAMES header=\(header.frame) first=\(first.frame) row=\(row.frame)")

        row.tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'selected 2'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)

        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        print("R12C-AFTER-SWIPE \(status.value as? String ?? "nil")")
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Archive"].exists)
        delete.tap()
        expectation(
            for: NSPredicate(format: "value CONTAINS 'rows=39 last=deleted 2'"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any)["message-2"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["message-3"].exists)

        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        top.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        )
        XCTAssertTrue(app.descendants(matching: .any)["message-20"].waitForExistence(timeout: 5))
        print("R12C-REPORT \(status.value as? String ?? "nil")")
    }

    /// R13: real touch swipes move pages of the pager, tabs select pages, a row swipe inside the
    /// pager moves the pager instead of opening row actions, a vertical drag scrolls the feed
    /// without changing the page, and the feed rebuilt after eviction is back at its position.
    @MainActor
    func testPagerSwipeTabsAndFeedPositionAfterEviction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scene", "S38_PagerTabs"]
        app.launch()
        let status = app.descendants(matching: .any)["r13-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        func waitStatus(_ text: String, _ file: StaticString = #filePath, line: UInt = #line) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: status)
            waitForExpectations(timeout: 6)
        }
        waitStatus("selected=a ")
        let pageA = app.descendants(matching: .any)["page-a"]
        XCTAssertTrue(pageA.waitForExistence(timeout: 5))

        // Swipe left on page A: the feed page comes in.
        pageA.swipeLeft()
        waitStatus("selected=feed ")
        waitStatus("mounted=a,feed,b ")
        print("R13-AFTER-SWIPE \(status.value as? String ?? "nil")")

        // A mostly vertical drag scrolls the feed and keeps the page.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        middle.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.25))
        )
        XCTAssertTrue(app.descendants(matching: .any)["feed-14"].waitForExistence(timeout: 5))
        waitStatus("selected=feed ")
        sleep(1)
        let positionText = (status.value as? String) ?? ""
        let feed = positionText.components(separatedBy: " ").first { $0.hasPrefix("feed=") } ?? ""
        print("R13-FEED \(feed)")
        XCTAssertNotEqual(feed, "feed=0@0")

        // Tabs: Mail; a horizontal drag on a table row moves the pager, not the row.
        app.descendants(matching: .any)["tab-mail"].tap()
        waitStatus("selected=mail ")
        let row = app.descendants(matching: .any)["feed-3"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        )
        waitStatus("selected=c ")
        waitStatus("action=none")
        XCTAssertFalse(app.buttons["Archive"].exists)

        // Page C mounts only Mail as its neighbour: the feed is evicted. Back to the feed.
        waitStatus("mounted=mail,c ")
        app.descendants(matching: .any)["tab-feed"].tap()
        waitStatus("selected=feed ")
        waitStatus("feed:2")
        waitStatus(feed + " ")
        print("R13-REPORT \(status.value as? String ?? "nil")")
    }
}
