#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // R06 (implementation-plan-6.md, plan 6): the first native-backing prototype P6.3 asks for.
    // `docs/weave-scroll-analysis.md` §4 found Weave never used `NSScrollView`/`UIScrollView` at
    // all — offset was hand-applied to `layer.bounds.origin`. This proves the opposite shape: an
    // unmodified `TrellisHostView`, sized to its own full (unvirtualized) content height, embeds
    // as the sole `documentView` of a real `NSScrollView`. Nothing here is a new production API —
    // it is evidence for the architectural decision the plan's checklist asks R06 to record
    // before ScrollNode's real contract is written.

    @MainActor
    private func waitForAppKitCommit(_ hostLayer: CALayer) async {
        for _ in 0..<10_000 where hostLayer.sublayers?.isEmpty != false { await Task.yield() }
    }

    /// A 300×2000 content tree (taller than any reasonable viewport) inside an unmodified
    /// `TrellisHostView`: a `TextNode` near the top, a `ControlNode` near the bottom — placed so
    /// it starts outside any viewport shorter than the full content, the same "control inside and
    /// outside the viewport" scenario the plan's R06 checklist names explicitly.
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

        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        host.attach(root: root)
        return (host, control, text)
    }

    @Test
    @MainActor
    func test_appKitHostView_embedsUnmodifiedAsTheSoleDocumentViewOfARealScrollView() async throws {
        let (host, control, _) = makeTallContentHost()
        await waitForAppKitCommit(try #require(host.layer))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = host

        // One render subtree: no second host, no wrapper layer — the plan's own requirement
        // ("не создавать второй renderer или отдельный верхнеуровневый host на каждую строку").
        #expect(scrollView.documentView === host)
        #expect(host.frame.height == 2000)  // full, unvirtualized content — R10's job, not R06's
        #expect(scrollView.contentView.documentVisibleRect.height == 400)  // native viewport

        let controlFrame = try #require(control.calculatedFrame)
        #expect(controlFrame.origin.y + controlFrame.height > 400)  // starts outside the viewport
        #expect(
            !scrollView.contentView.documentVisibleRect.intersects(
                NSRect(
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
    func test_appKitHostView_nativeScrollMovesTheClipViewNotTheHostsOwnLayerBounds() async throws {
        let (host, control, _) = makeTallContentHost()
        await waitForAppKitCommit(try #require(host.layer))
        let hostLayer = try #require(host.layer)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        scrollView.documentView = host
        #expect(hostLayer.bounds.origin == .zero)

        let controlFrame = try #require(control.calculatedFrame)
        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: controlFrame.origin.y - 50)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // The plan's P6.3 requirement in one assertion: offset is the native clip view's own
        // state, not something Trellis's renderer had to be taught. Defect #63 (Weave writing
        // `layer.bounds.origin` by hand on every scroll tick) cannot recur if this holds.
        #expect(hostLayer.bounds.origin == .zero)
        #expect(scrollView.contentView.bounds.origin.y > 0)
        #expect(
            scrollView.contentView.documentVisibleRect.intersects(
                NSRect(
                    x: controlFrame.origin.x,
                    y: controlFrame.origin.y,
                    width: controlFrame.width,
                    height: controlFrame.height
                )
            )
        )

        // Trellis's own hit-test math never learned about the scroll: the same host-local point
        // that named the control before scrolling still names it after — one coordinate
        // conversion, exactly as P6.3 requires ("Координаты content, viewport и host имеют одну
        // проверяемую конверсию для hit testing").
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
