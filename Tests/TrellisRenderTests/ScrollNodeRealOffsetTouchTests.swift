#if canImport(UIKit)
    import UIKit
    import Testing

    @testable import TrellisCore
    @testable import TrellisRender
    @testable import TrellisUIKit

    // R08/defect #75: offset-aware hit testing for a `ControlNode` inside a `ScrollNode`, driven
    // by a real `UIScrollView.contentOffset` change (the same `scrollViewDidScroll` delegate path
    // a live drag uses, `UIScrollViewBacking.reportOffset`) and real `touchesBegan`/`touchesEnded`
    // through `TrellisHostView` — not a fake backing, not `bridge.send` directly. Proves the
    // `HitTestSnapshot`/`scrollOffsets` math itself is correct; it does not exercise
    // `TrellisTouchObserver`'s own gesture-recognizer delivery (touches routed by calling these
    // methods directly cannot reach a `UIGestureRecognizer` override — only real UIKit event
    // dispatch does), which is where defect #75's actual live bug turned out to be (see its
    // `docs/defects.md` entry and `TrellisTouchObserver`'s `shouldRecognizeSimultaneouslyWith`).
    @MainActor
    private func waitForCommit(_ host: TrellisHostView, _ count: Int) async {
        for _ in 0..<10_000 where (host.hostBridge?.committedCount ?? 0) < count {
            await Task.yield()
        }
    }

    @Test
    @MainActor
    func test_realNativeOffsetThenRealTouchesActivatesTheRevealedControl() async {
        let root = Node()
        root.style.flexDirection = .column
        root.style.width = 300
        root.style.height = 400
        let scroll = ScrollNode()
        scroll.style.flexDirection = .column
        scroll.style.width = 300
        scroll.style.height = 400

        // 10 rows of 100pt each — matches S33's shape (fixed rows far exceeding the viewport).
        var target: ControlNode?
        for index in 0..<10 {
            if index == 5 {
                let control = ControlNode()
                control.style.width = 300
                control.style.height = 100
                target = control
                scroll.addSubnode(control)
            } else {
                let row = Node()
                row.style.width = 300
                row.style.height = 100
                scroll.addSubnode(row)
            }
        }
        root.addSubnode(scroll)

        let host = TrellisHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        host.attach(root: root)
        await waitForCommit(host, 1)

        guard let target, let scrollView = host.subviews.compactMap({ $0 as? UIScrollView }).first
        else {
            Issue.record("expected a mounted target control and a real UIScrollView")
            return
        }

        var activations = 0
        target.activation = { activations += 1 }

        // Row 5 sits at content y 500...600 (5 * 100pt), scroll offset 500 puts it exactly at
        // viewport y 0...100 — the same shape as S33's reveal, driven by the real UIScrollView
        // property a drag would also mutate (this triggers `scrollViewDidScroll` synchronously,
        // same delegate path `UIScrollViewBacking.reportOffset` uses for a live drag).
        scrollView.contentOffset = CGPoint(x: 0, y: 500)

        // Give the offset-only commit path (no layout/raster) a chance to settle before reading
        // state — mirrors `waitForCommit`'s spin-yield style since there is no new `commit` to
        // await here (R07/R08: offset ticks are deliberately layout/raster-free).
        for _ in 0..<1_000 { await Task.yield() }

        #expect(scroll.state.offset.y == 500, "ScrollState should reflect the real native offset")

        let hostPoint = CGPoint(x: 150, y: 50)  // viewport-space point now over row 5
        let touch = FakeUITouch(location: hostPoint, view: host)
        let event = UIEvent()

        host.touchesBegan([touch], with: event)
        #expect(target.isPressed, "expected the revealed control to be pressed by a real touch")

        host.touchesEnded([touch], with: event)
        #expect(activations == 1, "expected exactly one activation from the real touch")
    }

    /// A minimal `UITouch` double: `UITouch` cannot be constructed directly, and
    /// `AppKitPointerInputTests.swift`'s equivalent (`NSEvent.mouseEvent`) has no UIKit analogue
    /// for touches — this subclass overrides only what `TrellisHostView.pointerData(for:)`/
    /// `orderedDeterministically` read (`location(in:)`, `timestamp`).
    private final class FakeUITouch: UITouch {
        private let fakeLocation: CGPoint
        private weak var fakeView: UIView?

        init(location: CGPoint, view: UIView) {
            self.fakeLocation = location
            self.fakeView = view
            super.init()
        }

        override func location(in view: UIView?) -> CGPoint { fakeLocation }
        override var timestamp: TimeInterval { 0 }
    }
#endif
