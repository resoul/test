#if canImport(UIKit)
    import Nodes
    import Testing
    import UIKit

    @testable import NodesUIKit

    /// A scroll's focus items as the focus system sees them: frames in its content.
    @MainActor
    private struct Content {
        let view = NodeView(root: Node())
        let container: ScrollFocusContainer

        init() {
            container = ScrollFocusContainer(view: view, scroll: Scroll(.vertical))
            container.frame = CGRect(x: 0, y: 0, width: 1760, height: 900)
        }

        func node(_ frame: CGRect) -> NodeFocusItem {
            let item = NodeFocusItem(view: view, node: Node().id)
            item.frame = frame
            item.parent = container
            container.items.append(item)
            return item
        }

        func section(_ frame: CGRect, holding items: [NodeFocusItem]) -> SectionEntry {
            let entry = SectionEntry(view: view, node: Node().id)
            entry.frame = frame
            entry.items = items.map(\.node)
            entry.parent = container
            container.items.append(entry)
            return entry
        }

        func target(from item: NodeFocusItem, _ heading: UIFocusHeading) -> NodeID? {
            view.reachTarget(from: item, heading: heading)
        }
    }

    @Test @MainActor
    func aNodeInAnotherColumnFarBelowIsReached() {
        let content = Content()
        let top = content.node(CGRect(x: 32, y: 32, width: 94, height: 76))
        // Five screens down, at the right: out of the strip under the top one.
        let bottom = content.node(CGRect(x: 1582, y: 5000, width: 146, height: 76))

        #expect(content.target(from: top, .down) == bottom.node)
        #expect(content.target(from: bottom, .up) == top.node)
        // Nothing lies further that way.
        #expect(content.target(from: bottom, .down) == nil)
        #expect(content.target(from: top, .up) == nil)
    }

    @Test @MainActor
    func theNearestAheadWinsAndAsideCountsTwice() {
        let content = Content()
        let from = content.node(CGRect(x: 100, y: 0, width: 100, height: 50))
        // 300 ahead, 400 aside: 1100.
        _ = content.node(CGRect(x: 600, y: 350, width: 100, height: 50))
        // 900 ahead, straight: 900.
        let straight = content.node(CGRect(x: 100, y: 950, width: 100, height: 50))
        // Overlapping the origin along the way pressed: not wholly below it.
        _ = content.node(CGRect(x: 300, y: 30, width: 100, height: 50))

        #expect(content.target(from: from, .down) == straight.node)
    }

    @Test @MainActor
    func aSectionIsReachedAsAWholeAndLeadsToItsNodeFocusedLast() {
        let content = Content()
        let top = content.node(CGRect(x: 32, y: 32, width: 94, height: 76))
        let first = content.node(CGRect(x: 1200, y: 4000, width: 100, height: 76))
        let second = content.node(CGRect(x: 1400, y: 4000, width: 100, height: 76))
        // A node outside the section, nearer the way pressed than the section's nodes but
        // not than the section itself.
        let entry = content.section(
            CGRect(x: 32, y: 3990, width: 1700, height: 96),
            holding: [first, second]
        )

        #expect(content.target(from: top, .down) == first.node)
        entry.lastFocused = second.node
        #expect(content.target(from: top, .down) == second.node)
        // Inside the section, its nodes count by themselves.
        entry.isEnabled = false
        #expect(content.target(from: first, .right) == second.node)
    }

    @Test @MainActor
    func theNodesOfAScrollInsideCount() {
        let content = Content()
        let top = content.node(CGRect(x: 32, y: 32, width: 94, height: 76))
        let inner = ScrollFocusContainer(view: content.view, scroll: Scroll(.horizontal))
        inner.parent = content.container
        inner.frame = CGRect(x: 0, y: 3000, width: 1760, height: 200)
        let tile = NodeFocusItem(view: content.view, node: Node().id)
        // In the inner scroll's content: 1000 along, where it starts at its offset 0.
        tile.frame = CGRect(x: 1000, y: 20, width: 150, height: 150)
        tile.parent = inner
        inner.items = [tile]
        content.container.items.append(inner)

        #expect(content.target(from: top, .down) == tile.node)
    }

    @Test @MainActor
    func headingsWithoutADirectionFindNothing() {
        #expect(
            NodeView.score(
                from: .zero,
                to: CGRect(x: 0, y: 100, width: 10, height: 10),
                heading: .next
            ) == nil
        )
        #expect(
            NodeView.score(
                from: .zero,
                to: CGRect(x: 0, y: 100, width: 10, height: 10),
                heading: .down
            ) == 100
        )
    }

    @Test @MainActor
    func fromAScrollInsideAMoveOutOfItGoesOnInTheScrollAround() {
        let content = Content()
        let top = content.node(CGRect(x: 32, y: 32, width: 94, height: 76))
        let inner = ScrollFocusContainer(view: content.view, scroll: Scroll(.horizontal))
        inner.parent = content.container
        inner.frame = CGRect(x: 0, y: 3000, width: 1760, height: 200)
        let tile = NodeFocusItem(view: content.view, node: Node().id)
        tile.frame = CGRect(x: 1000, y: 20, width: 150, height: 150)
        tile.parent = inner
        inner.items = [tile]
        content.container.items.append(inner)

        // Nothing above it in its row: the scroll around has the top node.
        #expect(content.view.reachTarget(from: tile, heading: .up) == top.node)
        #expect(content.view.reachTarget(from: tile, heading: .down) == nil)
    }
#endif
