import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T07 / D65: "если изменились текст/стиль/locale, старое содержимое убирается; временная
// пустота допустима... показывать прежние данные как актуальные нельзя" — unlike a pure
// resize/rescale (kept in TextRasterLayerTests.swift), a content change must clear the raster
// layer's stale bitmap immediately, before the replacement is ready, rather than let it sit as
// if it were still current.
//
// Both tests below check `raster.contents` the instant `committedCount` reaches its new value
// and not a moment later: `RenderCoordinator.handle()` calls `onPostCommit` (which runs
// `scanForDisplayWork`, and therefore any `clearDisplayContent`) synchronously in the same call
// that increments `committedCount`, before this test ever gets to inspect either — and the
// replacement raster only starts on a `Task.detached` worker, which cannot have run yet at the
// instant the awaited condition first becomes true. So "check right after `waitForCommits`
// returns, add no further `await`" reliably observes the synchronous clear-or-keep decision,
// not a race against how fast the real `CoreTextRenderer` happens to finish.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func waitForArtifact(_ bridge: NodeHostBridge, _ id: NodeID) async {
    for _ in 0..<20_000 where bridge.displayArtifact(for: id) == nil { await Task.yield() }
}

@Test @MainActor
func t07_textChangeClearsTheStaleBitmapBeforeTheReplacementIsReady() async throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    await waitForArtifact(bridge, label.id)
    let outer = try #require(bridge.layer(for: label.id))
    let raster = try #require(outer.sublayers?.first)
    #expect(raster.contents != nil)

    label.text = "A completely different, much longer string that changes the box"
    await waitForCommits(bridge, 2)

    #expect(raster.contents == nil)
}

@Test @MainActor
func t07_pureResizeNeverClearsTheBitmapEvenBeforeTheNewOneArrives() async throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    await waitForArtifact(bridge, label.id)
    let outer = try #require(bridge.layer(for: label.id))
    let raster = try #require(outer.sublayers?.first)
    let originalContents = raster.contents
    #expect(originalContents != nil)

    root.style.width = 200
    await waitForCommits(bridge, 2)

    // Same text/style/theme/locale — only the box changed — so the old bitmap must still be
    // showing right now, not cleared while the (possibly not-yet-started) new raster is pending.
    #expect(raster.contents != nil)
}
