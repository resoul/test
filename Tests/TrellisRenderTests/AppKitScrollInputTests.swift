#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    @Test @MainActor
    func r08_appKitAXPageActionUsesNativeOffsetAndRejectsStaleHandler() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
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
        let coordinator = AppKitAccessibilityCoordinator(host: host, bridge: bridge)
        coordinator.apply(tree: try #require(bridge.accessibilityTree))
        bridge.onAccessibilityTreeChanged = { [weak coordinator] tree in
            coordinator?.apply(tree: tree)
        }
        let first = try #require(coordinator.element(for: cards[0].id))
        let action = try #require(first.accessibilityCustomActions()?.first)
        #expect(action.handler?() == true)
        #expect(scroll.state.offset.y == 200)
        #expect(bridge.semanticSnapshot?.record(for: cards[1].id)?.visibleBounds?.origin.y == 0)
        #expect(action.handler?() == false)
        host.detach()
        coordinator.removeAll()
        #expect(action.handler?() == false)
    }

    @MainActor
    private final class ScrollObserver: NativeScrollBackingDelegate {
        var offsets: [LayoutPoint] = []
        func scrollBacking(
            for node: NodeID,
            didChangeOffset offset: LayoutPoint,
            phase: ScrollPhase
        ) {
            offsets.append(offset)
        }
    }

    @Test @MainActor
    func r08_appKitBoundsTicksAndDisposeDisconnectObservers() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let observer = ScrollObserver()
        let backing = NSScrollViewBacking(
            nodeID: ScrollNode().id,
            delegate: observer,
            superview: host
        )
        backing.setFrame(LayoutFrame(width: 300, height: 200), relativeTo: nil)
        backing.setContentSize(MeasuredSize(width: 300, height: 1000))
        let native = try #require(host.subviews.compactMap { $0 as? NSScrollView }.first)
        native.contentView.scroll(to: NSPoint(x: 0, y: 100))
        #expect(observer.offsets.last?.y == 100)
        var completions: [Bool] = []
        backing.scroll(to: LayoutPoint(x: 0, y: 500), animated: true) { completions.append($0) }
        backing.dispose()
        let count = observer.offsets.count
        native.contentView.scroll(to: NSPoint(x: 0, y: 300))
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: native
        )
        #expect(observer.offsets.count == count)
        #expect(native.superview == nil)
        #expect(completions == [false])
    }
    @Test @MainActor
    func r08_appKitUserInputCancelsAnimationAndOldCompletionCannotMoveAgain() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let observer = ScrollObserver()
        let backing = NSScrollViewBacking(
            nodeID: ScrollNode().id,
            delegate: observer,
            superview: host
        )
        backing.setFrame(LayoutFrame(width: 300, height: 200), relativeTo: nil)
        backing.setContentSize(MeasuredSize(width: 300, height: 1000))
        let native = try #require(host.subviews.compactMap { $0 as? NSScrollView }.first)
        var completions: [Bool] = []
        backing.scroll(to: LayoutPoint(x: 0, y: 500), animated: true) { completions.append($0) }
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: native
        )
        #expect(completions == [false])
        backing.scroll(to: LayoutPoint(x: 0, y: 20), animated: false) { completions.append($0) }
        try await Task.sleep(for: .milliseconds(350))
        #expect(completions == [false, true])
        #expect(backing.contentOffset.y == 20)
        backing.dispose()
    }
#endif
