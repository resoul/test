#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    /// A row swiped aside, 40 points tall.
    @MainActor
    private final class Row: Node {
        var drags: [Drag] = []

        override init() {
            super.init()
            dragAxis = .horizontal
            onDrag = { [unowned self] drag in drags.append(drag) }
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 200, height: 40)) }
    }

    /// A node with two actions besides activating it.
    @MainActor
    private final class Mail: Node {
        var done: [String] = []

        override init() {
            super.init()
            accessibility.label = "Mail"
            accessibilityActions = ["Delete", "Flag"].map { name in
                AccessibilityAction(name: name) { [unowned self] in
                    done.append(name)
                    return true
                }
            }
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    /// Ten rows in a 100-point window.
    @MainActor
    private final class List: Node {
        let rows = (0..<10).map { _ in Row() }
        lazy var scroll = Scroll(.vertical, content: Column(rows: rows))

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }

        final class Column: Node {
            let rows: [Row]

            init(rows: [Row]) {
                self.rows = rows
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) {
                    for row in rows { row }
                }
            }
        }
    }
#endif

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    @testable import NodesAppKit

    @MainActor
    private func view(of list: List) -> NodeNSView {
        let view = NodeNSView(root: list)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layout()
        return view
    }

    @Test @MainActor
    func fingersAcrossARowDragItAndDoNotScroll() {
        let list = List()
        let view = view(of: list)
        let at = LayoutPoint(x: 100, y: 50)

        // Fingers moving left: the content would move right, 30 points.
        view.scroll(by: .zero, at: at, phase: .began, time: 1)
        view.scroll(by: LayoutPoint(x: 30, y: 2), at: at, phase: .touching, time: 1.01)
        view.scroll(by: LayoutPoint(x: 20, y: 0), at: at, phase: .touching, time: 1.02)
        view.scroll(by: .zero, at: at, phase: .released, time: 1.03)
        // The glide after goes nowhere, whichever way it goes.
        view.scroll(by: LayoutPoint(x: 40, y: 15), at: at, phase: .gliding, time: 1.1)

        let row = list.rows[1]
        #expect(row.drags.map(\.phase) == [.began, .changed, .changed, .ended])
        #expect(row.drags.last?.translation == LayoutPoint(x: -50, y: -2))
        #expect(list.scroll.contentOffset == .zero)
        view.host.detach()
    }

    @Test @MainActor
    func fingersAlongTheListScrollIt() {
        let list = List()
        let view = view(of: list)
        let at = LayoutPoint(x: 100, y: 50)

        view.scroll(by: .zero, at: at, phase: .began, time: 1)
        view.scroll(by: LayoutPoint(x: 2, y: 30), at: at, phase: .touching, time: 1.01)
        view.scroll(by: .zero, at: at, phase: .released, time: 1.02)

        #expect(list.rows.allSatisfy { $0.drags.isEmpty })
        #expect(list.scroll.contentOffset == LayoutPoint(x: 0, y: 30))
        view.host.detach()
    }
    @Test @MainActor
    func voiceOverOnTheMacListsTheNodesActionsAndDoesThem() throws {
        let mail = Mail()
        let view = NodeNSView(root: mail)
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        view.layout()

        let element = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        let actions = try #require(element.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Delete", "Flag"])
        #expect(actions[1].handler?() == true)
        #expect(mail.done == ["Flag"])
        view.host.detach()
    }
#endif

#if canImport(UIKit)
    import UIKit

    @testable import NodesUIKit

    @Test @MainActor
    func aPanAcrossARowDragsItAndOneAlongTheListDoesNot() {
        let list = List()
        let view = NodeView(root: list)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutIfNeeded()
        let at = CGPoint(x: 100, y: 50)

        #expect(view.dragAxis(at: at, velocity: CGPoint(x: -300, y: 20)) == .horizontal)
        #expect(view.dragAxis(at: at, velocity: CGPoint(x: 20, y: -300)) == nil)
        view.host.detach()
    }

    @Test @MainActor
    func voiceOverListsTheNodesActionsAndDoesThem() throws {
        let mail = Mail()
        let view = NodeView(root: mail)
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        view.layoutIfNeeded()

        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let actions = try #require(element.accessibilityCustomActions)
        #expect(actions.map(\.name) == ["Delete", "Flag"])
        #expect(actions[1].actionHandler?(actions[1]) == true)
        #expect(mail.done == ["Flag"])
        view.host.detach()
    }
#endif
