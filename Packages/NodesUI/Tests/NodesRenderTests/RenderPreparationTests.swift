#if canImport(CoreText)
    import CoreGraphics
    import Foundation
    import ImageIO
    import FlexEngine
    import LayoutCore
    import Nodes
    import QuartzCore
    import Testing
    import os
    @testable import NodesRender

    private final class BitmapGate: Sendable {
        private let state = OSAllocatedUnfairLock(
            initialState: (active: 0, peak: 0, entered: 0, order: [Int]())
        )
        private let gate = DispatchSemaphore(value: 0)

        var entered: Int { state.withLock { $0.entered } }
        var peak: Int { state.withLock { $0.peak } }
        var order: [Int] { state.withLock { $0.order } }
        func openOne() { gate.signal() }
        func open() { for _ in 0..<100 { gate.signal() } }
        func draw(_ label: Int) {
            state.withLock {
                $0.active += 1
                $0.entered += 1
                $0.order.append(label)
                $0.peak = max($0.peak, $0.active)
            }
            // An assertion failure must not leave test workers blocked indefinitely.
            let result = gate.wait(timeout: .now() + 5)
            #expect(result == .success)
            state.withLock { $0.active -= 1 }
        }
    }

    private struct GatedBitmap: DrawingSnapshot {
        let gate: BitmapGate
        let label: Int
        func draw(in context: CGContext, size: CGSize) {
            #expect(!Thread.isMainThread)
            gate.draw(label)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor private final class GatedDrawing: Node, LayerDrawing {
        let gate: BitmapGate
        let label: Int
        var revision: UInt64 = 0
        var prepareCount = 0
        var lastDemand: ContentDemand = []
        init(_ gate: BitmapGate, label: Int) { self.gate = gate; self.label = label }
        var drawingRevision: UInt64 { revision }
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 40, height: 20)) }
        func contentDemandChanged(_ demand: ContentDemand) { lastDemand = demand }
        func prepareDrawing(size: CGSize, scale: Double) { prepareCount += 1 }
        func draw(in context: CGContext, size: CGSize) {}
        func drawingSnapshot() -> (any DrawingSnapshot)? { GatedBitmap(gate: gate, label: label) }
    }

    @MainActor private final class DrawingPage: Node {
        let drawings: [GatedDrawing]
        var shows = true
        init(count: Int, gate: BitmapGate) {
            drawings = (0..<count).map { GatedDrawing(gate, label: $0) }
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { if shows { for drawing in drawings { drawing } } }
        }
    }

    private enum WaitFailure: Error { case timedOut }
    @MainActor private func eventually(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < end else { throw WaitFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test @MainActor func bitmapWorkersAndSnapshotsStayBoundedDuringCancellation() async throws {
        let gate = BitmapGate()
        defer { gate.open() }
        let page = DrawingPage(count: 12, gate: gate)
        let host = NodeHost(root: page, size: LayoutSize(width: 100, height: 300))
        defer { host.detach() }
        host.contentRangePolicy = ContentRangePolicy()
        host.layoutIfNeeded()
        let renderer = LayerRenderer(
            preparation: DrawingPreparationPolicy(
                maximumConcurrentTasks: 2,
                maximumQueuedDrawings: 2
            )
        )
        renderer.drawingMode = .asynchronous
        let container = CALayer()
        renderer.render(page, in: container)
        try await eventually { gate.entered == 2 }
        #expect(renderer.runningDrawCount == 2)
        #expect(renderer.queuedDrawCount == 2)
        #expect(renderer.pendingDrawCount == 4)
        host.isShown = false
        renderer.render(page, in: container)
        #expect(renderer.pendingDrawCount == 0)
        #expect(renderer.runningDrawCount == 2)
        host.isShown = true
        renderer.render(page, in: container)
        #expect(renderer.runningDrawCount == 2)
        #expect(renderer.queuedDrawCount <= 2)
        gate.open()
        await renderer.drawingsFinished()
        #expect(gate.peak == 2)
        #expect(renderer.runningDrawCount == 0)
        #expect(renderer.pendingDrawCount == 0)
        #expect(page.drawings.allSatisfy { renderer.layer(for: $0)?.contents != nil })
    }

    @Test @MainActor
    func newlyVisibleDrawingsOvertakeOldQueuedSnapshots() async throws {
        let gate = BitmapGate()
        defer { gate.open() }
        let page = DrawingPage(count: 12, gate: gate)
        let scroll = Scroll(.vertical)
        scroll.content = page
        let host = NodeHost(root: scroll, size: LayoutSize(width: 100, height: 80))
        defer { host.detach() }
        host.contentRangePolicy = ContentRangePolicy(preloadDistance: 20, displayDistance: 20)
        host.layoutIfNeeded()
        let renderer = LayerRenderer(
            preparation: DrawingPreparationPolicy(
                maximumConcurrentTasks: 1,
                maximumQueuedDrawings: 1
            )
        )
        renderer.drawingMode = .asynchronous
        renderer.render(scroll, in: CALayer())
        try await eventually { gate.entered == 1 }
        scroll.contentOffset = LayoutPoint(x: 0, y: 145)
        renderer.renderScrolls([scroll])
        gate.openOne()
        try await eventually { gate.entered == 2 }
        #expect(gate.order[1] >= 7)
        #expect(renderer.queuedDrawCount <= 1)
        gate.open()
        await renderer.drawingsFinished()
    }

    @Test(arguments: ["revision", "size", "scale", "removed", "background"])
    @MainActor func aBitmapInvalidatedBeforeTheNextRenderCannotCommit(_ change: String) async throws
    {
        let gate = BitmapGate()
        defer { gate.open() }
        let page = DrawingPage(count: 1, gate: gate)
        let node = page.drawings[0]
        let host = NodeHost(root: page, size: LayoutSize(width: 100, height: 100))
        defer { host.detach() }
        host.contentRangePolicy = ContentRangePolicy()
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        renderer.render(page, in: CALayer())
        try await eventually { gate.entered == 1 }
        #expect(renderer.drawingState(for: node) == .running)
        switch change {
        case "revision": node.revision += 1
        case "size": host.size = LayoutSize(width: 120, height: 100)
        case "scale": host.scale = 2
        case "removed": host.detach()
        default: host.isInBackground = true
        }
        gate.open()
        await renderer.drawingsFinished()
        #expect(renderer.layer(for: node)?.contents == nil)
        #expect(renderer.drawingState(for: node) != .ready)
    }

    @MainActor private final class LayerPicture: Node, LayerDrawing {
        var prepareCount = 0
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 40, height: 20)) }
        var drawingRevision: UInt64 { 0 }
        func prepareDrawing(size: CGSize, scale: Double) { prepareCount += 1 }
        var layerImage: LayerImage? { LayerImage(image: image, contentMode: .fit) }
        func draw(in context: CGContext, size: CGSize) {}
    }

    @MainActor private final class PicturePage: Node {
        let picture: Node
        let scroll = Scroll(.vertical)
        let content: Node
        init(_ picture: Node, space: Double) {
            self.picture = picture
            content = ColumnPicture(picture, space: space)
            super.init()
            scroll.content = content
        }
        override func layoutSpec() -> LayoutSpec? { FlexContainer(.column) { scroll } }
    }
    @MainActor private final class ColumnPicture: Node {
        let picture: Node
        let space: Double
        let spacer = Node()
        init(_ picture: Node, space: Double) { self.picture = picture; self.space = space }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                spacer.height(.points(space)); picture
            }
        }
    }

    private func fixtureImage() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try #require(context.makeImage())
    }
    private func fixtureBytes() throws -> Data {
        let bytes = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, try fixtureImage(), nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    @Test @MainActor func farLayerImagesDoNotPrepareOrBypassTheDisplayRange() throws {
        let picture = LayerPicture(try fixtureImage())
        let page = PicturePage(picture, space: 600)
        let host = NodeHost(root: page, size: LayoutSize(width: 100, height: 100))
        defer { host.detach() }
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.displayRange = .init(drawDistance: 0, releaseDistance: 1)
        renderer.render(page, in: CALayer())
        #expect(picture.prepareCount == 0)
        #expect(renderer.layer(for: picture)?.contents == nil)
    }

    @Test @MainActor func imagePreloadDoesNotDecodeAndDisplayPreparesPixels() async throws {
        let pipeline = ImagePipeline()
        let image = Image(
            source: .data(try fixtureBytes()),
            pipeline: pipeline,
            loadingMode: .demandDriven
        )
        #expect(image.contentReadiness.data == .idle)
        #expect(await pipeline.decodedCacheState().decodes == 0)
        image.contentDemandChanged(.preload)
        try await eventually { image.contentReadiness.data == .ready }
        #expect(image.decodedPixelSize == nil)
        #expect(await pipeline.decodedCacheState().decodes == 0)
        image.contentDemandChanged(.visible)
        try await eventually { image.contentReadiness.drawing == .ready }
        #expect(image.decodedPixelSize != nil)
        #expect(image.urgency.isUrgent)
        image.contentDemandChanged(.preload)
        #expect(image.decodedPixelSize == nil)
        #expect(!image.urgency.isUrgent)
        #expect(image.contentReadiness.data == .ready)
        image.contentDemandChanged(.display)
        try await eventually { image.decodedPixelSize != nil }
        image.contentDemandChanged([])
        #expect(image.decodedPixelSize == nil)
    }

    @Test @MainActor func rendererDrivesImageRangesAndDropsDemandOnRemoval() async throws {
        let image = Image(
            source: .data(try fixtureBytes()),
            placeholder: ImagePlaceholder(
                size: LayoutSize(width: 20, height: 20)
            ),
            pipeline: ImagePipeline(),
            loadingMode: .demandDriven
        )
        let page = PicturePage(image, space: 220)
        let host = NodeHost(root: page, size: LayoutSize(width: 100, height: 100))
        defer { host.detach() }
        host.contentRangePolicy = ContentRangePolicy(
            preloadDistance: 2,
            displayDistance: 0,
            preloadRetentionDistance: 2,
            displayRetentionDistance: 0
        )
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        let container = CALayer()
        renderer.render(page, in: container)
        #expect(renderer.contentDemand(for: image) == .preload)
        try await eventually { image.contentReadiness.data == .ready }
        #expect(image.decodedPixelSize == nil)
        page.scroll.contentOffset = LayoutPoint(x: 0, y: 160)
        renderer.renderScrolls([page.scroll])
        #expect(renderer.contentDemand(for: image).contains(.visible))
        try await eventually { image.decodedPixelSize != nil }
        host.layoutIfNeeded()
        renderer.render(page, in: container)
        #expect(renderer.layer(for: image)?.contents != nil)
        page.scroll.content = Node()
        host.layoutIfNeeded()
        renderer.render(page, in: container)
        #expect(image.decodedPixelSize == nil)
        #expect(renderer.contentDemand(for: image).isEmpty)
    }
    @Test @MainActor func demandDrivenImageFailureWaitsForRetryAndSourceReplacementResetsIt()
        async throws
    {
        let pipeline = ImagePipeline()
        let image = Image(
            source: .data(Data([0, 1, 2])),
            pipeline: pipeline,
            loadingMode: .demandDriven
        )
        image.contentDemandChanged(.display)
        try await eventually { image.contentReadiness.drawing == .failed }
        let attempts = await pipeline.decodedCacheState().decodes
        image.contentDemandChanged(.display)
        #expect(image.contentReadiness.drawing == .failed)
        #expect(await pipeline.decodedCacheState().decodes == attempts)
        image.retry()
        try await eventually { image.contentReadiness.drawing == .failed }
        #expect(await pipeline.decodedCacheState().decodes == attempts + 1)
        image.source = .data(try fixtureBytes())
        try await eventually { image.contentReadiness.drawing == .ready }
        #expect(image.phase == .ready)
        image.contentDemandChanged([])
    }
#endif
