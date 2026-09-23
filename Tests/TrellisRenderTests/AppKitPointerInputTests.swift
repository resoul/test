#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore

    // H08: mouseDown/Dragged/Up through the real `TrellisHostView`, not through `bridge.send`
    // directly — the bridge-level path is already covered by
    // `Tests/TrellisRenderTests/PointerSessionBridgeTests.swift` (H04) and
    // `Tests/TrellisCoreTests/Controls/ControlNodeTests.swift` (H06); this proves the adapter's
    // own coordinate conversion and pointer identity, which those do not exercise.

    @MainActor
    private func waitForAppKitCommit(_ hostLayer: CALayer) async {
        for _ in 0..<10_000 where hostLayer.sublayers?.isEmpty != false { await Task.yield() }
    }

    /// `location` is in this view's own flipped, top-left space — the space `PointerData.point`
    /// ends up in. AppKit's `NSEvent.locationInWindow` is bottom-left-origin, so this flips it
    /// against `height`, mirroring what `TrellisHostView.pointerData(for:)` undoes via `convert`.
    private func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, height: CGFloat)
        -> NSEvent
    {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: location.x, y: height - location.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// Root 400×400 with one `ControlNode` at (0, 0, 100, 40).
    @MainActor
    private func makeHost() -> (TrellisHostView, ControlNode) {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let root = Node()
        let control = ControlNode()
        control.style.width = 100
        control.style.height = 40
        root.addSubnode(control)
        host.attach(root: root)
        return (host, control)
    }

    @Test
    @MainActor
    func test_appKitHostView_mouseDownUpInsideActivatesControl() async throws {
        let (host, control) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))
        var activations = 0
        control.activation = { activations += 1 }

        host.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 20), height: 400))
        #expect(control.isPressed)
        host.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 50, y: 20), height: 400))

        #expect(activations == 1)
        #expect(!control.isPressed)
    }

    @Test
    @MainActor
    func test_appKitHostView_mouseDraggedOutsideThenUpDoesNotActivate() async throws {
        let (host, control) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))
        var activations = 0
        control.activation = { activations += 1 }

        host.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 20), height: 400))
        #expect(control.isPressed)
        host.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 300, y: 300), height: 400)
        )
        #expect(!control.isPressed)
        host.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 300, y: 300), height: 400))

        #expect(activations == 0)
        #expect(!control.isPressed)
    }

    @Test
    @MainActor
    func test_appKitHostView_mouseUpOutsideAfterDownInsideDoesNotActivate() async throws {
        let (host, control) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))
        var activations = 0
        control.activation = { activations += 1 }

        host.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 20), height: 400))
        host.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 300, y: 300), height: 400))

        #expect(activations == 0)
    }

    @Test
    @MainActor
    func test_appKitHostView_nonFiniteLocationSendsNothing() async throws {
        let (host, control) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))

        host.mouseDown(
            with: mouseEvent(.leftMouseDown, at: NSPoint(x: CGFloat.nan, y: 20), height: 400)
        )

        #expect(!control.isPressed)
        // No session was ever started, so a later up is simply ignored, not mis-delivered.
        host.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 50, y: 20), height: 400))
        #expect(!control.isPressed)
    }

    @Test
    @MainActor
    func test_appKitHostView_windowResignationCancelsAnActivePress() async throws {
        let (host, control) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))
        var activations = 0
        control.activation = { activations += 1 }

        host.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 20), height: 400))
        #expect(control.isPressed)

        // No real NSWindow is attached in this fixture (matching `AppKitHostViewTests`), so
        // this exercises the same `suspend()` path `windowDidResignKey` calls, not the
        // notification wiring itself — that wiring is native glue, checked by build (H08).
        host.detach()

        #expect(!control.isPressed)
        #expect(activations == 0)
    }
#endif
