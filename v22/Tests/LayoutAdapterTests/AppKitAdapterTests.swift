#if canImport(AppKit)
    import AppKit
    import LayoutAppKit
    import LayoutCore
    import Testing

    @MainActor
    private final class Card: LayoutNSView {
        let avatar = NSView()
        let badge = NSView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(avatar)
            addSubview(badge)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                avatar.size(48)
                badge.size(width: 20, height: 10).flex(grow: 1)
            }
            .alignItems(.center)
            .gap(12)
            .padding(16)
        }
    }

    @MainActor
    @Test
    func layoutNSViewPlacesItsSubviews() {
        let card = Card(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()

        #expect(card.avatar.frame == CGRect(x: 16, y: 16, width: 48, height: 48))
        #expect(card.badge.frame == CGRect(x: 76, y: 35, width: 208, height: 10))
    }

    @MainActor
    @Test
    func layoutNSViewSizesItselfFromItsSpec() {
        let card = Card(frame: .zero)

        #expect(card.intrinsicContentSize == CGSize(width: 16 + 48 + 12 + 20 + 16, height: 80))
    }

    @MainActor
    @Test
    func framesAreMirroredInASuperviewThatIsNotFlipped() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let child = NSView()
        host.addSubview(child)

        FlexContainer(.column) { child.size(width: 20, height: 10) }
            .alignItems(.start)
            .apply(in: host.bounds)

        #expect(child.frame == CGRect(x: 0, y: 90, width: 20, height: 10))
    }

    @MainActor
    @Test
    func aLayoutNSViewInsideASpecMeasuresByItsOwnSpec() {
        let card = Card(frame: .zero)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        host.addSubview(card)

        FlexContainer(.column) { card }
            .alignItems(.start)
            .apply(in: host.bounds)

        #expect(card.frame.size == CGSize(width: 112, height: 80))
    }

    @MainActor
    @Test
    func hiddenItemsHideTheirViews() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let first = NSView()
        let second = NSView()
        host.addSubview(first)
        host.addSubview(second)

        FlexContainer(.row) {
            first.size(10).hidden()
            second.size(10).hidden(false)
        }
        .apply(in: host.bounds)

        #expect(first.isHidden)
        #expect(!second.isHidden)
        #expect(second.frame.minX == 0)
    }
#endif
