import LayoutCore
import Testing

@testable import Nodes

@MainActor
private final class Label: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 20)) }
}

/// A row that is tapped and swiped aside; a label inside it.
@MainActor
private final class Row: Node {
    let label = Label()
    var drags: [Drag] = []
    var taps = 0

    override init() {
        super.init()
        dragAxis = .horizontal
        onDrag = { [unowned self] drag in drags.append(drag) }
        onTap = { [unowned self] in taps += 1 }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) { label }.height(.points(40))
    }
}

@MainActor
private func host(_ row: Row) -> NodeHost {
    let host = NodeHost(root: row, size: LayoutSize(width: 200, height: 40))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func aDragAlongTheAxisGoesToTheNodeAndTakesTheTapAway() {
    let row = Row()
    let host = host(row)
    let start = LayoutPoint(x: 20, y: 10)

    host.pointerDown(at: start)
    #expect(host.canDrag(at: start, along: .horizontal))
    // On the label: the row, around it, takes it.
    #expect(host.dragBegan(at: start, along: .horizontal))
    host.dragMoved(by: LayoutPoint(x: -30, y: 2))
    host.dragEnded(by: LayoutPoint(x: -60, y: 3), velocity: LayoutPoint(x: -500, y: 0))
    host.pointerUp(at: LayoutPoint(x: 0, y: 10))

    #expect(row.drags.map(\.phase) == [.began, .changed, .ended])
    #expect(row.drags[1].translation == LayoutPoint(x: -30, y: 2))
    #expect(row.drags[2].velocity == LayoutPoint(x: -500, y: 0))
    #expect(row.taps == 0)
    host.detach()
}

@Test @MainActor
func aDragTheOtherWayIsNotTheNodes() {
    let row = Row()
    let host = host(row)

    #expect(!host.canDrag(at: LayoutPoint(x: 20, y: 10), along: .vertical))
    #expect(!host.dragBegan(at: LayoutPoint(x: 20, y: 10), along: .vertical))
    #expect(row.drags.isEmpty)
    host.detach()
}

@Test @MainActor
func aDragTheSystemTakesAwayIsCancelled() {
    let row = Row()
    let host = host(row)

    host.dragBegan(at: LayoutPoint(x: 20, y: 10), along: .horizontal)
    host.dragCancelled()
    // Nothing more comes after.
    host.dragMoved(by: LayoutPoint(x: 5, y: 0))

    #expect(row.drags.map(\.phase) == [.began, .cancelled])
    host.detach()
}

@MainActor
private final class Mail: Node {
    var done: [String] = []

    override init() {
        super.init()
        accessibility.label = "Mail"
        accessibilityActions = [
            AccessibilityAction(name: "Delete") { [unowned self] in
                done.append("Delete")
                return true
            },
            AccessibilityAction(name: "Flag") { [unowned self] in
                done.append("Flag")
                return true
            },
        ]
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
}

@Test @MainActor
func anElementOffersTheNodesActionsAndTheHostDoesThem() {
    let mail = Mail()
    let host = NodeHost(root: mail, size: LayoutSize(width: 100, height: 40))
    host.layoutIfNeeded()

    let item = host.accessibilityItems().first
    #expect(item?.actions == ["Delete", "Flag"])
    #expect(host.performAccessibilityAction(1, of: mail.id))
    #expect(!host.performAccessibilityAction(2, of: mail.id))
    #expect(mail.done == ["Flag"])
    host.detach()
}
