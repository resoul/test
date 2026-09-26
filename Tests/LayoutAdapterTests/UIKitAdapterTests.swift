#if canImport(UIKit)
    import LayoutCore
    @testable import LayoutUIKit
    import Testing
    import UIKit

    @MainActor
    private final class Card: LayoutView {
        let avatar = UIView()
        let badge = UIView()

        override init(frame: CGRect) {
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

    /// A view that cannot inherit from `LayoutView`, as a cell or a control.
    @MainActor
    private final class Row: UIView, LayoutSpecProviding {
        let icon = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(icon)
        }

        required init?(coder: NSCoder) { nil }

        func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { icon.size(24) }.padding(8)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyLayoutSpec()
        }
    }

    @MainActor
    @Test
    func layoutViewPlacesItsSubviews() {
        let card = Card(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
        card.setNeedsLayout()
        card.layoutIfNeeded()

        #expect(card.avatar.frame == CGRect(x: 16, y: 16, width: 48, height: 48))
        #expect(card.badge.frame == CGRect(x: 76, y: 35, width: 208, height: 10))
    }

    @MainActor
    @Test
    func layoutViewSizesItselfFromItsSpec() {
        let card = Card(frame: .zero)

        #expect(card.intrinsicContentSize == CGSize(width: 16 + 48 + 12 + 20 + 16, height: 80))
        // A width to fit in gives fit-content: no wider than the content.
        #expect(card.sizeThatFits(CGSize(width: 500, height: 0)) == CGSize(width: 112, height: 80))
    }

    @MainActor
    @Test
    func aLayoutViewInsideASpecMeasuresByItsOwnSpec() {
        let card = Card(frame: .zero)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        host.addSubview(card)

        FlexContainer(.column) { card }
            .alignItems(.start)
            .apply(in: LayoutRect(host.bounds))

        #expect(card.frame.size == CGSize(width: 112, height: 80))
    }

    @MainActor
    @Test
    func hiddenItemsHideTheirViews() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        let first = UIView()
        let second = UIView()
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

    @MainActor
    @Test
    func aViewThatCannotInheritLaysOutWithOneLine() {
        let row = Row(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        row.setNeedsLayout()
        row.layoutIfNeeded()

        #expect(row.icon.frame == CGRect(x: 8, y: 8, width: 24, height: 24))
        #expect(row.layoutSpecSize(fitting: .zero) == CGSize(width: 40, height: 40))
    }

    @MainActor
    @Test
    func aLabelIsMeasuredBySizeThatFits() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let label = UILabel()
        label.text = "Follow"
        host.addSubview(label)

        // UIKit rounds a label's size to the device's pixels, so at the device's scale
        // snapping leaves it as it is.
        let scale = Double(
            host.traitCollection.displayScale > 0 ? host.traitCollection.displayScale : 1
        )
        FlexContainer(.row) { label }
            .alignItems(.start)
            .apply(in: LayoutRect(host.bounds), scale: scale)

        let fitting = label.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        )
        #expect(label.frame.width == fitting.width)
        #expect(label.frame.height == fitting.height)
    }

    @MainActor
    @Test
    func rightToLeftStartsTheRowAtTheRight() {
        let card = Card(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
        card.semanticContentAttribute = .forceRightToLeft
        card.setNeedsLayout()
        card.layoutIfNeeded()

        #expect(card.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        #expect(card.avatar.frame == CGRect(x: 236, y: 16, width: 48, height: 48))
        #expect(card.badge.frame == CGRect(x: 16, y: 35, width: 208, height: 10))
    }

    @MainActor
    @Test
    func aFrameLeavesTheViewsTransformAlone() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let badge = UIView()
        badge.transform = CGAffineTransform(scaleX: 2, y: 2)
        host.addSubview(badge)

        FlexContainer(.row) { badge.size(10) }
            .apply(in: LayoutRect(host.bounds))

        #expect(badge.transform == CGAffineTransform(scaleX: 2, y: 2))
        #expect(badge.bounds.size == CGSize(width: 10, height: 10))
        #expect(badge.center == CGPoint(x: 5, y: 5))
    }

    /// An item laid out once, or — by mistake — twice.
    @MainActor
    private final class Repeated: LayoutView {
        let item = UIView()
        var twice = false

        override init(frame: CGRect) {
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
        let view = Repeated(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        var reports: [LayoutSpecReport] = []
        view.onLayoutReport = { reports.append($0) }
        view.traceAreas = [.place]
        view.tracedElements = [view.item]
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(reports.count == 1)
        #expect(reports.first?.hasProblems == false)
        #expect(reports.first?.host.hasPrefix("Repeated@") == true)
        #expect(reports.first?.trace.count == 1)
        #expect(view.item.frame == CGRect(x: 0, y: 0, width: 10, height: 10))

        // The item in two places: the pass is rejected and the item keeps its frame.
        view.twice = true
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(reports.last?.isRejected == true)
        #expect(reports.last?.duplicates.count == 1)
        #expect(view.item.frame == CGRect(x: 0, y: 0, width: 10, height: 10))
    }
#endif
