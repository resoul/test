import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// R12c (`implementation-plan-6.md`, P6.6, ADR 0034): TableNode mounted in a real
// `NodeHostBridge`; taps and swipes go through the bridge's pointer pipeline and gesture arena,
// actions through buttons and accessibility.

@MainActor
private final class TableBacking: NativeScrollBacking {
    let containerLayer = CALayer()
    var contentOffset = LayoutPoint(x: 0, y: 0)

    var viewportSize: MeasuredSize {
        MeasuredSize(
            width: Double(containerLayer.bounds.width),
            height: Double(containerLayer.bounds.height)
        )
    }

    func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
        containerLayer.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        containerLayer.position = CGPoint(x: frame.origin.x, y: frame.origin.y)
    }

    var contentOriginInHost: LayoutPoint {
        LayoutPoint(x: Double(containerLayer.position.x), y: Double(containerLayer.position.y))
    }

    func setContentSize(_ size: MeasuredSize) {}
    func setInsets(_ insets: DirectionalEdgeInsets) {}
    func apply(configuration: ScrollConfiguration) {}
    func installContentLayer(_ layer: CALayer) { containerLayer.addSublayer(layer) }
    func removeContentLayer() {}
    func dispose() {}
    func scroll(
        to offset: LayoutPoint,
        animated: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        contentOffset = offset
        completion(true)
    }
}

private struct Mail: Sendable, Equatable {
    let subject: String
}

@MainActor
private struct MailProvider: ItemProvider {
    func makeNode(for item: Mail, id: Int) -> Node {
        let node = Node()
        node.style.height = 44
        node.accessibility.label = item.subject
        return node
    }

    func update(_ node: Node, with item: Mail, id: Int) {}
}

@MainActor
private final class Inbox {
    let source: StateSubject<CollectionSnapshot<Int, Mail>>
    var performed: [String] = []
    var failuresLeft = 0

    init(sections: [(String, Range<Int>)] = [("inbox", 0..<30)]) {
        source = StateSubject(
            CollectionSnapshot(
                dataKey: "mail",
                revision: 1,
                sections: sections.map { name, ids in
                    CollectionSection(
                        id: name,
                        items: ids.map {
                            CollectionItem(id: $0, value: Mail(subject: "Mail \($0)"))
                        }
                    )
                }
            )
        )
    }

    func delete(_ id: Int) {
        let current = source.current
        source.send(
            CollectionSnapshot(
                dataKey: current.dataKey,
                revision: current.revision + 1,
                sections: current.sections.map { section in
                    CollectionSection(id: section.id, items: section.items.filter { $0.id != id })
                }
            )
        )
    }

    func actions(_ id: Int) -> [RowAction<Int>] {
        [
            RowAction(id: "archive", title: "Archive") { [weak self] item in
                guard let self else { return .completed }

                self.performed.append("archive@\(item)")
                if self.failuresLeft > 0 {
                    self.failuresLeft -= 1
                    return .failed("offline")
                }
                return .completed
            },
            RowAction(id: "delete", title: "Delete", style: .destructive) { [weak self] item in
                self?.performed.append("delete@\(item)")
                self?.delete(item)
                return .completed
            },
        ]
    }
}

@MainActor
private final class TableFixture {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let table: TableNode<MailProvider>
    let inbox: Inbox
    private var pointer: UInt64 = 0

    init(
        inbox: Inbox = Inbox(),
        direction: LayoutDirection = .leftToRight,
        configure: (TableNode<MailProvider>) -> Void = { _ in }
    ) {
        self.inbox = inbox
        bridge = NodeHostBridge(hostLayer: hostLayer)
        var style = LayoutStyle()
        style.width = 320
        style.height = 400
        table = TableNode(source: inbox.source, provider: MailProvider(), style: style)
        table.trailingActions = { [weak inbox] id in inbox?.actions(id) ?? [] }
        configure(table)
        root.addSubnode(table)
        _ = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 400),
            scale: 1,
            layoutDirection: direction,
            scrollBackingFactory: { _, _ in TableBacking() }
        )
    }

    func settle() async {
        for _ in 0..<6 {
            let committed = bridge.committedCount
            for _ in 0..<500 where bridge.committedCount == committed {
                await Task.yield()
            }
        }
    }

    func rowCenterY(_ id: Int) -> Double {
        let index = table.window.snapshot.index(of: id)!
        let frame = table.cell(for: id)?.calculatedFrame
        return table.window.itemOffset(at: index) + (frame?.height ?? 44) / 2
    }

    func tap(x: Double, y: Double) {
        pointer += 1
        let point = LayoutPoint(x: x, y: y)
        _ = bridge.send(.pointerDown, PointerData(point: point, pointerID: pointer))
        _ = bridge.send(.pointerUp, PointerData(point: point, pointerID: pointer))
    }

    func drag(y: Double, from start: Double, to end: Double, steps: Int = 6) {
        pointer += 1
        let id = pointer
        _ = bridge.send(
            .pointerDown,
            PointerData(point: LayoutPoint(x: start, y: y), pointerID: id)
        )
        for step in 1...steps {
            let x = start + (end - start) * Double(step) / Double(steps)
            _ = bridge.send(
                .pointerMove,
                PointerData(point: LayoutPoint(x: x, y: y), pointerID: id)
            )
        }
        _ = bridge.send(.pointerUp, PointerData(point: LayoutPoint(x: end, y: y), pointerID: id))
    }

    func translation(of id: Int) -> Double? {
        table.cell(for: id)?.subnodes.last { $0.subnodes.count == 2 }?.subnodes.last?.style.visual
            .transform.translationX
    }
}

@MainActor
@Test
func test_table_tapSelectsSingleAndMultipleAndReportsSelect() async {
    let fixture = TableFixture()
    var selected: [Int] = []
    fixture.table.events.onSelect = { selected.append($0) }
    await fixture.settle()

    fixture.tap(x: 100, y: fixture.rowCenterY(2))
    await fixture.settle()
    #expect(fixture.table.selection == [2])
    #expect(fixture.table.cell(for: 2)?.rowElement.accessibility.isSelected == true)

    fixture.tap(x: 100, y: fixture.rowCenterY(5))
    await fixture.settle()
    #expect(fixture.table.selection == [5])

    fixture.table.selectionMode = .multiple
    fixture.tap(x: 100, y: fixture.rowCenterY(2))
    fixture.tap(x: 100, y: fixture.rowCenterY(5))
    await fixture.settle()
    #expect(fixture.table.selection == [2])
    #expect(selected == [2, 5, 2, 5])
}

@MainActor
@Test
func test_table_sectionHeadersSitInFirstRowsAndLastRowsHaveNoSeparator() async {
    let fixture = TableFixture(inbox: Inbox(sections: [("today", 0..<3), ("older", 3..<6)])) {
        table in
        table.sectionHeader = { id in
            let header = Node()
            header.style.height = 30
            header.accessibility.label = "Header \(id)"
            return header
        }
    }
    await fixture.settle()

    let first = fixture.table.cell(for: 0)
    let second = fixture.table.cell(for: 1)
    let older = fixture.table.cell(for: 3)
    #expect(first?.subnodes.first?.accessibility.label == "Header today")
    #expect(older?.subnodes.first?.accessibility.label == "Header older")
    #expect(second?.subnodes.count == 2)
    // Header 30 + row 44 + the 0.5 pt separator rounded to one pixel at scale 1.
    let expected: Double = 30 + 44 + 1
    #expect(first?.calculatedFrame?.height == expected)
    #expect(fixture.table.cell(for: 2)?.subnodes.last?.style.height == .points(0))
    #expect(second?.subnodes.last?.style.height == .points(0.5))
}

@MainActor
@Test
func test_table_swipeRevealsTrailingActionsAndDeleteRemovesOnlyThatRow() async {
    let fixture = TableFixture()
    await fixture.settle()
    let y = fixture.rowCenterY(3)

    fixture.drag(y: y, from: 260, to: 150)
    await fixture.settle()
    #expect(fixture.table.swipe.openRow == 3)
    #expect(fixture.table.swipe.revealed == 160)
    #expect(fixture.translation(of: 3) == -160)

    fixture.tap(x: 300, y: y)  // Delete: the last trailing button, 240..<320
    await fixture.settle()
    #expect(fixture.inbox.performed == ["delete@3"])
    #expect(!fixture.table.window.snapshot.contains(3))
    #expect(fixture.table.window.snapshot.contains(4))
    #expect(fixture.table.swipe.openRow == nil)
}

@MainActor
@Test
func test_table_fullSwipePerformsFirstTrailingAction() async {
    let fixture = TableFixture()
    await fixture.settle()

    fixture.drag(y: fixture.rowCenterY(1), from: 300, to: 40)
    await fixture.settle()

    #expect(fixture.inbox.performed == ["archive@1"])
    #expect(fixture.table.swipe.openRow == nil)
}

@MainActor
@Test
func test_table_rightToLeftRevealsTrailingActionsOnTheLeft() async {
    let fixture = TableFixture(direction: .rightToLeft)
    await fixture.settle()

    fixture.drag(y: fixture.rowCenterY(2), from: 60, to: 170)
    await fixture.settle()

    #expect(fixture.table.swipe.openRow == 2)
    #expect(fixture.table.swipe.edge == .trailing)
    #expect(fixture.translation(of: 2) == 160)
}

@MainActor
@Test
func test_table_containerContextDisablesGestureButAccessibilityKeepsActions() async {
    let fixture = TableFixture()
    fixture.root.setEnvironment(RowSwipeContextKey.self, to: false)
    fixture.table.swipeActionsPolicy = .automatic
    await fixture.settle()

    fixture.drag(y: fixture.rowCenterY(2), from: 260, to: 100)
    await fixture.settle()
    #expect(fixture.table.swipe.openRow == nil)

    let row = fixture.table.cell(for: 2)!.rowElement
    #expect(row.accessibility.customActions.map(\.id) == ["archive", "delete"])
    #expect(fixture.bridge.performAccessibilityAction(.custom("archive"), on: row.id))
    await fixture.settle()
    #expect(fixture.inbox.performed == ["archive@2"])

    // An explicit policy overrides the container.
    fixture.table.swipeActionsPolicy = .enabled
    await fixture.settle()
    fixture.drag(y: fixture.rowCenterY(2), from: 260, to: 150)
    await fixture.settle()
    #expect(fixture.table.swipe.openRow == 2)
}

@MainActor
@Test
func test_table_failedActionStaysOpenWithRetryAndRetrySucceeds() async {
    let inbox = Inbox()
    inbox.failuresLeft = 1
    let fixture = TableFixture(inbox: inbox)
    await fixture.settle()
    let y = fixture.rowCenterY(4)

    fixture.drag(y: y, from: 260, to: 150)
    await fixture.settle()
    fixture.tap(x: 200, y: y)  // Archive: 160..<240
    await fixture.settle()
    #expect(fixture.table.swipe.phase == .failed(actionID: "archive", message: "offline"))
    #expect(fixture.table.swipe.openRow == 4)

    fixture.tap(x: 200, y: y)  // Retry
    await fixture.settle()
    #expect(inbox.performed == ["archive@4", "archive@4"])
    #expect(fixture.table.swipe.openRow == nil)
}
