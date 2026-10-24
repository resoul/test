import FlexEngine
import LayoutCore
import Nodes
import Testing

private let rangeBounds = LayoutRect(x: 100, y: 200, width: 200, height: 100)

@Test(arguments: [
    LayoutRect(x: 301, y: 220, width: 20, height: 20),
    LayoutRect(x: 220, y: 301, width: 20, height: 20),
    LayoutRect(x: 79, y: 220, width: 20, height: 20),
    LayoutRect(x: 220, y: 179, width: 20, height: 20),
])
private func preparationRangesWorkAlongBothAxesAndOnBothSides(_ frame: LayoutRect) {
    let viewport = ContentViewport(bounds: rangeBounds)
    let demand = ContentRangePolicy().demand(for: frame, in: viewport)

    #expect(demand == ContentDemand.display.requirements)
    #expect(!demand.contains(.visible))
}

@Test
func aColdItemCanJumpDirectlyIntoTheVisibleRangeWithoutReadyContent() {
    let viewport = ContentViewport(bounds: rangeBounds)
    let frame = LayoutRect(x: 150, y: 220, width: 20, height: 20)
    let demand = ContentRangePolicy().demand(for: frame, in: viewport)
    let content = ContentLifecycle(key: 1, demand: demand)

    #expect(demand == ContentDemand.visible.requirements)
    #expect(content.readiness == ContentReadiness())
}

@Test
func aHorizontalPaneAndNestedVerticalClipLimitTheEffectiveViewport() {
    let viewport = ContentViewport(
        bounds: LayoutRect(x: 0, y: 0, width: 200, height: 400),
        clips: [
            LayoutRect(x: 150, y: 0, width: 200, height: 400),
            LayoutRect(x: 0, y: 100, width: 200, height: 150),
        ]
    )
    #expect(viewport.effectiveBounds == LayoutRect(x: 150, y: 100, width: 50, height: 150))
    let policy = ContentRangePolicy()
    let shownPart = LayoutRect(x: 140, y: 120, width: 20, height: 20)
    let clippedPart = LayoutRect(x: 100, y: 120, width: 20, height: 20)
    #expect(policy.demand(for: shownPart, in: viewport).contains(.visible))
    #expect(!policy.demand(for: clippedPart, in: viewport).contains(.visible))
    #expect(
        !policy.demand(for: LayoutRect(x: 160, y: 260, width: 20, height: 20), in: viewport)
            .contains(.visible)
    )
}

@Test
func aPreparingPaneCannotBecomeVisibleAndAnInactivePaneRequestsNothing() {
    let frame = LayoutRect(x: 150, y: 220, width: 20, height: 20)
    let policy = ContentRangePolicy()
    let preparing = ContentViewport(bounds: rangeBounds, activity: .preparing)
    let inactive = ContentViewport(bounds: rangeBounds, activity: .inactive)

    #expect(policy.demand(for: frame, in: preparing) == ContentDemand.display.requirements)
    #expect(policy.demand(for: frame, in: inactive, previous: .visible).isEmpty)
}

@Test
func retentionAvoidsRestartingWorkNearAnEntryBoundaryButDoesNotRetainVisible() {
    let viewport = ContentViewport(bounds: rangeBounds)
    let policy = ContentRangePolicy()
    let atDisplayEntry = LayoutRect(x: 150, y: 340, width: 20, height: 10)
    let pastDisplayEntry = LayoutRect(x: 150, y: 370, width: 20, height: 10)
    let pastDisplayRetention = LayoutRect(x: 150, y: 410, width: 20, height: 10)
    let pastPreloadEntry = LayoutRect(x: 150, y: 550, width: 20, height: 10)
    let pastPreloadRetention = LayoutRect(x: 150, y: 610, width: 20, height: 10)

    #expect(policy.demand(for: atDisplayEntry, in: viewport).contains(.display))
    #expect(policy.demand(for: pastDisplayEntry, in: viewport) == .preload)
    let retained = policy.demand(for: pastDisplayEntry, in: viewport, previous: .visible)
    #expect(retained == ContentDemand.display.requirements)
    #expect(!retained.contains(.visible))
    #expect(policy.demand(for: pastDisplayRetention, in: viewport, previous: retained) == .preload)
    #expect(policy.demand(for: pastPreloadEntry, in: viewport).isEmpty)
    #expect(policy.demand(for: pastPreloadEntry, in: viewport, previous: .preload) == .preload)
    #expect(policy.demand(for: pastPreloadRetention, in: viewport, previous: .preload).isEmpty)
}

@Test
func touchingTheViewportEdgeIsNotVisibleEvenWithZeroPreparationDistances() {
    let policy = ContentRangePolicy(
        preloadDistance: 0,
        displayDistance: 0,
        preloadRetentionDistance: 0,
        displayRetentionDistance: 0
    )
    let viewport = ContentViewport(bounds: rangeBounds)
    let touching = LayoutRect(x: 150, y: 300, width: 20, height: 20)
    let separated = LayoutRect(x: 150, y: 301, width: 20, height: 20)

    #expect(policy.demand(for: touching, in: viewport) == ContentDemand.display.requirements)
    #expect(!policy.demand(for: touching, in: viewport).contains(.visible))
    #expect(policy.demand(for: separated, in: viewport).isEmpty)
}

@Test
func rangeThresholdsStayNestedAndFinite() {
    let policy = ContentRangePolicy(
        preloadDistance: -10,
        displayDistance: 2,
        preloadRetentionDistance: .nan,
        displayRetentionDistance: 4
    )
    #expect(policy.preloadDistance == 2)
    #expect(policy.displayDistance == 2)
    #expect(policy.preloadRetentionDistance == 4)
    #expect(policy.displayRetentionDistance == 4)
    let nonFinite = ContentRangePolicy(
        preloadDistance: .infinity,
        displayDistance: .nan,
        preloadRetentionDistance: -.infinity,
        displayRetentionDistance: -1
    )
    #expect(nonFinite.preloadDistance == 0)
    #expect(nonFinite.displayRetentionDistance == 0)
}

@Test(arguments: [
    LayoutRect(x: 0, y: 0, width: 0, height: 100),
    LayoutRect(x: 0, y: 0, width: 100, height: -1),
    LayoutRect(x: .nan, y: 0, width: 100, height: 100),
    LayoutRect(x: 0, y: .infinity, width: 100, height: 100),
    LayoutRect(
        x: Double.greatestFiniteMagnitude,
        y: 0,
        width: Double.greatestFiniteMagnitude,
        height: 100
    ),
])
private func invalidFramesAndViewportsCannotCreateDemand(_ invalid: LayoutRect) {
    let policy = ContentRangePolicy()
    #expect(ContentViewport(bounds: invalid).effectiveBounds == nil)
    #expect(policy.demand(for: invalid, in: ContentViewport(bounds: rangeBounds)).isEmpty)
    let clipped = ContentViewport(bounds: rangeBounds, clips: [invalid])
    #expect(clipped.effectiveBounds == nil)
    #expect(policy.demand(for: rangeBounds, in: clipped, previous: .visible).isEmpty)
}

@Test
func scrollingUpdatesDemandForModelItemsWithoutNodesOrResourceReloads() throws {
    var content = ContentLifecycle(key: 42)
    let policy = ContentRangePolicy()
    let frame = LayoutRect(x: 0, y: 250, width: 100, height: 30)
    let initialViewport = ContentViewport(bounds: LayoutRect(x: 0, y: 0, width: 100, height: 100))
    content.updateDemand(policy.demand(for: frame, in: initialViewport))
    #expect(content.demand == .preload)
    let dataRequest = content.begin(.data)
    let data = try #require(dataRequest)
    #expect(content.complete(data, with: .ready) == true)

    let scrolledViewport = ContentViewport(
        bounds: LayoutRect(x: 0, y: 240, width: 100, height: 100)
    )
    let shown = policy.demand(for: frame, in: scrolledViewport, previous: content.demand)
    let transitionRequest = content.updateDemand(shown)
    let transition = try #require(transitionRequest)
    #expect(transition.entered == [.measure, .display, .visible])
    #expect(content.begin(.data) == nil)
    #expect(content.readiness.data == .ready)
    #expect(content.readiness.measurement == .idle)
    #expect(content.readiness.drawing == .idle)
    #expect(content.updateDemand(shown) == nil)
}

@MainActor
private final class ClippedRangePage: Node {
    let scroll = Scroll(.horizontal)
    let strip = ClippedRangeStrip()
    override init() {
        super.init()
        scroll.content = strip
    }
    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll.width(.points(100)).height(.points(100)) }
    }
}

@MainActor
private final class ClippedRangeStrip: Node {
    let spacer = Node()
    let item = Node()
    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            spacer.size(width: 120, height: 20)
            item.size(width: 20, height: 20)
        }
    }
}

@Test @MainActor
func nodeRangesUseTheEnclosingClipAndHostActivity() {
    let page = ClippedRangePage()
    let host = NodeHost(root: page, size: LayoutSize(width: 300, height: 200))
    defer { host.detach() }
    host.layoutIfNeeded()
    let policy = ContentRangePolicy(
        preloadDistance: 0.5,
        displayDistance: 0.1,
        preloadRetentionDistance: 0.5,
        displayRetentionDistance: 0.1
    )
    let item = page.strip.item
    #expect(item.contentDemand(in: policy) == .preload)
    page.scroll.contentOffset = LayoutPoint(x: 40, y: 0)
    #expect(item.contentDemand(in: policy).contains(.visible))
    page.scroll.appearance.opacity = 0
    #expect(item.contentDemand(in: policy).isEmpty)
    page.scroll.appearance.opacity = 1
    host.isInBackground = true
    #expect(item.contentDemand(in: policy).isEmpty)
    host.isInBackground = false
    host.isShown = false
    #expect(item.contentDemand(in: policy).isEmpty)
    host.isShown = true
    #expect(item.contentDemand(in: policy).contains(.visible))
}
