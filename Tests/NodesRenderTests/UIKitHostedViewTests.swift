#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesUIKit
    import StateCore
    import Testing
    import UIKit

    @testable import NodesUIKit

    /// A view that says how big it wants to be.
    private final class Meter: UIView {
        var wanted = CGSize(width: 80, height: 40)
        override var intrinsicContentSize: CGSize { wanted }
    }

    @MainActor
    private final class Row: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 30)) }
    }

    /// A 20-point bar over a scroll of rows, the hosted view the third row of them.
    @MainActor
    private final class Screen: Node {
        let bar = Row()
        let before = [Row(), Row()]
        let hosted = HostedView(make: { Meter() })
        let after = (0..<8).map { _ in Row() }
        lazy var column = Column(children: before + [hosted] + after, hideable: hosted)
        lazy var scroll = Scroll(.vertical, content: column)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                bar.size(width: 50, height: 20)
                scroll
            }
        }
    }

    @MainActor
    private final class Column: Node {
        let children: [Node]
        let hideable: Node
        let hide = State(false)

        init(children: [Node], hideable: Node) {
            self.children = children
            self.hideable = hideable
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for child in children {
                    child.hidden(child === hideable && hide.value)
                }
            }
            .alignItems(.start)
        }
    }

    /// A 200 × 120 view of the screen, laid out: the scroll gets the 100 points under the bar.
    /// The second pass is the one that lays the hosted view out at the size it measured when
    /// the first made it.
    @MainActor
    private func view(of screen: Screen) -> NodeView {
        let view = NodeView(root: screen)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    /// The view that holds `hosted`'s, cutting it to what shows.
    @MainActor
    private func clip(of hosted: HostedView<Meter>) throws -> UIView {
        try #require(hosted.view?.superview)
    }

    @Test @MainActor
    func aHostedViewSitsAtItsNodesFrameAndTheNodeTakesTheViewsSize() throws {
        let screen = Screen()
        let view = view(of: screen)

        // Below the bar and two rows: 20 + 60 = 80, and the view's own 80 × 40.
        #expect(screen.hosted.preferredSize == LayoutSize(width: 80, height: 40))
        let clip = try clip(of: screen.hosted)
        #expect(clip.superview === view)
        #expect(clip.frame == CGRect(x: 0, y: 80, width: 80, height: 40))
        #expect(screen.hosted.view?.frame.size == CGSize(width: 80, height: 40))
        view.host.detach()
    }

    @Test @MainActor
    func aTouchOverAHostedViewInAScrollGoesToTheView() throws {
        let screen = Screen()
        let view = view(of: screen)
        let hosted = try #require(screen.hosted.view)

        let hit = try #require(view.hitTest(CGPoint(x: 40, y: 100), with: nil))
        #expect(hit === hosted || hit.isDescendant(of: hosted))
        view.host.detach()
    }

    @Test @MainActor
    func aViewThatChangesSizeMakesItsNodeLayOutAgain() throws {
        let screen = Screen()
        let view = view(of: screen)

        screen.hosted.view?.wanted = CGSize(width: 90, height: 25)
        screen.hosted.invalidateSize()
        view.layoutIfNeeded()

        #expect(screen.hosted.preferredSize == LayoutSize(width: 90, height: 25))
        #expect(screen.hosted.view?.frame.size == CGSize(width: 90, height: 25))
        view.host.detach()
    }

    @Test @MainActor
    func scrollingCutsTheViewAndScrollingItAwayCutsItToNothingWithoutHidingIt() throws {
        let screen = Screen()
        let view = view(of: screen)
        let hosted = try #require(screen.hosted.view)
        let clip = try clip(of: screen.hosted)

        // 30 points up: the view is at 50–90, wholly in the scroll's 20–120.
        screen.scroll.contentOffset = LayoutPoint(x: 0, y: 30)
        view.layoutIfNeeded()
        #expect(clip.frame == CGRect(x: 0, y: 50, width: 80, height: 40))

        // 75 points up: it is at 5–45, and the bar's 20 points are not the scroll's: cut at 20.
        screen.scroll.contentOffset = LayoutPoint(x: 0, y: 75)
        view.layoutIfNeeded()
        #expect(clip.frame == CGRect(x: 0, y: 20, width: 80, height: 25))
        #expect(hosted.frame.origin.y == -15)

        // Far enough that none of it shows: zero-sized, and still in the view.
        screen.scroll.contentOffset = LayoutPoint(x: 0, y: 130)
        view.layoutIfNeeded()
        #expect(clip.frame.size == .zero)
        #expect(!clip.isHidden && hosted.superview === clip)
        view.host.detach()
    }

    @Test @MainActor
    func aHiddenNodeTakesItsViewAwayAndShownAgainMakesOne() throws {
        let screen = Screen()
        let view = view(of: screen)
        let first = try #require(screen.hosted.view)

        screen.column.hide.value = true
        StateUpdates.flush()
        view.layoutIfNeeded()
        // Its holder is gone from the tree's view, and with it the view's clip.
        #expect(first.superview?.superview == nil)

        screen.column.hide.value = false
        StateUpdates.flush()
        view.layoutIfNeeded()
        let second = try #require(screen.hosted.view)
        #expect(second !== first)
        #expect(second.superview?.superview === view)
        view.host.detach()
    }

    @MainActor
    private final class Stacked: Node {
        let lower = HostedView(make: { Meter() })
        let upper = HostedView(make: { Meter() })

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                lower
                upper
            }
        }
    }

    @Test @MainActor
    func theViewsStandInTheOrderOfTheTree() throws {
        let stacked = Stacked()
        let view = NodeView(root: stacked)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutIfNeeded()

        let lower = try #require(stacked.lower.view?.superview)
        let upper = try #require(stacked.upper.view?.superview)
        let subviews = view.subviews
        let lowerIndex = try #require(subviews.firstIndex(of: lower))
        let upperIndex = try #require(subviews.firstIndex(of: upper))
        #expect(lowerIndex < upperIndex)
        view.host.detach()
    }

    @MainActor
    private final class Labelled: Node {
        let level = State(1)
        let hosted: HostedView<UILabel>

        override init() {
            let level = level
            hosted = HostedView(
                make: { UILabel() },
                update: { $0.text = "Level \(level.value)" }
            )
            super.init()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { hosted }
        }
    }

    @Test @MainActor
    func theViewShowsTheStateItsUpdateReadsAndFollowsItsChanges() throws {
        let node = Labelled()
        let view = NodeView(root: node)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutIfNeeded()
        #expect(node.hosted.view?.text == "Level 1")

        node.level.value = 2
        StateUpdates.flush()
        #expect(node.hosted.view?.text == "Level 2")
        view.host.detach()
    }

    @Test @MainActor
    func aFixedSizeIsTheNodesBeforeItsViewExists() {
        let hosted = HostedView(sizing: .fixed(LayoutSize(width: 30, height: 12))) { Meter() }
        #expect(hosted.preferredSize == LayoutSize(width: 30, height: 12))
        #expect(hosted.view == nil)
    }

    @Test @MainActor
    func aHostedFieldTakesTheKeyboardOnRequestAndSaysSo() throws {
        let node = Labelled2()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let view = NodeView(root: node)
        view.zoom = 1
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()

        #expect(!node.hosted.hasKeyboard)
        node.hosted.focus()
        #expect(node.hosted.hasKeyboard)
        node.hosted.unfocus()
        #expect(!node.hosted.hasKeyboard)
        view.host.detach()
    }

    @MainActor
    private final class Labelled2: Node {
        let hosted = HostedView(make: { UITextField() })

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { hosted }
        }
    }
#endif
