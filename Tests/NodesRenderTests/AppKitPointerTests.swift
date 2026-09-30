#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesAppKit
    import NodesRender
    import RichTextCore
    import Testing

    /// A button and a plain box with a tip, side by side.
    @MainActor
    private final class Bar: Node {
        let button = Button("Send") {}
        let box = Box()

        final class Box: Node {
            override var layoutContent: LeafContent? {
                .size(LayoutSize(width: 100, height: 40))
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                button
                box
            }
            .alignItems(.start)
        }
    }

    /// A view showing `bar` in a window that is not on screen, laid out.
    @MainActor
    private func view(_ bar: Bar) -> (NodeNSView, NSWindow) {
        let view = NodeNSView(root: bar)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) -> NSEvent {
        let location = view.convert(point, to: nil)
        let window = view.window?.windowNumber ?? 0
        // Entering and leaving are events of their own kind; AppKit refuses to make them
        // as mouse events.
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )!
        }
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    @Test @MainActor
    func theMouseOverAButtonLightensItAndLeavingTheViewLetsItGo() {
        let bar = Bar()
        let (view, window) = view(bar)
        defer { window.close() }
        let onButton = CGPoint(x: 10, y: 10)

        view.mouseMoved(with: mouse(.mouseMoved, at: onButton, in: view))
        #expect(bar.button.state == .hovered)
        #expect(bar.button.appearance.opacity == 0.85)
        view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 300, y: 80), in: view))
        #expect(bar.button.state == [])
        view.mouseEntered(with: mouse(.mouseEntered, at: onButton, in: view))
        #expect(bar.button.state == .hovered)
        view.mouseExited(with: mouse(.mouseExited, at: CGPoint(x: -5, y: 10), in: view))
        #expect(bar.button.state == [])

        bar.button.isEnabled = false
        view.mouseMoved(with: mouse(.mouseMoved, at: onButton, in: view))
        #expect(bar.button.state == .disabled)
        #expect(bar.button.appearance.opacity == 0.4)
    }

    @Test @MainActor
    func theViewGivesTheTipOfTheNodeUnderTheMouse() {
        let bar = Bar()
        bar.button.toolTip = "Send the message"
        bar.box.toolTip = "A box"
        let (view, window) = view(bar)
        defer { window.close() }
        let x = CGFloat(bar.box.frame.origin.x) + 10

        #expect(
            view.view(view, stringForToolTip: 0, point: CGPoint(x: 10, y: 10), userData: nil)
                == "Send the message"
        )
        #expect(
            view.view(view, stringForToolTip: 0, point: CGPoint(x: x, y: 10), userData: nil)
                == "A box"
        )
        #expect(
            view.view(view, stringForToolTip: 0, point: CGPoint(x: 390, y: 90), userData: nil) == ""
        )
    }

    /// A line of text with a link in it.
    @MainActor
    private final class Page: Node {
        let text = Text(
            rich: RichText(
                blocks: [
                    .paragraph([
                        Run("Read "), Run("the page", link: URL(string: "https://example.com")),
                        Run(" for more."),
                    ])
                ]
            )
        )

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { text }.alignItems(.start).padding(10)
        }
    }

    @Test @MainActor
    func theMouseOverALinkIsAHandAndGoesBackToTheArrowElsewhere() throws {
        let page = Page()
        page.text.onLink = { _ in }
        let view = NodeNSView(root: page)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.close() }

        let frame = page.text.frame
        // "Read " is 5 characters of about 8 points: the link starts past 40 points.
        let onLink = CGPoint(x: frame.origin.x + 70, y: frame.origin.y + frame.size.height / 2)
        let onWord = CGPoint(x: frame.origin.x + 8, y: frame.origin.y + frame.size.height / 2)

        NSCursor.arrow.set()
        view.mouseMoved(with: mouse(.mouseMoved, at: onWord, in: view))
        #expect(NSCursor.current == .arrow)
        view.mouseMoved(with: mouse(.mouseMoved, at: onLink, in: view))
        #expect(NSCursor.current == .pointingHand)
        view.mouseMoved(with: mouse(.mouseMoved, at: onWord, in: view))
        #expect(NSCursor.current == .arrow)

        view.mouseMoved(with: mouse(.mouseMoved, at: onLink, in: view))
        #expect(NSCursor.current == .pointingHand)
        view.mouseExited(with: mouse(.mouseExited, at: CGPoint(x: -5, y: 10), in: view))
        #expect(NSCursor.current == .arrow)
    }
#endif
