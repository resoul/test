#if canImport(AppKit)
    import AppKit
    import Testing

    // A02 — native evidence for the AppKit side of D44/D47 (docs/validation/a02-native-prototype.md):
    // an `NSView` host exposing real `NSAccessibilityElement` children with role, label, screen
    // frame and a press action the system accessibility API can call — no NSView per node.

    /// Not `@MainActor`: `NSAccessibilityElement` is not isolated in the SDK, so its action
    /// overrides are nonisolated; the counter is touched only from the main thread anyway.
    private final class CardElement: NSAccessibilityElement {
        let identity: Int
        var activations = 0

        @MainActor
        init(identity: Int, frameInHost: NSRect, host: NSView) {
            self.identity = identity
            super.init()
            setAccessibilityRole(.button)
            setAccessibilityLabel("Card \(identity)")
            setAccessibilityParent(host)
            // Screen frame: host (flipped) → window → screen, all through the host view.
            let windowRect = host.convert(frameInHost, to: nil)
            setAccessibilityFrame(host.window?.convertToScreen(windowRect) ?? windowRect)
        }

        override func accessibilityPerformPress() -> Bool {
            activations += 1
            return true
        }
    }

    @MainActor
    private final class ElementHostView: NSView {
        var elements: [CardElement] = []

        override var isFlipped: Bool { true }

        override func isAccessibilityElement() -> Bool { false }

        override func accessibilityRole() -> NSAccessibility.Role? { .group }

        override func accessibilityChildren() -> [Any]? { elements }
    }

    @Test @MainActor
    func a02_appKitExposesRealAccessibilityElementsWithFrameAndPress() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = ElementHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = host
        host.elements = [
            CardElement(
                identity: 0,
                frameInHost: NSRect(x: 10, y: 10, width: 80, height: 40),
                host: host
            ),
            CardElement(
                identity: 1,
                frameInHost: NSRect(x: 10, y: 60, width: 80, height: 40),
                host: host
            ),
        ]

        let children = host.accessibilityChildren() as? [CardElement]
        #expect(children?.count == 2)
        #expect(children?[1].accessibilityLabel() == "Card 1")
        #expect(children?[1].accessibilityRole() == .button)
        #expect(children?[1].accessibilityParent() as? NSView === host)
        // Flipped host: y = 60 from the top of a 300-pt view is y = 200 from its bottom in
        // AppKit window space; the screen frame adds the window origin.
        let expectedWindowRect = host.convert(NSRect(x: 10, y: 60, width: 80, height: 40), to: nil)
        #expect(expectedWindowRect == NSRect(x: 10, y: 200, width: 80, height: 40))
        #expect(children?[1].accessibilityFrame() == window.convertToScreen(expectedWindowRect))
        #expect(children?[0].accessibilityPerformPress() == true)
        #expect(children?[0].activations == 1)
        #expect(children?[1].activations == 0)
    }
#endif
