import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// R13 (`implementation-plan-6.md`, P6.5/P6.9, ADR 0036): PagerNode and TabsNode mounted in a
// real `NodeHostBridge`; pans go through the bridge's pointer pipeline and gesture arena.

@MainActor
private final class Backing: NativeScrollBacking {
    let nodeID: NodeID
    weak var delegate: (any NativeScrollBackingDelegate)?
    let containerLayer = CALayer()
    var contentOffset = LayoutPoint(x: 0, y: 0)

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
    func apply(configuration: ScrollConfiguration) {}
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
        node.accessibility.isElement = true
        node.accessibility.identifier = "row-\(id)"
        return node
    }

    func update(_ node: Node, with item: Row, id: Int) {}
}

/// A model whose list data outlives the page UI: the page factory only builds nodes.
@MainActor
private final class FeedModel {
    let source = StateSubject(
        CollectionSnapshot(
            dataKey: "feed",
            revision: 1,
            items: (0..<300).map {
                CollectionItem(id: $0, value: Row(height: Double(30 + ($0 * 37) % 50)))
            }
        )
    )
    var refreshes = 0
}

@MainActor
private final class Fixture {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let pager: PagerNode<String>
    let tabs: TabsNode<String>
    let feed = FeedModel()
    var made: [String: Int] = [:]
    var progress: [PagerProgress<String>] = []
    var animations: [Animation] = []
    var selections: [String] = []
    var backings: [NodeID: Backing] = [:]
    private var pointer: UInt64 = 0

    init(
        pages: [String] = ["a", "b", "c", "d", "e"],
        direction: LayoutDirection = .leftToRight,
        reduceMotion: Bool = false,
        animated: Bool = false
    ) {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        pager = PagerNode(tabs: [])
        tabs = TabsNode(pager: pager)
        pager.tabs = pages.map { makeTab($0) }
        if !animated {
            pager.settleAnimation = .none
        }
        pager.style.flexGrow = 1
        pager.onProgressChange = { [weak self] progress, animation in
            self?.progress.append(progress)
            self?.animations.append(animation)
        }
        pager.onSelectionChange = { [weak self] in self?.selections.append($0) }
        root.style.flexDirection = .column
        root.addSubnode(tabs)
        root.addSubnode(pager)
        _ = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 400),
            scale: 1,
            layoutDirection: direction,
            reduceMotion: reduceMotion,
            scrollBackingFactory: { [weak self] id, delegate in
                let backing = Backing(nodeID: id, delegate: delegate)
                self?.backings[id] = backing
                return backing
            }
        )
    }

    func makeTab(_ id: String) -> Tab<String> {
        Tab(id: id, title: id.uppercased()) { [unowned self] in
            self.made[id, default: 0] += 1
            if id == "a" {
                let list = ListNode(source: self.feed.source, provider: RowProvider())
                list.loader.onRefresh = { [weak feed = self.feed] _ in
                    feed?.refreshes += 1
                    return .completed
                }
                return list
            }
            let page = Node()
            page.accessibility.isElement = true
            page.accessibility.identifier = "page-\(id)"
            return page
        }
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

    /// A horizontal drag across the pager at y = 200, with a deterministic clock: `seconds`
    /// is the total duration, so the release velocity is known.
    func drag(from start: Double, to end: Double, seconds: Double = 1, release: Bool = true) {
        pointer += 1
        let id = pointer
        var time = 0.0
        pager.pan.now = { time }
        _ = bridge.send(
            .pointerDown,
            PointerData(point: LayoutPoint(x: start, y: 200), pointerID: id)
        )
        let steps = 10
        for step in 1...steps {
            time = seconds * Double(step) / Double(steps)
            let x = start + (end - start) * Double(step) / Double(steps)
            _ = bridge.send(
                .pointerMove,
                PointerData(point: LayoutPoint(x: x, y: 200), pointerID: id)
            )
        }
        if release {
            _ = bridge.send(
                .pointerUp,
                PointerData(point: LayoutPoint(x: end, y: 200), pointerID: id)
            )
        }
    }

    /// Native offset of the pager's own scroll view.
    func offset() -> Double {
        guard let scroll = pager.subnodes.first as? ScrollNode else { return .nan }

        return backings[scroll.id]?.contentOffset.x ?? .nan
    }

    func tap(_ id: String) {
        guard let frame = tabs.button(for: id)?.calculatedFrame else { return }

        pointer += 1
        let point = LayoutPoint(x: frame.origin.x + frame.width / 2, y: frame.origin.y + 10)
        _ = bridge.send(.pointerDown, PointerData(point: point, pointerID: pointer))
        _ = bridge.send(.pointerUp, PointerData(point: point, pointerID: pointer))
    }

    func identifiers() -> [String] {
        var result: [String] = []
        func visit(_ element: AccessibilityElement) {
            if let identifier = element.identifier { result.append(identifier) }
            element.children.forEach(visit)
        }
        bridge.accessibilityTree?.elements.forEach(visit)
        return result
    }
}

@MainActor
@Test
func test_pager_mountsTheSelectedPageAndItsNeighboursOnly() async {
    let fixture = Fixture()
    await fixture.settle()
    #expect(fixture.pager.selection == "a")
    #expect(fixture.pager.mountedIDs == ["a", "b"])

    fixture.pager.select("c", animated: false)
    await fixture.settle()
    #expect(fixture.pager.mountedIDs == ["b", "c", "d"])
    #expect(fixture.offset() == 2 * 320)
    #expect(fixture.selections == ["c"])
    // Factories build on mount only, once per mount.
    #expect(fixture.made["e"] == nil)
    #expect(fixture.made["c"] == 1)
}

@MainActor
@Test
func test_pager_dragFollowsTheFingerAndReleasePastHalfCommitsTheNextPage() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.drag(from: 300, to: 100, seconds: 1, release: false)
    #expect(abs(fixture.offset() - 200) < 0.5)
    let during = fixture.pager.progress
    #expect(during.from == "a" && during.to == "b" && during.settled == nil)
    #expect(abs(during.fraction - 200.0 / 320) < 0.01)
    #expect(fixture.pager.selection == "a")  // committed only on release

    fixture.drag(from: 100, to: 100, seconds: 0.1)  // new pointer: ignored; release the first
    _ = fixture.bridge.send(
        .pointerUp,
        PointerData(point: LayoutPoint(x: 100, y: 200), pointerID: 1)
    )
    await fixture.settle()
    #expect(fixture.pager.selection == "b")
    #expect(fixture.pager.progress.settled == "b")
    #expect(fixture.offset() == 320)
    #expect(fixture.selections == ["b"])
}

@MainActor
@Test
func test_pager_shortSlowDragReturnsFastFlickAdvances() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.drag(from: 250, to: 150, seconds: 1)  // 100 pt at 100 pt/s
    await fixture.settle()
    #expect(fixture.pager.selection == "a")
    #expect(fixture.offset() == 0)
    #expect(fixture.pager.progress.settled == "a")

    fixture.drag(from: 250, to: 150, seconds: 0.1)  // 100 pt at 1000 pt/s
    await fixture.settle()
    #expect(fixture.pager.selection == "b")
    #expect(fixture.selections == ["b"])
}

@MainActor
@Test
func test_pager_oneGestureMovesAtMostOnePageAndStopsAtTheEdges() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.drag(from: 20, to: 300, seconds: 1, release: false)  // before the first page
    #expect(fixture.offset() == 0)  // hard edge
    _ = fixture.bridge.send(
        .pointerUp,
        PointerData(point: LayoutPoint(x: 300, y: 200), pointerID: 1)
    )
    await fixture.settle()
    #expect(fixture.pager.selection == "a")

    fixture.drag(from: 310, to: -700, seconds: 0.2)  // three widths: still one page
    await fixture.settle()
    #expect(fixture.pager.selection == "b")
}

@MainActor
@Test
func test_pager_rightToLeftMirrorsDragAndPlacement() async {
    let fixture = Fixture(direction: .rightToLeft)
    await fixture.settle()

    fixture.drag(from: 20, to: 250, seconds: 1)
    await fixture.settle()
    #expect(fixture.pager.selection == "b")
    #expect(fixture.offset() == 3 * 320)  // RTL: page b is second from the right
}

@MainActor
@Test
func test_pager_resizeKeepsTheSelectedPage() async {
    let fixture = Fixture()
    await fixture.settle()
    fixture.pager.select("c", animated: false)
    await fixture.settle()

    fixture.bridge.updateBounds(LayoutFrame(width: 200, height: 400), scale: 1)
    await fixture.settle()
    #expect(fixture.pager.selection == "c")
    #expect(fixture.offset() == 2 * 200)
    #expect(fixture.pager.page(for: "c")?.calculatedFrame?.width == 200)
}

@MainActor
@Test
func test_pager_reorderKeepsTheSelectionAndDeletingTheSelectedPageSelectsItsSuccessor()
    async
{
    let fixture = Fixture()
    await fixture.settle()
    fixture.pager.select("c", animated: false)
    await fixture.settle()

    fixture.pager.tabs = ["e", "c", "a", "b", "d"].map { fixture.makeTab($0) }
    await fixture.settle()
    #expect(fixture.pager.selection == "c")
    #expect(fixture.pager.mountedIDs == ["e", "c", "a"])
    #expect(fixture.offset() == 320)
    #expect(fixture.tabs.button(for: "e") != nil)

    fixture.pager.tabs = ["e", "a", "b", "d"].map { fixture.makeTab($0) }
    await fixture.settle()
    #expect(fixture.pager.selection == "a")  // took the deleted page's index
    #expect(fixture.selections.last == "a")
    #expect(fixture.tabs.button(for: "c") == nil)

    fixture.pager.tabs = []
    await fixture.settle()
    #expect(fixture.pager.selection == nil)
    #expect(fixture.pager.mountedIDs.isEmpty)
}

@MainActor
@Test
func test_pager_distantAnimatedSelectSlidesTheTargetInNextToTheCurrentPage() async {
    let fixture = Fixture(animated: true)
    await fixture.settle()

    fixture.pager.select("e")
    #expect(fixture.pager.selection == "e")
    #expect(fixture.animations.last == fixture.pager.settleAnimation)
    await fixture.settle()
    // Pages in between were never built; "e" ends at its own index.
    #expect(fixture.made["c"] == nil)
    #expect(fixture.made["d"] == 1)
    #expect(fixture.pager.mountedIDs == ["d", "e"])
    #expect(fixture.offset() == 4 * 320)
}

@MainActor
@Test
func test_pager_evictedListPageRestoresItsPositionWithoutRequestingAgain() async {
    let fixture = Fixture()
    await fixture.settle()
    let list = fixture.pager.page(for: "a") as! ListNode<RowProvider>
    let backing = fixture.backings[list.scrollNode.id]!
    backing.drag(to: 3_000, phase: .idle)
    await fixture.settle()
    let before = list.pagePosition!

    fixture.pager.select("d", animated: false)
    await fixture.settle()
    #expect(fixture.pager.page(for: "a") == nil)
    #expect(list.isDisposed)

    fixture.pager.select("a", animated: false)
    await fixture.settle()
    for _ in 0..<5 { await fixture.settle() }
    let rebuilt = fixture.pager.page(for: "a") as! ListNode<RowProvider>
    #expect(rebuilt !== list)
    #expect(fixture.made["a"] == 2)
    #expect(rebuilt.pagePosition?.itemID == before.itemID)
    #expect(
        rebuilt.pagePosition.map { abs($0.offsetFromTop - before.offsetFromTop) <= 0.5 } == true
    )
    #expect(fixture.feed.refreshes == 0)
}

@MainActor
@Test
func test_pager_tableInsidePagerLeavesTheHorizontalGestureToThePager() async {
    let fixture = Fixture()
    let source = StateSubject(
        CollectionSnapshot(
            dataKey: "mail",
            revision: 1,
            items: (0..<30).map { CollectionItem(id: $0, value: Row(height: 44)) }
        )
    )
    var performed = 0
    fixture.pager.tabs = [
        Tab(id: "mail", title: "Mail") {
            let table = TableNode(source: source, provider: RowProvider())
            table.trailingActions = { _ in
                [
                    RowAction(id: "delete", title: "Delete") { _ in
                        performed += 1
                        return .completed
                    }
                ]
            }
            return table
        },
        fixture.makeTab("b"),
    ]
    await fixture.settle()
    let table = fixture.pager.page(for: "mail") as! TableNode<RowProvider>

    fixture.drag(from: 300, to: 60, seconds: 1)
    await fixture.settle()
    #expect(table.swipe.openRow == nil)
    #expect(fixture.pager.selection == "b")
    #expect(performed == 0)
    // The actions stay reachable without the gesture.
    fixture.pager.select("mail", animated: false)
    await fixture.settle()
    let row = (fixture.pager.page(for: "mail") as! TableNode<RowProvider>).cell(for: 0)!.rowElement
    #expect(row.accessibility.customActions.map(\.id) == ["delete"])
}

@MainActor
@Test
func test_pager_aPageScrollingUnderTheFingerKeepsTheGestureAndAPanFreezesPageScrolls() async {
    let fixture = Fixture()
    await fixture.settle()
    let list = fixture.pager.page(for: "a") as! ListNode<RowProvider>
    let backing = fixture.backings[list.scrollNode.id]!

    backing.drag(to: 40, phase: .dragging)  // the page's own vertical drag is running
    fixture.drag(from: 300, to: 60, seconds: 1)
    await fixture.settle()
    #expect(fixture.pager.selection == "a")
    backing.drag(to: 40, phase: .idle)
    await fixture.settle()

    fixture.drag(from: 300, to: 200, seconds: 1, release: false)
    #expect(!list.scrollNode.configuration.userInteractionEnabled)
    _ = fixture.bridge.send(
        .pointerUp,
        PointerData(point: LayoutPoint(x: 200, y: 200), pointerID: 2)
    )
    #expect(list.scrollNode.configuration.userInteractionEnabled)
}

@MainActor
@Test
func test_pager_tabsSelectByTapAndIndicatorFollowsTheSameProgress() async {
    let fixture = Fixture()
    await fixture.settle()
    let width = 320.0 / 5

    fixture.tap("c")
    await fixture.settle()
    #expect(fixture.pager.selection == "c")
    #expect(fixture.tabs.button(for: "c")?.accessibility.isSelected == true)
    #expect(fixture.tabs.button(for: "a")?.accessibility.isSelected == false)
    let indicator = fixture.tabs.subnodes.last!
    #expect(indicator.style.offsets.leading == 2 * width)
    #expect(indicator.style.width == .points(width))

    // Half-way drag: the indicator is half-way between the two tabs.
    fixture.drag(from: 300, to: 140, seconds: 1, release: false)
    #expect(abs((indicator.style.offsets.leading ?? 0) - 2.5 * width) < 0.5)
    _ = fixture.bridge.send(
        .pointerUp,
        PointerData(point: LayoutPoint(x: 140, y: 200), pointerID: 2)
    )
}

@MainActor
@Test
func test_pager_onlyTheSelectedPageIsExposedToAccessibility() async {
    let fixture = Fixture()
    await fixture.settle()
    fixture.pager.select("c", animated: false)
    await fixture.settle()

    let identifiers = fixture.identifiers()
    #expect(identifiers.contains("page-c"))
    #expect(!identifiers.contains("page-b"))
    #expect(!identifiers.contains("page-d"))
    #expect(identifiers.filter { $0.hasPrefix("tab-") }.count == 5)

    // Half-way through a drag the neighbour is partly on screen but still not exposed: only
    // the committed page is read.
    fixture.drag(from: 300, to: 140, seconds: 1, release: false)
    await fixture.settle()
    let during = fixture.identifiers()
    #expect(during.contains("page-c"))
    #expect(!during.contains("page-d"))
}

@MainActor
@Test
func test_pager_reduceMotionSettlesWithoutAnimation() async {
    let fixture = Fixture(reduceMotion: true, animated: true)
    await fixture.settle()

    fixture.pager.select("b")
    #expect(fixture.animations.last == Animation.none)
    #expect(fixture.pager.mountedIDs == ["a", "b", "c"])  // evicted at once, nothing animates
}

@MainActor
@Test
func test_pager_detachDuringAPanReturnsToTheSelectedPage() async {
    let fixture = Fixture()
    await fixture.settle()

    fixture.drag(from: 300, to: 100, seconds: 1, release: false)
    fixture.bridge.detach()
    #expect(fixture.pager.selection == "a")
    #expect(fixture.offset() == 0)
    #expect(fixture.pager.pan.state != .began && fixture.pager.pan.state != .changed)
}
