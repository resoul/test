#if canImport(AppKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesAppKit
    import Testing

    @MainActor
    private final class Tappable: Node {
        var taps = 0

        override init() {
            super.init()
            onTap = { [unowned self] in taps += 1 }
            appearance.cornerRadius = 6
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 40, height: 20)) }
    }

    @MainActor
    private final class Pair: Node {
        let first = Tappable()
        let second = Tappable()

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                first; second
            }
            .gap(10)
            .padding(10)
            .alignItems(.start)
        }
    }

    @MainActor
    private func key(_ characters: String, up: Bool = false, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: up ? .keyUp : .keyDown,
            location: .zero,
            modifierFlags: shift ? .shift : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    @Test @MainActor
    func tabAndArrowsMoveTheFocusAndARingFollowsIt() throws {
        let pair = Pair()
        let view = NodeNSView(root: pair)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        view.layout()

        view.keyDown(with: key("\t"))
        view.layout()

        #expect(view.host.focusedNode == pair.first.id)
        #expect(pair.first.appearance.scale == 1)
        let ring = try #require(view.layer?.sublayers?.last)
        #expect(!ring.isHidden)
        #expect(ring.frame == CGRect(x: 6, y: 6, width: 48, height: 28))

        view.keyDown(with: key(String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        view.layout()

        #expect(view.host.focusedNode == pair.second.id)
        #expect(ring.frame.origin.x == 56)
        view.host.detach()
    }

    @Test @MainActor
    func spaceAndReturnPressTheFocusedNode() {
        let pair = Pair()
        let view = NodeNSView(root: pair)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        view.layout()
        view.host.focus(pair.second.id)

        view.keyDown(with: key(" "))
        view.keyUp(with: key(" ", up: true))
        view.keyDown(with: key("\r"))
        view.keyUp(with: key("\r", up: true))

        #expect(pair.second.taps == 2)
        #expect(pair.first.taps == 0)
        view.host.detach()
    }
#endif
