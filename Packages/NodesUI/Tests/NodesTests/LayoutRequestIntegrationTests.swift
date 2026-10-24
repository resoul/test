import FlexEngine
import LayoutCore
import Testing

@testable import Nodes

@MainActor
private final class RequestLeaf: Node {
    var content: LeafContent {
        didSet { setNeedsLayout() }
    }

    init(_ content: LeafContent = .size(width: 20, height: 10)) {
        self.content = content
    }

    override var layoutContent: LeafContent? { content }
}

@MainActor
private final class RequestRow: Node {
    let leaf: RequestLeaf
    let remainder = RequestLeaf(.size(width: 10, height: 10))
    let pendingLeaf = RequestLeaf(.size(width: 10, height: 10))
    var repeatsLeaf = false {
        didSet { setNeedsLayout() }
    }
    var showsPendingLeaf = false {
        didSet { setNeedsLayout() }
    }

    init(leaf: RequestLeaf = RequestLeaf()) {
        self.leaf = leaf
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            leaf
            if repeatsLeaf { leaf }
            if showsPendingLeaf { pendingLeaf }
            remainder.flex(grow: 1)
        }
        .alignItems(.start)
    }
}

@MainActor
private func requestHost(_ root: Node) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: 200, height: 100))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func changingTheHostSizeInvalidatesAComputationBeforeTheNextPassStarts() async {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    host.didRender()
    var reports: [LayoutReport] = []
    var renders = 0
    host.onLayoutReport = { reports.append($0) }
    host.onNeedsRender = { renders += 1 }

    row.leaf.content = .size(width: 40, height: 10)
    host.layoutIfNeeded()
    // Both mutations happen before the background task can return to the main actor.
    host.size = LayoutSize(width: 400, height: 100)
    await host.layoutFinished()

    #expect(host.passes == 1)
    #expect(host.needsLayout)
    #expect(row.frame.size.width == 200)
    #expect(row.leaf.frame.size.width == 20)
    #expect(reports.isEmpty)
    #expect(renders == 0)

    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(row.frame.size.width == 400)
    #expect(row.leaf.frame.size.width == 40)
    #expect(row.remainder.frame.size.width == 360)
    #expect(reports.count == 1)
    #expect(renders == 1)
}

@Test @MainActor
func changingNodeContentInvalidatesAComputationBeforeTheNextPassStarts() async {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    var reports: [LayoutReport] = []
    host.onLayoutReport = { reports.append($0) }

    row.leaf.content = .size(width: 40, height: 10)
    host.layoutIfNeeded()
    row.leaf.content = .size(width: 60, height: 10)
    await host.layoutFinished()

    #expect(host.passes == 1)
    #expect(host.needsLayout)
    #expect(row.leaf.frame.size.width == 20)
    #expect(row.remainder.frame.size.width == 180)
    #expect(reports.isEmpty)

    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(row.leaf.frame.size.width == 60)
    #expect(row.remainder.frame.size.width == 140)
    #expect(reports.count == 1)
}

@Test @MainActor
func resizingTheHostFromItsLayoutReportPreventsAnOutdatedApply() {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.didRender()
    var resized = false
    host.onLayoutReport = { [weak host] _ in
        guard !resized else { return }
        resized = true
        host?.size = LayoutSize(width: 400, height: 100)
    }

    withAnimation(.linear(duration: 1)) {
        row.leaf.content = .size(width: 40, height: 10)
    }
    host.layoutIfNeeded()

    #expect(resized)
    #expect(host.passes == 1)
    #expect(host.needsLayout)
    #expect(row.frame.size.width == 200)
    #expect(row.leaf.frame.size.width == 20)
    #expect(host.renderAnimation == nil)

    host.onLayoutReport = nil
    host.layoutIfNeeded()

    #expect(host.passes == 2)
    #expect(row.frame.size.width == 400)
    #expect(row.leaf.frame.size.width == 40)
    #expect(row.remainder.frame.size.width == 360)
    #expect(host.renderAnimation == .linear(duration: 1))
}

@Test @MainActor
func aReentrantLayoutReportKeepsTheNewerComputationApplied() {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    var reentered = false
    host.onLayoutReport = { [weak host] _ in
        guard !reentered, let host else { return }
        reentered = true
        host.size = LayoutSize(width: 400, height: 100)
        host.layoutIfNeeded()
    }

    row.leaf.content = .size(width: 40, height: 10)
    host.layoutIfNeeded()

    #expect(reentered)
    #expect(host.passes == 2)
    #expect(!host.needsLayout)
    #expect(row.frame.size.width == 400)
    #expect(row.leaf.frame.size.width == 40)
    #expect(row.remainder.frame.size.width == 360)
}

@MainActor
private final class MainActorRequestContent: ContentMeasurer {
    var height = 10.0
    var measurements = 0

    nonisolated var requiresMainThread: Bool { true }

    nonisolated func minContentWidth() -> Double {
        MainActor.assumeIsolated { 30 }
    }

    nonisolated func maxContentWidth() -> Double {
        MainActor.assumeIsolated { 30 }
    }

    nonisolated func height(forWidth width: Double) -> Double {
        MainActor.assumeIsolated {
            measurements += 1
            return height
        }
    }
}

@Test @MainActor
func mainOnlyContentUsesTheExplicitMainActorRequestPath() {
    let content = MainActorRequestContent()
    let row = RequestRow(leaf: RequestLeaf(.measured(content)))
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    let measurements = content.measurements

    content.height = 40
    row.leaf.setNeedsLayout()
    host.layoutIfNeeded()

    #expect(host.passes == 2)
    #expect(content.measurements > measurements)
    #expect(row.leaf.frame.size == LayoutSize(width: 30, height: 40))
}

@Test @MainActor
func aBackgroundRequestRejectsDuplicateNodesWithoutChangingTheTree() async throws {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    let frame = row.leaf.frame
    let remainderFrame = row.remainder.frame
    var reports: [LayoutReport] = []
    host.onLayoutReport = { reports.append($0) }

    row.repeatsLeaf = true
    row.leaf.content = .size(width: 40, height: 10)
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(reports.count == 1)
    let report = try #require(reports.first)
    #expect(report.isRejected)
    #expect(report.duplicates == [row.leaf.id])
    #expect(host.passes == 1)
    #expect(row.leaf.frame == frame)
    #expect(row.remainder.frame == remainderFrame)
    #expect(row.subnodes.map(\.id) == [row.leaf.id, row.remainder.id])
}

@Test @MainActor
func aBackgroundRequestPreservesTheRequestedNodeTrace() async throws {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    host.traceAreas = [.place]
    host.tracedNodes = [row.leaf.id]
    var reports: [LayoutReport] = []
    host.onLayoutReport = { reports.append($0) }

    row.leaf.content = .size(width: 40, height: 10)
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(reports.count == 1)
    let report = try #require(reports.first)
    #expect(!report.isRejected)
    #expect(report.stack == .enough)
    #expect(report.trace.map(\.node) == [row.leaf.id])
    #expect(row.leaf.frame.size.width == 40)
}

@Test @MainActor
func aBackgroundReportKeepsANewerBackgroundPassPendingAndAnimated() async {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    host.didRender()
    var reports = 0
    var renders = 0
    var sawNewPendingNode = false
    host.onNeedsRender = { renders += 1 }
    host.onLayoutReport = { [weak host] _ in
        guard let host else { return }
        reports += 1
        if reports == 1 {
            withAnimation(.linear(duration: 1)) {
                host.size = LayoutSize(width: 400, height: 100)
                row.showsPendingLeaf = true
            }
            host.layoutIfNeeded()
            #expect(!row.pendingLeaf.isMounted)
            #expect(row.pendingLeaf.pendingHost === host)
        } else {
            sawNewPendingNode = row.pendingLeaf.pendingHost === host
        }
    }

    withAnimation(.easeIn(duration: 2)) {
        row.leaf.content = .size(width: 40, height: 10)
    }
    host.layoutIfNeeded()
    // The first wait captures the old task; its callback starts the task for the second.
    await host.layoutFinished()
    await host.layoutFinished()

    #expect(reports == 2)
    #expect(renders == 1)
    #expect(sawNewPendingNode)
    #expect(host.passes == 2)
    #expect(!host.needsLayout)
    #expect(row.frame.size.width == 400)
    #expect(row.leaf.frame.size.width == 40)
    #expect(row.pendingLeaf.isMounted)
    #expect(row.pendingLeaf.pendingHost == nil)
    #expect(row.remainder.frame.size.width == 350)
    #expect(host.renderAnimation == .linear(duration: 1))
}

@Test(arguments: [false, true]) @MainActor
func changingAnUnmountedNodeFromTheReportInvalidatesItsFirstComputation(
    _ solvesInBackground: Bool
) async {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = solvesInBackground
    var changed = false
    host.onLayoutReport = { [weak host] _ in
        guard !changed, let host else { return }
        changed = true
        #expect(!row.pendingLeaf.isMounted)
        #expect(row.pendingLeaf.pendingHost === host)
        row.pendingLeaf.content = .size(width: 70, height: 10)
    }

    row.showsPendingLeaf = true
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(changed)
    #expect(host.passes == 1)
    #expect(host.needsLayout)
    #expect(!row.pendingLeaf.isMounted)
    #expect(row.subnodes.map(\.id) == [row.leaf.id, row.remainder.id])

    host.onLayoutReport = nil
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(row.pendingLeaf.isMounted)
    #expect(row.pendingLeaf.frame.size.width == 70)
    #expect(row.remainder.frame.size.width == 110)
}

@Test @MainActor
func aDirtyBackgroundComputationCarriesItsAnimationIntoTheNextPass() async {
    let row = RequestRow()
    let host = requestHost(row)
    defer { host.detach() }
    host.solvesInBackground = true
    host.didRender()

    withAnimation(.spring(response: 0.4, dampingRatio: 0.9)) {
        row.leaf.content = .size(width: 40, height: 10)
    }
    host.layoutIfNeeded()
    row.leaf.content = .size(width: 60, height: 10)
    await host.layoutFinished()

    #expect(host.passes == 1)
    #expect(host.needsLayout)
    #expect(row.leaf.frame.size.width == 20)
    #expect(host.renderAnimation == nil)

    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(row.leaf.frame.size.width == 60)
    #expect(host.renderAnimation == .spring(response: 0.4, dampingRatio: 0.9))
}
