import ApplicationServices
import XCTest

/// The demo's lists as the accessibility of the running app on the Mac reports them. XCTest
/// shows where elements are; VoiceOver's own requests — a few rows of a list by index, and
/// the action to bring an element into view — go through the accessibility API, as VoiceOver
/// sends them. That API answers the test runner only once it is allowed to control the
/// computer (System Settings, Privacy & Security, Accessibility); until then those tests
/// are skipped.
final class ListAccessibilityTests: XCTestCase {
    @MainActor
    func testElementsAreWhereTheyShowInTheWindow() {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        let heading = app.staticTexts["Nodes, text, state and a breakpoint"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20))

        // The screen's heading is at the top of the window, under its title bar; mirrored,
        // it would be at the bottom.
        XCTAssertTrue(window.frame.contains(heading.frame), "heading \(heading.frame), window \(window.frame)")
        XCTAssertLessThan(heading.frame.minY, window.frame.minY + 120, "heading \(heading.frame), window \(window.frame)")
    }

    @MainActor
    func testALineFarDownTheListComesIntoViewWhenAsked() throws {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        try XCTSkipUnless(AXIsProcessTrusted(), "The runner may not use the accessibility API")
        let demo = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.layout.demo.mac")
                .first
        )
        let root = AXUIElementCreateApplication(demo.processIdentifier)

        // The list of ten thousand lines: a row for each, the lines not laid out too.
        let list = try XCTUnwrap(
            find(in: root) { element in
                let rows: Int? = value(of: element, "AXRowCount")
                return rows == 10_000
            }
        )
        XCTAssertEqual(value(of: list, "AXRole"), "AXList")
        var count = 0
        XCTAssertEqual(AXUIElementGetAttributeValueCount(list, "AXChildren" as CFString, &count), .success)
        XCTAssertEqual(count, 10_000)
        var some: CFArray?
        XCTAssertEqual(
            AXUIElementCopyAttributeValues(list, "AXChildren" as CFString, 9000, 1, &some),
            .success
        )
        let rows = try XCTUnwrap(some as? [AXUIElement])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(value(of: row, "AXRole"), "AXRow")
        XCTAssertEqual(value(of: row, "AXIndex"), 9000)
        // Not laid out: the row is empty.
        let empty: [AXUIElement]? = value(of: row, "AXChildren")
        XCTAssertEqual(empty?.count ?? 0, 0)

        XCTAssertEqual(AXUIElementPerformAction(row, "AXScrollToVisible" as CFString), .success)

        // Laid out, in the window, under the title sticking to the top of the list. XCTest
        // takes at most a thousand of an element's children, and line 9000 is past them: the
        // line is read through the API too.
        let children: [AXUIElement] = try XCTUnwrap(value(of: row, "AXChildren"))
        XCTAssertEqual(children.count, 1)
        let label: String? = value(of: children[0], "AXDescription")
        XCTAssertEqual(label, "Line 9000")
        let line = try XCTUnwrap(frame(of: children[0]))
        let title = app.staticTexts["10,000 lines"]
        XCTAssertTrue(window.frame.contains(line), "line \(line), window \(window.frame)")
        XCTAssertGreaterThanOrEqual(line.minY, title.frame.maxY - 1)
        XCTAssertLessThan(line.minY, title.frame.maxY + 20, "line \(line), title \(title.frame)")
    }

    @MainActor
    func testAButtonBelowTheWindowComesIntoViewWhenAsked() throws {
        let app = XCUIApplication()
        app.launch()
        let jump = app.buttons["To line 5000"]
        XCTAssertTrue(jump.waitForExistence(timeout: 20))
        XCTAssertFalse(jump.isHittable)
        try XCTSkipUnless(AXIsProcessTrusted(), "The runner may not use the accessibility API")
        let demo = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.layout.demo.mac")
                .first
        )
        let button = try XCTUnwrap(
            find(in: AXUIElementCreateApplication(demo.processIdentifier)) { element in
                let label: String? = value(of: element, "AXDescription")
                return label == "To line 5000"
            }
        )

        XCTAssertEqual(AXUIElementPerformAction(button, "AXScrollToVisible" as CFString), .success)

        XCTAssertTrue(jump.isHittable, "button \(jump.frame)")
    }

    @MainActor
    func testTheRowsOfAListBelowTheWindowAreWhereTheListIs() {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))

        // The grid of squares starts below the window: its rows are below it too, across
        // the window's width, not at the screen's edge.
        let rows = app.tableRows
        XCTAssertGreaterThan(rows.count, 4)
        for index in 0..<4 {
            let row = rows.element(boundBy: index).frame
            XCTAssertGreaterThanOrEqual(row.minX, window.frame.minX, "row \(index) \(row)")
            XCTAssertLessThanOrEqual(row.maxX, window.frame.maxX, "row \(index) \(row)")
            XCTAssertGreaterThanOrEqual(row.minY, window.frame.maxY, "row \(index) \(row)")
        }
    }

    /// The attribute `name` of `element`, if it has one of type `T`.
    private func value<T>(of element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    /// Where `element` is on the screen, from its top left, as XCTest has frames.
    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(of: element, "AXPosition"),
            let size: AXValue = value(of: element, "AXSize")
        else { return nil }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent)
        else { return nil }

        return CGRect(origin: origin, size: extent)
    }

    /// The first element under `root`, breadth first, that `matches`; the rows of lists are
    /// left out: a list may have thousands.
    private func find(in root: AXUIElement, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var pending = [root]
        while !pending.isEmpty {
            let element = pending.removeFirst()
            if matches(element) { return element }
            let role: String? = value(of: element, "AXRole")
            guard role != "AXList", let children: [AXUIElement] = value(of: element, "AXChildren")
            else { continue }

            pending.append(contentsOf: children)
        }
        return nil
    }
}
