#if canImport(UIKit)
    import Testing
    import UIKit

    @testable import TrellisCore
    @testable import TrellisRender
    @testable import TrellisUIKit

    @Test @MainActor
    func r08_uiKitAXScrollUpdatesFramesAndRejectsStaleProxy() async throws {
        let host = TrellisHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let scroll = ScrollNode()
        scroll.style.flexDirection = .column
        let cards = (0..<3).map { _ in ControlNode() }
        for card in cards {
            card.style.width = 300
            card.style.height = 200
            card.accessibility.label = "Card"
            scroll.addSubnode(card)
        }
        host.attach(root: scroll)
        let bridge = try #require(host.hostBridge)
        for _ in 0..<10_000 where bridge.committedCount == 0 { await Task.yield() }
        let coordinator = NativeProxyCoordinator(host: host, bridge: bridge)
        let snapshot = try #require(bridge.semanticSnapshot)
        coordinator.apply(snapshot: snapshot, tree: bridge.accessibilityTree, scope: nil)
        bridge.onSemanticsPublished = { [weak coordinator, weak bridge] snapshot in
            coordinator?.apply(snapshot: snapshot, tree: bridge?.accessibilityTree, scope: nil)
        }
        let first = try #require(coordinator.proxy(for: cards[0].id))
        #expect(!first.accessibilityScroll(.up))
        #expect(first.accessibilityScroll(.down))
        #expect(scroll.state.offset.y == 200)
        #expect(bridge.semanticSnapshot?.record(for: cards[1].id)?.visibleBounds?.origin.y == 0)
        #expect(!first.accessibilityScroll(.down))
        let second = try #require(coordinator.proxy(for: cards[1].id))
        #expect(second.accessibilityScroll(.up))
        host.detach()
        coordinator.removeAll()
        #expect(!second.accessibilityScroll(.down))
    }

    @Test @MainActor
    func r08_uiKitRevealWaitsForNativeConfirmation() async throws {
        let host = TrellisHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let scroll = ScrollNode()
        scroll.style.flexDirection = .column
        let first = ControlNode()
        let second = ControlNode()
        for card in [first, second] {
            card.style.width = 300
            card.style.height = 200
            scroll.addSubnode(card)
        }
        host.attach(root: scroll)
        let bridge = try #require(host.hostBridge)
        for _ in 0..<10_000 where bridge.committedCount == 0 { await Task.yield() }
        let coordinator = NativeProxyCoordinator(host: host, bridge: bridge)
        coordinator.isNativeFocusEnabled = true
        coordinator.apply(
            snapshot: try #require(bridge.semanticSnapshot),
            tree: bridge.accessibilityTree,
            scope: nil
        )
        bridge.onSemanticsPublished = { [weak coordinator, weak bridge] snapshot in
            coordinator?.apply(snapshot: snapshot, tree: bridge?.accessibilityTree, scope: nil)
        }
        _ = bridge.focus(first.id, reason: .native)
        #expect(coordinator.revealFocus(.down))
        #expect(scroll.state.offset.y == 200)
        #expect(bridge.focusedID == nil)
        let target = try #require(coordinator.proxy(for: second.id))
        #expect(target.canBecomeFocused)
        coordinator.nativeFocusDidLand(on: target)
        #expect(bridge.focusedID == second.id)
        host.detach()
    }

    @MainActor
    private final class ScrollObserver: NativeScrollBackingDelegate {
        var count = 0
        func scrollBacking(
            for node: NodeID,
            didChangeOffset offset: LayoutPoint,
            phase: ScrollPhase
        ) {
            count += 1
        }
    }

    @Test @MainActor
    func r08_uiKitDisposeDisconnectsLateNativeTicksAndCompletesOnce() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let node = ScrollNode()
        let observer = ScrollObserver()
        let backing = UIScrollViewBacking(nodeID: node.id, delegate: observer, superview: host)
        backing.setFrame(LayoutFrame(width: 300, height: 200), relativeTo: nil)
        backing.setContentSize(MeasuredSize(width: 300, height: 1000))
        let native = try #require(host.subviews.compactMap { $0 as? UIScrollView }.first)
        var results: [Bool] = []
        backing.scroll(to: LayoutPoint(x: 0, y: 500), animated: true) { results.append($0) }
        let completedBeforeDispose = !results.isEmpty
        backing.dispose()
        let count = observer.count
        backing.scrollViewDidScroll(native)
        backing.scrollViewDidEndDecelerating(native)
        #expect(observer.count == count)
        #expect(native.delegate == nil)
        #expect(native.superview == nil)
        // Off-window UIKit may complete immediately; a genuinely pending command is cancelled.
        #expect(results == [completedBeforeDispose])
    }
    @Test @MainActor
    func r08_uiKitDragCancelsProgrammaticCompletionExactlyOnce() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let observer = ScrollObserver()
        let backing = UIScrollViewBacking(
            nodeID: ScrollNode().id,
            delegate: observer,
            superview: host
        )
        backing.setFrame(LayoutFrame(width: 300, height: 200), relativeTo: nil)
        backing.setContentSize(MeasuredSize(width: 300, height: 1000))
        let native = try #require(host.subviews.compactMap { $0 as? UIScrollView }.first)
        var completions: [Bool] = []
        backing.scroll(to: LayoutPoint(x: 0, y: 500), animated: true) { completions.append($0) }
        let completedBeforeDrag = !completions.isEmpty
        backing.scrollViewWillBeginDragging(native)
        backing.scrollViewDidEndScrollingAnimation(native)
        #expect(completions == [completedBeforeDrag])
        backing.dispose()
    }
#endif
