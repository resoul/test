import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// R14 (`implementation-plan-6.md`, P6.5, ADR 0037): TabbedScrollNode mounted in a real
// `NodeHostBridge` with recording scroll backings — the block sized to the viewport below the
// pin line, the page lock and its immediate native application, page positions, pinning on
// selection and tab taps, one gesture owner between the outer scroll and the pager.

@MainActor
private final class Backing: NativeScrollBacking {
    let nodeID: NodeID
    weak var delegate: (any NativeScrollBackingDelegate)?
    let containerLayer = CALayer()
    var contentOffset = LayoutPoint(x: 0, y: 0)
    /// `userInteractionEnabled` of every configuration that reached this native view.
    var appliedInteraction: [Bool] = []

    init(nodeID: NodeID, delegate: any NativeScrollBackingDelegate) {
        self.nodeID = nodeID
        self.delegate = delegate
    }

    var viewportSize: MeasuredSize {
        MeasuredSize(
            width: Double(containerLayer.bounds.width),
            height: Double(containerLayer.bounds.height)
        )
    }

    func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
        containerLayer.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        containerLayer.position = CGPoint(x: frame.origin.x, y: frame.origin.y)
    }

    var contentOriginInHost: LayoutPoint {
        LayoutPoint(x: Double(containerLayer.position.x), y: Double(containerLayer.position.y))
    }

    func setContentSize(_ size: MeasuredSize) {}
    func setInsets(_ insets: DirectionalEdgeInsets) {}
    func apply(configuration: ScrollConfiguration) {
        appliedInteraction.append(configuration.userInteractionEnabled)
    }
    func installContentLayer(_ layer: CALayer) { containerLayer.addSublayer(layer) }
    func removeContentLayer() {}
    func dispose() {}
    func scroll(
        to offset: LayoutPoint,
        animated: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        contentOffset = offset
        completion(true)
    }

    func drag(to y: Double, phase: ScrollPhase = .dragging) {
        contentOffset = LayoutPoint(x: 0, y: y)
        delegate?.scrollBacking(for: nodeID, didChangeOffset: contentOffset, phase: phase)
    }
}

private struct Row: Sendable, Equatable {
    let height: Double
}

@MainActor
private final class RowProvider: ItemProvider {
    func makeNode(for item: Row, id: Int) -> Node {
        let node = Node()
        node.style.height = .points(item.height)
        return node
    }

    func update(_ node: Node, with item: Row, id: Int) {}
}

@MainActor
private func feed(_ key: String) -> StateSubject<CollectionSnapshot<Int, Row>> {
    StateSubject(
        CollectionSnapshot(
            dataKey: key,
            revision: 1,
            items: (0..<300).map {
                CollectionItem(id: $0, value: Row(height: Double(30 + ($0 * 37) % 50)))
            }
        )
    )
}

@MainActor
private final class Fixture {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let header = Node()
    let tabbed: TabbedScrollNode<String>
    var backings: [NodeID: Backing] = [:]
    private var pointer: UInt64 = 0

    /// A 200 pt header over pages `a` and `b` (lists) and `c` (a short static page), in a
    /// 320×640 host.
    /// `fullBleed` keeps the root from folding the safe area into its padding, so the
    /// composition covers the whole host.
    init(
        placement: TabsPlacement = .pinned,
        safeArea: DirectionalEdgeInsets = DirectionalEdgeInsets(),
        fullBleed: Bool = false
    ) {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        header.style.height = .points(200)
        let feedA = feed("a")
        let feedB = feed("b")
        tabbed = TabbedScrollNode(
            header: header,
            tabs: .segmented(placement: placement),
            pages: [
                Tab(id: "a", title: "A") { ListNode(source: feedA, provider: RowProvider()) },
                Tab(id: "b", title: "B") { ListNode(source: feedB, provider: RowProvider()) },
                Tab(id: "c", title: "C") {
                    let page = Node()
                    page.style.height = .points(100)
                    return page
                },
            ]
        )
        tabbed.pager.settleAnimation = .none
        tabbed.style.flexGrow = 1
        root.style.flexDirection = .column
        if fullBleed {
            root.safeAreaIgnoredEdges = .all
        }
        root.addSubnode(tabbed)
        _ = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 640),
            scale: 1,
            safeAreaInsets: safeArea,
            scrollBackingFactory: { [weak self] id, delegate in
                let backing = Backing(nodeID: id, delegate: delegate)
                self?.backings[id] = backing
                return backing
            }
        )
    }

    /// The outer scroll's native view.
    var outer: Backing {
        backings[tabbed.scrollNode.id]!
    }

    func list(_ id: String) -> ListNode<RowProvider>? {
        tabbed.pager.page(for: id) as? ListNode<RowProvider>
    }

    func page(_ id: String) -> Backing? {
        list(id).flatMap { backings[$0.scrollNode.id] }
    }

    func settle() async {
        for _ in 0..<20_000 where bridge.committedCount < 2 {
            await Task.yield()
        }
        for _ in 0..<8 {
            let committed = bridge.committedCount
            for _ in 0..<500 where bridge.committedCount == committed {
                await Task.yield()
            }
            if bridge.committedCount == committed { return }
        }
    }

    /// A tap on tab `id`, at its position on screen (the outer offset applied).
    func tap(_ id: String) {
        guard let frame = tabbed.tabsNode.button(for: id)?.calculatedFrame else { return }

        pointer += 1
        let point = LayoutPoint(
            x: frame.origin.x + frame.width / 2,
            y: frame.origin.y + 10 - tabbed.scrollNode.state.offset.y
        )
        _ = bridge.send(.pointerDown, PointerData(point: point, pointerID: pointer))
        _ = bridge.send(.pointerUp, PointerData(point: point, pointerID: pointer))
    }

    /// A horizontal drag across the pages at y = 500 with a deterministic clock.
    func swipe(from start: Double, to end: Double, release: Bool = true) {
        pointer += 1
        let id = pointer
        var time = 0.0
        tabbed.pager.pan.now = { time }
        _ = bridge.send(
            .pointerDown,
            PointerData(point: LayoutPoint(x: start, y: 500), pointerID: id)
        )
        for step in 1...10 {
            time = Double(step) / 10
            let x = start + (end - start) * Double(step) / 10
            _ = bridge.send(
                .pointerMove,
                PointerData(point: LayoutPoint(x: x, y: 500), pointerID: id)
            )
        }
        if release {
            releaseSwipe(at: end)
        }
    }

    func releaseSwipe(at x: Double) {
        _ = bridge.send(
            .pointerUp,
            PointerData(point: LayoutPoint(x: x, y: 500), pointerID: pointer)
        )
    }
}

@MainActor
@Test
func test_tabbed_theBlockFillsTheViewportBelowThePinLine() async {
    let fixture = Fixture()
    await fixture.settle()

    #expect(fixture.tabbed.tabsNode.calculatedFrame?.origin.y == 200)
    #expect(fixture.tabbed.pager.calculatedFrame?.height == 640 - 44)
    // Header + one viewport: the largest outer offset is the pin offset.
    #expect(fixture.tabbed.scrollNode.state.contentSize.height == 840)
    #expect(!fixture.tabbed.isPinned)
    #expect(fixture.tabbed.collapseProgress == 0)
}

@MainActor
@Test
func test_tabbed_thePinLineFollowsTheCoveredSafeAreaAndPagesSeeNoTopSafeArea() async {
    let fixture = Fixture(
        safeArea: DirectionalEdgeInsets(top: 30, leading: 0, bottom: 20, trailing: 0),
        fullBleed: true
    )
    await fixture.settle()

    #expect(fixture.tabbed.pager.calculatedFrame?.height == 640 - 30 - 44)
    fixture.outer.drag(to: 170, phase: .idle)
    #expect(fixture.tabbed.isPinned)
    let list = fixture.list("a")
    #expect(list?.scrollNode.environment.safeAreaInsets.top == 0)
    #expect(list?.scrollNode.environment.safeAreaInsets.bottom == 20)
}

@MainActor
@Test
func test_tabbed_insideARootThatFoldedTheSafeAreaThereIsNothingToCover() async {
    let fixture = Fixture(
        safeArea: DirectionalEdgeInsets(top: 30, leading: 0, bottom: 20, trailing: 0)
    )
    await fixture.settle()

    // The root's padding already keeps the composition clear of the safe area.
    #expect(fixture.tabbed.calculatedFrame?.origin.y == 30)
    #expect(fixture.tabbed.pager.calculatedFrame?.height == 640 - 30 - 20 - 44)
    fixture.outer.drag(to: 200, phase: .idle)
    #expect(fixture.tabbed.isPinned)
    #expect(fixture.list("a")?.scrollNode.environment.safeAreaInsets.bottom == 0)
}

@MainActor
@Test
func test_tabbed_pagesAreLockedUntilPinnedAndTheLockReachesTheNativeViewAtOnce() async {
    let fixture = Fixture()
    await fixture.settle()
    let a = fixture.list("a")!
    let b = fixture.list("b")!
    let native = fixture.page("a")!
    #expect(!a.scrollNode.configuration.userInteractionEnabled)
    #expect(!b.scrollNode.configuration.userInteractionEnabled)
    #expect(native.appliedInteraction.last == false)

    fixture.outer.drag(to: 120)
    #expect(!fixture.tabbed.isPinned)
    #expect(abs(fixture.tabbed.collapseProgress - 0.6) < 0.001)

    // Offset ticks do not commit: the lock must reach the native view within the tick.
    fixture.outer.drag(to: 200)
    #expect(fixture.tabbed.isPinned)
    #expect(fixture.tabbed.collapseProgress == 1)
    #expect(a.scrollNode.configuration.userInteractionEnabled)
    #expect(b.scrollNode.configuration.userInteractionEnabled)
    #expect(native.appliedInteraction.last == true)

    fixture.outer.drag(to: 150)
    #expect(!fixture.tabbed.isPinned)
    #expect(native.appliedInteraction.last == false)
}

@MainActor
@Test
func test_tabbed_expandingReturnsOnlyTheSelectedPageToItsTop() async {
    let fixture = Fixture()
    await fixture.settle()
    fixture.outer.drag(to: 200, phase: .idle)
    fixture.page("a")!.drag(to: 500, phase: .idle)
    fixture.page("b")!.drag(to: 300, phase: .idle)
    await fixture.settle()

    fixture.outer.drag(to: 100)
    #expect(fixture.page("a")!.contentOffset.y == 0)
    #expect(fixture.page("b")!.contentOffset.y == 300)
}

@MainActor
@Test
func test_tabbed_selectingAPageBelowItsTopWhileExpandedPinsTheTabs() async {
    let fixture = Fixture()
    await fixture.settle()
    fixture.outer.drag(to: 200, phase: .idle)
    fixture.page("b")!.drag(to: 300, phase: .idle)
    fixture.outer.drag(to: 0, phase: .idle)
    #expect(!fixture.tabbed.isPinned)

    fixture.tabbed.select("b", animated: false)
    await fixture.settle()
    #expect(fixture.outer.contentOffset.y == 200)
    #expect(fixture.tabbed.isPinned)
    #expect(fixture.page("b")!.contentOffset.y == 300)
}

@MainActor
@Test
func test_tabbed_selectingAPageAtItsTopKeepsTheHeader() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.tabbed.select("b", animated: false)
    await fixture.settle()
    #expect(fixture.outer.contentOffset.y == 0)
    fixture.tabbed.select("c", animated: false)
    await fixture.settle()
    #expect(fixture.outer.contentOffset.y == 0)
    #expect(!fixture.tabbed.isPinned)
}

@MainActor
@Test
func test_tabbed_aRestoredPageBelowItsTopSelectedWhileExpandedPinsTheTabs() async {
    let fixture = Fixture()
    await fixture.settle()
    fixture.outer.drag(to: 200, phase: .idle)
    fixture.page("a")!.drag(to: 500, phase: .idle)
    await fixture.settle()
    fixture.tabbed.select("c", animated: false)
    await fixture.settle()
    #expect(!fixture.tabbed.pager.mountedIDs.contains("a"))

    fixture.outer.drag(to: 0, phase: .idle)
    fixture.tabbed.select("a", animated: false)
    await fixture.settle()
    #expect(fixture.tabbed.isPinned)
    #expect(fixture.outer.contentOffset.y == 200)
    #expect((fixture.page("a")?.contentOffset.y ?? 0) > 400)
}

@MainActor
@Test
func test_tabbed_tapOnTheSelectedTabPinsThenScrollsThePageToItsTop() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.tap("a")
    await fixture.settle()
    #expect(fixture.outer.contentOffset.y == 200)
    #expect(fixture.tabbed.isPinned)
    #expect(fixture.tabbed.selection == "a")

    fixture.page("a")!.drag(to: 400, phase: .idle)
    fixture.tap("a")
    await fixture.settle()
    #expect(fixture.page("a")!.contentOffset.y == 0)
    #expect(fixture.outer.contentOffset.y == 200)
}

@MainActor
@Test
func test_tabbed_pinTabsAndExpandHeaderMoveTheOuterScroll() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.tabbed.pinTabs(animated: false)
    await fixture.settle()
    #expect(fixture.tabbed.isPinned)
    fixture.page("a")!.drag(to: 300, phase: .idle)

    fixture.tabbed.expandHeader(animated: false)
    await fixture.settle()
    #expect(fixture.outer.contentOffset.y == 0)
    #expect(!fixture.tabbed.isPinned)
    #expect(fixture.page("a")!.contentOffset.y == 0)
}

@MainActor
@Test
func test_tabbed_oneGestureOwnerBetweenTheOuterScrollAndThePager() async {
    let fixture = Fixture()
    await fixture.settle()
    let outer = fixture.tabbed.scrollNode

    // The outer scroll is being dragged: the pager does not begin.
    fixture.outer.drag(to: 40, phase: .dragging)
    fixture.swipe(from: 300, to: 60)
    await fixture.settle()
    #expect(fixture.tabbed.selection == "a")
    fixture.outer.drag(to: 40, phase: .idle)

    // A pager pan disables the outer scroll at once and restores it on release.
    fixture.swipe(from: 300, to: 200, release: false)
    #expect(!outer.configuration.userInteractionEnabled)
    #expect(fixture.outer.appliedInteraction.last == false)
    fixture.releaseSwipe(at: 200)
    #expect(outer.configuration.userInteractionEnabled)
    #expect(fixture.outer.appliedInteraction.last == true)
}

@MainActor
@Test
func test_tabbed_aHeaderThatGrowsWhilePinnedKeepsTheTabsPinned() async {
    let fixture = Fixture()
    await fixture.settle()
    fixture.outer.drag(to: 200, phase: .idle)
    #expect(fixture.tabbed.isPinned)

    fixture.header.style.height = .points(260)
    await fixture.settle()
    #expect(fixture.outer.contentOffset.y == 260)
    #expect(fixture.tabbed.isPinned)
}

@MainActor
@Test
func test_tabbed_inlineTabsScrollAwayAndThePagesStopAtThePinLine() async {
    let fixture = Fixture(placement: .inline)
    await fixture.settle()

    #expect(fixture.tabbed.pager.calculatedFrame?.height == 640)
    #expect(fixture.tabbed.scrollNode.state.contentSize.height == 200 + 44 + 640)
    fixture.outer.drag(to: 200, phase: .idle)
    #expect(!fixture.tabbed.isPinned)
    fixture.outer.drag(to: 244, phase: .idle)
    #expect(fixture.tabbed.isPinned)
}
