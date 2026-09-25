#if canImport(AppKit)
    import AppKit
    @testable import LayoutAppKit
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
            .apply(in: LayoutRect(host.bounds))

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
            .apply(in: LayoutRect(host.bounds))

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
        .apply(in: LayoutRect(host.bounds))

        #expect(first.isHidden)
        #expect(!second.isHidden)
        #expect(second.frame.minX == 0)
    }

    /// An item laid out once, or — by mistake — twice.
    @MainActor
    private final class Repeated: LayoutNSView {
        let item = NSView()
        var twice = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(item)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                item.size(10)
                if twice { item.size(10) }
            }
            .alignItems(.start)
        }
    }

    @MainActor
    @Test
    func aLayoutViewReportsItsPasses() {
        let view = Repeated(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        var reports: [LayoutSpecReport] = []
        view.onLayoutReport = { reports.append($0) }
        view.traceAreas = [.place]
        view.tracedElements = [view.item]
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        #expect(reports.count == 1)
        #expect(reports.first?.hasProblems == false)
        #expect(reports.first?.host.hasPrefix("Repeated@") == true)
        #expect(reports.first?.trace.count == 1)
        #expect(view.item.frame == CGRect(x: 0, y: 0, width: 10, height: 10))

        // The item in two places: the pass is rejected and the item keeps its frame.
        view.twice = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        #expect(reports.last?.isRejected == true)
        #expect(reports.last?.duplicates.count == 1)
        #expect(view.item.frame == CGRect(x: 0, y: 0, width: 10, height: 10))
    }
#endif
