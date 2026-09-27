import XCTest

/// The mouse on the demo in a Mac window, with the system's own mouse events: the wheel
/// scrolls the list and turns the pages of the pager, a drag across a message swipes it
/// aside, and a drag of a handle moves a message while the inbox is edited.
final class MouseTests: XCTestCase {
    private var app: XCUIApplication!
    private var window: XCUIElement!

    @MainActor
    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        window = app.windows.firstMatch
        XCTAssertTrue(app.staticTexts["Nodes, text, state and a breakpoint"].waitForExistence(timeout: 20))
    }

    /// The point `x` from the window's left edge, at `y` on the screen.
    @MainActor
    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y - window.frame.minY))
    }

    /// The element whose label holds `text`: a row of the inbox is one element, read as its
    /// sender and subject.
    @MainActor
    private func element(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// Turns the wheel down over the list until `element` shows whole in the window.
    @MainActor
    private func scrollToShow(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let inside = CGRect(
            x: window.frame.minX,
            y: window.frame.minY + 60,
            width: window.frame.width,
            height: window.frame.height - 120
        )
        // The first card's name is in the list, near its top: while it shows, it moves with
        // the list.
        // Over the list, low in the window: the screen's title stands over the top of it.
        let wheel = point(x: window.frame.width / 2, y: window.frame.maxY - 100)
        for _ in 0..<120 {
            if element.exists, inside.contains(element.frame) { return }

            wheel.scroll(byDeltaX: 0, deltaY: -60)
        }
        XCTFail("\(element) does not come into view", file: file, line: line)
    }

    @MainActor
    func testTheWheelScrollsTheListAndADragAcrossMostOfAMessageDeletesIt() {
        launch()
        // The inbox's rows are laid out as they come near the window.
        scrollToShow(app.buttons["Edit"])
        let grace = element("The first actual bug")
        scrollToShow(grace)

        // From near the row's right end, most of its width toward the left: past most of the
        // row, the first of the trailing actions, Delete, is done.
        let start = point(x: window.frame.width - 60, y: grace.frame.midY)
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -window.frame.width * 0.8, dy: 0)))

        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: grace)], timeout: 5)
    }

    @MainActor
    func testADragOfAHandleMovesAMessageWhileTheInboxIsEdited() {
        launch()
        let edit = app.buttons["Edit"]
        scrollToShow(edit)
        edit.click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        let ada = element("Notes on the Analytical Engine")
        let alan = element("On computable numbers")
        let katherine = element("Trajectories for Friendship 7")
        scrollToShow(katherine)
        // A row, from one message to the next.
        let height = element("The first actual bug").frame.midY - ada.frame.midY

        // The handle is at the row's right end, inside the inbox's margin: two and a half
        // rows down, past the middles of the next two.
        let handle = point(x: window.frame.width - 54, y: ada.frame.midY)
        handle.click(forDuration: 0.2, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: height * 2.5)))
        sleep(1)

        XCTAssertGreaterThan(ada.frame.minY, alan.frame.minY, "Ada \(ada.frame), Alan \(alan.frame)")
        XCTAssertLessThan(ada.frame.minY, katherine.frame.minY, "Ada \(ada.frame), Katherine \(katherine.frame)")
        app.buttons["Done"].click()
    }

    @MainActor
    func testTheWheelTurnsThePagesOfThePagerOneAtATime() {
        launch()
        let first = element("Page 1 of 4")
        let second = element("Page 2 of 4")
        let third = element("Page 3 of 4")
        scrollToShow(first)
        // The labels are centered on their pages, and not all as wide.
        let start = first.frame.midX

        // Every page is an element: where they are tells which one shows.
        first.scroll(byDeltaX: -20, deltaY: 0)
        sleep(1)
        if abs(second.frame.midX - start) > 1 {
            // The other way is forward.
            first.scroll(byDeltaX: 20, deltaY: 0)
            sleep(1)
        }
        XCTAssertEqual(second.frame.midX, start, accuracy: 1, "page 2 \(second.frame)")
        XCTAssertGreaterThan(third.frame.midX, start + 100, "page 3 \(third.frame)")
    }
}
