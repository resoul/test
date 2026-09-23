#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // R14 (ADR 0037 §3, defect #93): a scroll view with `userInteractionEnabled == false` — a
    // locked page of `TabbedScrollNode` — passes the wheel up the responder chain, so the
    // enclosing outer scroll moves instead of the event being swallowed.

    @MainActor
    private final class WheelRecorder: NSView {
        var wheels = 0

        override func scrollWheel(with event: NSEvent) {
            wheels += 1
        }
    }

    @MainActor
    private final class IgnoringDelegate: NativeScrollBackingDelegate {
        func scrollBacking(
            for node: NodeID,
            didChangeOffset offset: LayoutPoint,
            phase: ScrollPhase
        ) {}
    }

    @Test @MainActor
    func r14_appKitDisabledScrollPassesTheWheelToTheEnclosingView() throws {
        let recorder = WheelRecorder(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let delegate = IgnoringDelegate()
        let backing = NSScrollViewBacking(
            nodeID: NodeIDAllocator.allocate(),
            delegate: delegate,
            superview: recorder
        )
        backing.setFrame(LayoutFrame(width: 300, height: 300), relativeTo: nil)
        let scrollView = try #require(recorder.subviews.first as? NSScrollView)
        let cgEvent = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -12,
                wheel2: 0,
                wheel3: 0
            )
        )
        let event = try #require(NSEvent(cgEvent: cgEvent))

        let locked = ScrollConfiguration(axis: .vertical, userInteractionEnabled: false)
        backing.apply(configuration: locked)
        scrollView.scrollWheel(with: event)
        #expect(recorder.wheels == 1)
        backing.dispose()
    }
#endif
