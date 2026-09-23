import Testing

@testable import TrellisCore

// R12c (`implementation-plan-6.md`, P6.6, ADR 0034): pure table contracts — rows with section
// context and selection, swipe policies, the one-open-row controller and the horizontal
// recognizer. Rendering and pointer routing are covered by `TableNodeHostTests`.

private struct Line: Sendable, Equatable {
    var text: String
}

@MainActor
private struct LineProvider: ItemProvider {
    func makeNode(for item: Line, id: Int) -> Node { Node() }
    func update(_ node: Node, with item: Line, id: Int) {}
}

@MainActor
@Test
func test_tableRows_carrySectionContextAndSelection() {
    let snapshot = CollectionSnapshot<Int, Line>(
        dataKey: "mail",
        revision: 3,
        sections: [
            CollectionSection(
                id: "today",
                items: [
                    CollectionItem(id: 1, value: Line(text: "a")),
                    CollectionItem(id: 2, value: Line(text: "b")),
                ]
            ),
            CollectionSection(id: "older", items: [CollectionItem(id: 3, value: Line(text: "c"))]),
        ]
    )

    let rows = TableNode<LineProvider>.rows(of: snapshot, selection: [2])

    #expect(rows.revision == 3)
    #expect(rows.items.map(\.value.sectionID) == ["today", "today", "older"])
    #expect(rows.items.map(\.value.isFirstInSection) == [true, false, true])
    #expect(rows.items.map(\.value.isLastInSection) == [false, true, true])
    #expect(rows.items.map(\.value.isSelected) == [false, true, false])
}

@Test
func test_swipePolicy_automaticFollowsContextExplicitOverrides() {
    #expect(SwipeActionsPolicy.automatic.allowsSwipe(hasActions: true, contextAllows: true))
    #expect(!SwipeActionsPolicy.automatic.allowsSwipe(hasActions: true, contextAllows: false))
    #expect(SwipeActionsPolicy.enabled.allowsSwipe(hasActions: true, contextAllows: false))
    #expect(!SwipeActionsPolicy.disabled.allowsSwipe(hasActions: true, contextAllows: true))
    #expect(!SwipeActionsPolicy.enabled.allowsSwipe(hasActions: false, contextAllows: true))
    #expect(!RowSwipeContextKey.affectsLayout)
}

@MainActor
private func action(_ id: String, _ result: RowActionResult = .completed, log: Box? = nil)
    -> RowAction<Int>
{
    RowAction(id: id, title: id) { item in
        log?.performed.append("\(id)@\(item)")
        return result
    }
}

@MainActor
private final class Box {
    var performed: [String] = []
}

@MainActor
@Test
func test_swipeController_opensPastHalfButtonsAndClosesBelow() {
    let swipe = RowSwipeController<Int>()

    #expect(swipe.track(7, translation: -50, leadingCount: 0, trailingCount: 2, rowWidth: 320))
    #expect(swipe.openRow == 7 && swipe.edge == .trailing && swipe.offset(for: 7) == -50)
    #expect(!swipe.release(7, actionCount: 2, rowWidth: 320, allowsFullSwipe: true))
    #expect(swipe.openRow == nil)

    swipe.track(7, translation: -90, leadingCount: 0, trailingCount: 2, rowWidth: 320)
    #expect(!swipe.release(7, actionCount: 2, rowWidth: 320, allowsFullSwipe: true))
    #expect(swipe.openRow == 7 && swipe.revealed == 160 && swipe.phase == .open)
}

@MainActor
@Test
func test_swipeController_fullSwipeAndSideWithoutActions() {
    let swipe = RowSwipeController<Int>()

    #expect(!swipe.track(1, translation: 40, leadingCount: 0, trailingCount: 1, rowWidth: 320))
    #expect(swipe.openRow == nil)

    swipe.track(1, translation: -200, leadingCount: 0, trailingCount: 1, rowWidth: 320)
    #expect(swipe.release(1, actionCount: 1, rowWidth: 320, allowsFullSwipe: true))

    swipe.close()
    swipe.track(1, translation: -200, leadingCount: 0, trailingCount: 1, rowWidth: 320)
    #expect(!swipe.release(1, actionCount: 1, rowWidth: 320, allowsFullSwipe: false))
    #expect(swipe.revealed == 80)
}

@MainActor
@Test
func test_swipeController_oneOpenRowAndRemovedRowCloses() {
    let swipe = RowSwipeController<Int>()
    var changes: [Int?] = []
    swipe.onChange = { changes.append($0) }
    swipe.track(1, translation: 100, leadingCount: 1, trailingCount: 0, rowWidth: 320)
    _ = swipe.release(1, actionCount: 1, rowWidth: 320, allowsFullSwipe: false)

    swipe.track(2, translation: -100, leadingCount: 0, trailingCount: 1, rowWidth: 320)
    #expect(swipe.openRow == 2)
    #expect(swipe.offset(for: 1) == 0)
    #expect(changes.contains(1))

    swipe.itemsRemoved { $0 != 2 }
    #expect(swipe.openRow == nil)
}

@MainActor
@Test
func test_swipeController_performBlocksRepeatsFailureKeepsOpenAndRetryCloses() async {
    let swipe = RowSwipeController<Int>()
    let log = Box()
    var attempts = 0
    let flaky = RowAction<Int>(id: "archive", title: "Archive") { _ in
        attempts += 1
        return attempts == 1 ? .failed("offline") : .completed
    }
    swipe.track(4, translation: -100, leadingCount: 0, trailingCount: 1, rowWidth: 320)
    _ = swipe.release(4, actionCount: 1, rowWidth: 320, allowsFullSwipe: false)

    #expect(swipe.perform(flaky, for: 4))
    #expect(!swipe.perform(action("other", log: log), for: 4))
    #expect(swipe.phase == .performing(actionID: "archive"))
    for _ in 0..<20 { await Task.yield() }
    #expect(swipe.phase == .failed(actionID: "archive", message: "offline"))
    #expect(swipe.openRow == 4)

    #expect(swipe.perform(flaky, for: 4))
    for _ in 0..<20 { await Task.yield() }
    #expect(swipe.openRow == nil)
    #expect(attempts == 2)
    #expect(log.performed.isEmpty)
}

@MainActor
@Test
func test_swipeController_actionOfRemovedRowIsNotRepeatedOrMoved() async {
    let swipe = RowSwipeController<Int>()
    let log = Box()
    swipe.track(5, translation: -100, leadingCount: 0, trailingCount: 1, rowWidth: 320)
    _ = swipe.release(5, actionCount: 1, rowWidth: 320, allowsFullSwipe: false)
    swipe.perform(action("delete", log: log), for: 5)

    swipe.itemsRemoved { $0 != 5 }
    for _ in 0..<20 { await Task.yield() }

    #expect(log.performed == ["delete@5"])
    #expect(swipe.openRow == nil)
    #expect(!swipe.isPerforming(5))
}

@MainActor
@Test
func test_rowSwipeRecognizer_horizontalBeginsVerticalFails() {
    let recognizer = RowSwipeRecognizer()
    var reports: [(GestureState, Double)] = []
    recognizer.onSwipe = { reports.append(($0, $1)) }
    func event(_ type: EventType, _ x: Double, _ y: Double) -> Event {
        Event(
            type: type,
            targetID: NodeIDAllocator.allocate(),
            payload: .pointer(PointerData(point: LayoutPoint(x: x, y: y), pointerID: 1))
        )
    }

    _ = recognizer.handle(event(.pointerDown, 100, 100))
    #expect(recognizer.handle(event(.pointerMove, 70, 104)) == .began)
    _ = recognizer.handle(event(.pointerMove, 40, 106))
    _ = recognizer.handle(event(.pointerUp, 30, 106))
    #expect(reports.map(\.1) == [-30, -60, -70])

    recognizer.reset()
    _ = recognizer.handle(event(.pointerDown, 100, 100))
    #expect(recognizer.handle(event(.pointerMove, 104, 130)) == .failed)
}
