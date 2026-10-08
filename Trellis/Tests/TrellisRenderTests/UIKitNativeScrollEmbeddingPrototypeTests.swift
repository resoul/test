#if canImport(UIKit)
    import UIKit
    import Testing

    @testable import TrellisUIKit
    @testable import TrellisCore
    @testable import TrellisRender

    // R06 (implementation-plan-6.md, plan 6) — the UIKit half of the native-backing prototype
    // P6.3 asks for. See `AppKitNativeScrollEmbeddingPrototypeTests.swift` for the shared
    // rationale and `docs/weave-scroll-analysis.md` §4 for what Weave never had (no
    // `UIScrollView` anywhere; offset was hand-applied to `layer.bounds.origin`, defect #63).

    @MainActor
    private func waitForUIKitCommit(_ host: TrellisHostView) async {
        for _ in 0..<10_000 where host.layer.sublayers?.isEmpty != false { await Task.yield() }
    }

    /// A 300×2000 content tree inside an unmodified `TrellisHostView`: a `TextNode` near the
    /// top, a `ControlNode` near the bottom — outside any viewport shorter than the full
    /// content, matching the AppKit prototype's shape exactly (one shared contract, two hosts).
    @MainActor
    private func makeTallContentHost() -> (
        host: TrellisHostView, control: ControlNode, text: TextNode
    ) {
        let root = Node()
        root.style.flexDirection = .column
        root.style.width = 300
        root.style.height = 2000

        let text = TextNode(text: "Scrollable content — R06 native embedding prototype")
        text.style.width = 260
        text.style.height = 40
        root.addSubnode(text)

        let spacer = Node()
        spacer.style.width = 300
        spacer.style.height = 1860
        root.addSubnode(spacer)

        let control = ControlNode()
        control.style.width = 120
        control.style.height = 44
        root.addSubnode(control)

        let host = TrellisHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 2000))
        host.attach(root: root)
        return (host, control, text)
    }

    @Test
    @MainActor
    func test_uiKitHostView_embedsUnmodifiedAsTheSoleSubviewOfARealScrollView() async throws {
        let (host, control, _) = makeTallContentHost()
        await waitForUIKitCommit(host)

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        scrollView.addSubview(host)
        scrollView.contentSize = host.frame.size

        // One render subtree: no second host, no wrapper layer.
        #expect(scrollView.subviews == [host])
        #expect(host.frame.height == 2000)  // full, unvirtualized content — R10's job, not R06's
        #expect(scrollView.bounds.height == 400)  // native viewport

        let controlFrame = try #require(control.calculatedFrame)
        #expect(controlFrame.origin.y + controlFrame.height > 400)  // starts outside the viewport
        let visible = CGRect(x: 0, y: scrollView.contentOffset.y, width: 300, height: 400)
        #expect(
            !visible.intersects(
                CGRect(
                    x: controlFrame.origin.x,
                    y: controlFrame.origin.y,
                    width: controlFrame.width,
                    height: controlFrame.height
                )
            )
        )
    }

    @Test
    @MainActor
    func test_uiKitHostView_nativeScrollMovesTheScrollViewsLayerNotTheHostsOwnLayerBounds()
        async throws
    {
        let (host, control, _) = makeTallContentHost()
        await waitForUIKitCommit(host)
        let hostLayer = host.layer

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        scrollView.addSubview(host)
        scrollView.contentSize = host.frame.size
        #expect(hostLayer.bounds.origin == .zero)

        let controlFrame = try #require(control.calculatedFrame)
        scrollView.setContentOffset(
            CGPoint(x: 0, y: controlFrame.origin.y - 50),
            animated: false
        )

        // The plan's P6.3 requirement in one assertion: offset lives on the scroll view's own
        // layer/contentOffset, not something Trellis's renderer had to be taught. Defect #63
        // (Weave writing `layer.bounds.origin` by hand on every scroll tick) cannot recur here.
        #expect(hostLayer.bounds.origin == .zero)
        #expect(scrollView.contentOffset.y > 0)
        let visible = CGRect(
            x: 0,
            y: scrollView.contentOffset.y,
            width: 300,
            height: 400
        )
        #expect(
            visible.intersects(
                CGRect(
                    x: controlFrame.origin.x,
                    y: controlFrame.origin.y,
                    width: controlFrame.width,
                    height: controlFrame.height
                )
            )
        )

        // Trellis's own hit-test math never learned about the scroll: the same host-local point
        // that named the control before scrolling still names it after — one coordinate
        // conversion, exactly as P6.3 requires.
        let bridge = try #require(host.hostBridge)
        let point = LayoutPoint(
            x: controlFrame.origin.x + controlFrame.width / 2,
            y: controlFrame.origin.y + controlFrame.height / 2
        )
        guard
            case .delivered(let outcome) = bridge.send(
                .pointerDown,
                PointerData(point: point, pointerID: 1)
            )
        else {
            Issue.record("pointerDown was not delivered to the embedded host")
            return
        }
        #expect(outcome.reachedTarget)
        _ = bridge.send(.pointerUp, PointerData(point: point, pointerID: 1))
    }
#endif
