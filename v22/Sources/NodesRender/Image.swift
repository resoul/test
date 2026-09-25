#if canImport(ImageIO)
    import CryptoKit
    import Foundation
    import ImageIO
    import LayoutCore
    import Nodes
    import QuartzCore
    import StateCore

    /// Where an image is read from. File URLs are read directly; remote URLs use the disk cache.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageSource: Sendable, Equatable {
        case data(Data)
        case url(URL)
    }

    /// How an image occupies its node's frame.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageContentMode: Sendable {
        case fit
        case fill
        case stretch
    }

    /// A solid fill shown until image pixels are available, or after the first load fails.
    /// An optional size measures the image before its original dimensions are known.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct ImagePlaceholder: Sendable, Equatable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var color: Color

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var size: LayoutSize?

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(
            color: Color = Color(red: 0.9, green: 0.9, blue: 0.9),
            size: LayoutSize? = nil
        ) {
            self.color = color
            self.size = size
        }
    }

    /// Progress of the first usable image. `ready` includes a preview while detail loads.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageLoadPhase: Sendable, Equatable {
        case empty
        case loading
        case ready
        case failed
    }

    /// Loads and decodes static images. The disk cache holds encoded bytes; decoding happens
    /// away from the main actor. Decoded sizes are shared within a bounded memory cache.
    ///
    /// Ownership: the caller owns the pipeline and its cache. Isolation: actor. Errors: image,
    /// file, and network errors are thrown. Cancellation: a caller leaves a shared decode;
    /// the last departing caller cancels it.
    public actor ImagePipeline {
        /// Ownership: shared actor. Isolation: actor. Errors: none. Cancellation: not applicable.
        public static let shared = ImagePipeline()

        /// Ownership: the pipeline owns the cache. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public let cache: ImageCache

        /// Optional ceiling for decoded width or height. `nil` lets the requested frame use
        /// the source's full resolution when needed. Disk bytes are never reduced by this.
        ///
        /// Ownership: value. Isolation: actor. Errors: none. Cancellation: not applicable.
        public let maximumDecodedPixelDimension: Int?

        /// Initial preview size, before the node knows how large it will be drawn.
        ///
        /// Ownership: value. Isolation: actor. Errors: none. Cancellation: not applicable.
        public let previewPixelDimension: Int

        /// Maximum estimated pixel bytes retained by the pipeline for decoded images.
        /// The estimate is `bytesPerRow * height`; zero disables reuse.
        /// Nodes and rendered layers can hold the same images beyond this cache's lifetime.
        ///
        /// Ownership: value. Isolation: actor. Errors: none. Cancellation: not applicable.
        public let maximumDecodedCacheBytes: Int

        private struct DecodedKey: Hashable, Sendable {
            let digest: Data
            let pixelDimension: Int
        }

        private struct DecodedEntry {
            let image: LoadedImage
            let bytes: Int
            var lastUse: UInt64
        }

        private struct InFlight {
            let id: UInt64
            let cacheGeneration: UInt64
            let task: Task<LoadedImage, Error>
            var waiters: Set<UInt64>
        }

        private let decodeGate = DecodeGate()
        private var decoded: [DecodedKey: DecodedEntry] = [:]
        private var inFlight: [DecodedKey: InFlight] = [:]
        private var decodedBytes = 0
        private var clock: UInt64 = 0
        private var nextFlightID: UInt64 = 0
        private var nextWaiterID: UInt64 = 0
        private var cacheGeneration: UInt64 = 0
        private var decodeCount = 0
        private var runningDecodes = 0
        private var peakRunningDecodes = 0
        private var digests: [URL: (stamp: ImageFileStamp, digest: Data)] = [:]
        private var sourceReads = 0

        /// Ownership: the caller owns the pipeline. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            cache: ImageCache = ImageCache(),
            maximumDecodedPixelDimension: Int? = nil,
            previewPixelDimension: Int = 256,
            maximumDecodedCacheBytes: Int = 64 * 1024 * 1024
        ) {
            self.cache = cache
            self.maximumDecodedPixelDimension = maximumDecodedPixelDimension.map { max(1, $0) }
            self.previewPixelDimension = max(1, previewPixelDimension)
            self.maximumDecodedCacheBytes = max(0, maximumDecodedCacheBytes)
        }

        func load(_ source: ImageSource, targetPixelDimension: Int) async throws -> LoadedImage {
            let limit =
                maximumDecodedPixelDimension.map {
                    min(max(1, targetPixelDimension), $0)
                } ?? max(1, targetPixelDimension)
            // A file whose size and dates are unchanged still holds the bytes last hashed, so
            // a decoded size is found without reading or hashing the file again.
            if case let .url(url) = source, let known = digests[url],
                await cache.stamp(for: url) == known.stamp,
                let image = reuse(DecodedKey(digest: known.digest, pixelDimension: limit))
            {
                return image
            }

            let data: Data
            var stamp: ImageFileStamp?
            switch source {
            case let .data(value):
                data = value
            case let .url(url):
                stamp = await cache.stamp(for: url)
                data = try await cache.load(url)
                sourceReads += 1
            }
            try Task.checkCancellation()

            // A URL can be overwritten without changing its spelling. Hash the bytes that
            // will actually be decoded so an old bitmap cannot stand in for new contents.
            let digest = Data(SHA256.hash(data: data))
            // The stamp is remembered only when the file did not change around the read, so
            // it always belongs to the bytes that were hashed.
            if case let .url(url) = source, let stamp, await cache.stamp(for: url) == stamp {
                digests[url] = (stamp, digest)
            }
            let key = DecodedKey(digest: digest, pixelDimension: limit)
            if let image = reuse(key) { return image }

            nextWaiterID &+= 1
            let waiterID = nextWaiterID
            let flight: InFlight
            if var existing = inFlight[key] {
                existing.waiters.insert(waiterID)
                inFlight[key] = existing
                flight = existing
            } else {
                nextFlightID &+= 1
                let id = nextFlightID
                // Decodes run one at a time so several simultaneous images do not create
                // several full-sized bitmaps at once. They wait in the gate rather than on
                // this actor, which stays free for cache hits and cancellations; a decode
                // cancelled while queued leaves the queue without running.
                let task = Task.detached(priority: Task.currentPriority) { [decodeGate] in
                    try await decodeGate.acquire()
                    await self.decodeStarted()
                    let result = Result { try Self.decode(data, pixelDimension: limit) }
                    await self.decodeFinished()
                    await decodeGate.release()
                    return try result.get()
                }
                flight = InFlight(
                    id: id,
                    cacheGeneration: cacheGeneration,
                    task: task,
                    waiters: [waiterID]
                )
                inFlight[key] = flight
                decodeCount &+= 1
            }

            let flightID = flight.id
            return try await withTaskCancellationHandler {
                do {
                    let image = try await flight.task.value
                    try Task.checkCancellation()
                    if inFlight[key]?.id == flightID {
                        inFlight[key] = nil
                        if flight.cacheGeneration == cacheGeneration {
                            retain(image, for: key)
                        }
                    }
                    return image
                } catch {
                    removeWaiter(waiterID, from: key, flightID: flightID)
                    throw error
                }
            } onCancel: {
                Task {
                    await self.removeWaiter(waiterID, from: key, flightID: flightID)
                }
            }
        }

        private func reuse(_ key: DecodedKey) -> LoadedImage? {
            guard var entry = decoded[key] else { return nil }

            clock &+= 1
            entry.lastUse = clock
            decoded[key] = entry
            return entry.image
        }

        /// Drops the pipeline's retained decoded images. Mounted nodes keep what they show.
        ///
        /// Ownership: releases the pipeline's references. Isolation: actor. Errors: none.
        /// Cancellation: in-flight decoding continues for its callers but does not refill
        /// the cache after this call.
        public func clearDecodedCache() {
            decoded.removeAll()
            digests.removeAll()
            decodedBytes = 0
            cacheGeneration &+= 1
        }

        func decodedCacheState() -> (
            entries: Int, bytes: Int, decodes: Int, peakRunning: Int, sourceReads: Int
        ) {
            (decoded.count, decodedBytes, decodeCount, peakRunningDecodes, sourceReads)
        }

        private func decodeStarted() {
            runningDecodes += 1
            peakRunningDecodes = max(peakRunningDecodes, runningDecodes)
        }

        private func decodeFinished() {
            runningDecodes -= 1
        }

        private func removeWaiter(_ id: UInt64, from key: DecodedKey, flightID: UInt64) {
            guard var flight = inFlight[key], flight.id == flightID else { return }
            flight.waiters.remove(id)
            if flight.waiters.isEmpty {
                flight.task.cancel()
                inFlight[key] = nil
            } else {
                inFlight[key] = flight
            }
        }

        private func retain(_ image: LoadedImage, for key: DecodedKey) {
            guard maximumDecodedCacheBytes > 0 else { return }
            let (bytes, overflow) = image.image.bytesPerRow.multipliedReportingOverflow(
                by: image.image.height
            )
            guard !overflow, bytes > 0, bytes <= maximumDecodedCacheBytes else { return }

            while decodedBytes > maximumDecodedCacheBytes - bytes,
                let oldest = decoded.min(by: { $0.value.lastUse < $1.value.lastUse })
            {
                decoded.removeValue(forKey: oldest.key)
                decodedBytes -= oldest.value.bytes
            }
            clock &+= 1
            decoded[key] = DecodedEntry(image: image, bytes: bytes, lastUse: clock)
            decodedBytes += bytes

            // Remembered digests are only useful for images still held; drop the rest once
            // they outnumber the held images, so a long feed does not grow the table forever.
            if digests.count > 2 * max(decoded.count, 64) {
                let held = Set(decoded.keys.map(\.digest))
                digests = digests.filter { held.contains($0.value.digest) }
            }
        }

        private nonisolated static func decode(
            _ data: Data,
            pixelDimension: Int
        ) throws -> LoadedImage {
            try Task.checkCancellation()
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceGetCount(imageSource) > 0
            else { throw ImageCacheError.invalidImage }

            let properties =
                CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
            let rawWidth =
                (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
            let rawHeight =
                (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
            let orientation =
                (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let swapsAxes = (5...8).contains(orientation)
            let width = swapsAxes ? rawHeight : rawWidth
            let height = swapsAxes ? rawWidth : rawHeight

            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: pixelDimension,
                kCGImageSourceShouldCacheImmediately as String: true,
            ]
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(
                    imageSource,
                    0,
                    options as CFDictionary
                )
            else { throw ImageCacheError.invalidImage }
            try Task.checkCancellation()
            return LoadedImage(
                image: image,
                size: LayoutSize(
                    width: Double(width > 0 ? width : image.width),
                    height: Double(height > 0 ? height : image.height)
                )
            )
        }
    }

    /// Lets one decode run at a time and queues the rest in arrival order. A queued caller
    /// that is cancelled leaves the queue and throws `CancellationError`.
    actor DecodeGate {
        private var isRunning = false
        private var waiting: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
        private var nextID: UInt64 = 0

        var waitingCount: Int { waiting.count }

        func acquire() async throws {
            try Task.checkCancellation()
            guard isRunning else {
                isRunning = true
                return
            }

            nextID &+= 1
            let id = nextID
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    enqueue(id, continuation)
                }
            } onCancel: {
                Task { await self.leave(id) }
            }
        }

        private func enqueue(_ id: UInt64, _ continuation: CheckedContinuation<Void, Error>) {
            // Cancellation that arrived before this point found nothing to remove.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiting.append((id, continuation))
            }
        }

        func release() {
            guard !waiting.isEmpty else {
                isRunning = false
                return
            }

            // The slot passes straight to the next caller, so nobody can overtake the queue.
            waiting.removeFirst().continuation.resume()
        }

        private func leave(_ id: UInt64) {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// An image's own size, keeping its proportions: as wide as its natural width when
    /// nothing limits it, and as tall as its proportions give for whatever width it gets.
    struct NaturalSizeMeasurer: ContentMeasurer {
        let size: LayoutSize

        func minContentWidth() -> Double { size.width }

        func maxContentWidth() -> Double { size.width }

        func height(forWidth width: Double) -> Double { width * size.height / size.width }
    }

    struct LoadedImage: Sendable {
        let image: CGImage
        let size: LayoutSize
    }

    /// A static image node. It decodes a preview, then pixels for its frame and display scale.
    /// An old result is discarded when the source, frame, or display scale changes.
    ///
    /// Ownership: the creator owns the node; the node owns its load task. Isolation:
    /// MainActor. Errors: a failed first load sets `phase` to `.failed` and keeps the
    /// placeholder visible. Cancellation: replacing the source, requested pixel size, or
    /// releasing the node cancels the old load.
    @MainActor
    public final class Image: Node, LayerDrawing {
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: replaces load.
        public var source: ImageSource? {
            didSet { if source != oldValue { reload() } }
        }

        /// Source pixels per point of the image's own size: 2 for an image made for a 2x
        /// display. It changes only how large the image measures, not which pixels are decoded
        /// — those follow the frame and the display scale. Values of zero or less count as 1.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var scale: Double {
            didSet { if scale != oldValue { setNeedsLayout() } }
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var contentMode: ImageContentMode {
            didSet {
                if contentMode != oldValue {
                    revision &+= 1
                    requestedPixelDimension = nil
                    detailTask?.cancel()
                    detailGeneration &+= 1
                    host?.setNeedsRender()
                }
            }
        }

        /// What is drawn before pixels arrive and if the first load fails. `nil` is clear.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var placeholder: ImagePlaceholder? {
            didSet {
                if placeholder != oldValue {
                    revision &+= 1
                    if placeholder?.size != oldValue?.size { setNeedsLayout() }
                    host?.setNeedsRender()
                }
            }
        }

        /// Observable loading state. Reading it in `update()` tracks changes. A preview
        /// counts as ready while detail is refined.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none.
        /// Cancellation: source replacement resets it to loading or empty.
        public var phase: ImageLoadPhase { phaseState.value }

        /// The original oriented dimensions in pixels, or `nil` until loading succeeds.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public private(set) var pixelSize: LayoutSize?

        /// Pixels currently decoded for display; may be a preview while a sharper image loads.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public private(set) var decodedPixelSize: LayoutSize?

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var drawingRevision: UInt64 { revision }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var layoutContent: LeafContent? {
            let pointScale = scale > 0 ? scale : 1
            let natural =
                pixelSize.map {
                    LayoutSize(width: $0.width / pointScale, height: $0.height / pointScale)
                } ?? placeholder?.size
            guard let natural, natural.width > 0, natural.height > 0 else {
                return .size(natural ?? .zero)
            }

            return .measured(NaturalSizeMeasurer(size: natural))
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var accessibilityContentTraits: AccessibilityTraits { .image }

        private let pipeline: ImagePipeline
        private let phaseState = State(ImageLoadPhase.empty)
        private var loaded: LoadedImage?
        private var loadTask: Task<Void, Never>?
        private var detailTask: Task<Void, Never>?
        private var sourceGeneration: UInt64 = 0
        private var detailGeneration: UInt64 = 0
        private var requestedPixelDimension: Int?
        private var revision: UInt64 = 0
        /// Set while the node is out of the tree after having been in it: nothing loads and
        /// no pixels are held until it returns.
        private var isSuspended = false
        private var solid: (color: Color?, image: CGImage)?

        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: the load stops when the source changes or the node is released.
        public init(
            source: ImageSource? = nil,
            scale: Double = 1,
            contentMode: ImageContentMode = .fit,
            placeholder: ImagePlaceholder? = nil,
            pipeline: ImagePipeline = .shared
        ) {
            self.source = source
            self.scale = scale
            self.contentMode = contentMode
            self.placeholder = placeholder
            self.pipeline = pipeline
            super.init()
            reload()
        }

        deinit {
            loadTask?.cancel()
            detailTask?.cancel()
        }

        /// Leaving the tree cancels loading and lets go of the decoded pixels; the original
        /// size stays, so the layout does not jump when the node returns. Returning resumes an
        /// unfinished first load; the renderer then asks for pixels for the frame, which the
        /// pipeline's memory cache often still holds.
        ///
        /// Ownership: cancels or starts node-owned tasks. Isolation: MainActor. Errors: none.
        /// Cancellation: leaving cancels both loads.
        public override func mountedChanged(_ isMounted: Bool) {
            if isMounted {
                guard isSuspended else { return }

                isSuspended = false
                if source != nil, pixelSize == nil, phaseState.value == .loading {
                    startFirstLoad()
                }
                host?.setNeedsRender()
            } else {
                isSuspended = true
                loadTask?.cancel()
                detailTask?.cancel()
                loadTask = nil
                detailTask = nil
                detailGeneration &+= 1
                requestedPixelDimension = nil
                loaded = nil
                decodedPixelSize = nil
                revision &+= 1
            }
        }

        /// Tries the current source again after an initial failure or a changed resource.
        ///
        /// Ownership: starts a node-owned task. Isolation: MainActor. Errors: none.
        /// Cancellation: replaces the previous load and its detail request.
        public func retry() {
            guard source != nil else { return }
            reload()
        }

        /// Requests only the pixels needed to cover the visible frame at the display scale.
        /// Fill and stretch can need more source pixels than fit because they crop or distort.
        ///
        /// Ownership: starts a task owned by the node. Isolation: MainActor. Errors: a failed
        /// refinement leaves the last decoded image visible. Cancellation: a new request
        /// cancels the old one.
        public func prepareDrawing(size: CGSize, scale: Double) {
            guard !isSuspended, let source, let pixelSize,
                size.width > 0, size.height > 0, scale > 0,
                pixelSize.width > 0, pixelSize.height > 0
            else { return }

            let pixelWidth = Double(size.width) * scale
            let pixelHeight = Double(size.height) * scale
            guard pixelWidth.isFinite, pixelHeight.isFinite else { return }
            let horizontal = pixelWidth / pixelSize.width
            let vertical = pixelHeight / pixelSize.height
            let factor = contentMode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
            let sourceMaximum = max(pixelSize.width, pixelSize.height)
            let wanted = Int(min(sourceMaximum, max(1, (sourceMaximum * factor).rounded(.up))))
            guard requestedPixelDimension != wanted else { return }

            requestedPixelDimension = wanted
            detailTask?.cancel()
            detailGeneration &+= 1
            let request = detailGeneration
            let generation = sourceGeneration
            let pipeline = pipeline
            detailTask = Task { [weak self] in
                do {
                    let result = try await pipeline.load(source, targetPixelDimension: wanted)
                    guard !Task.isCancelled, let self, self.sourceGeneration == generation,
                        self.detailGeneration == request
                    else { return }
                    self.loaded = result
                    self.decodedPixelSize = LayoutSize(
                        width: Double(result.image.width),
                        height: Double(result.image.height)
                    )
                    self.revision &+= 1
                    self.host?.setNeedsRender()
                } catch {
                    // The preview or preceding detail remains visible until another size asks.
                }
            }
        }

        /// The decoded pixels, or before them a single pixel of the placeholder's color (clear
        /// without one) stretched over the frame. The layer shows them as they are, so no
        /// frame-sized copy of the image or the fill is made.
        ///
        /// Ownership: returns references the node holds. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public var layerImage: LayerImage? {
            if let image = loaded?.image {
                return LayerImage(image: image, contentMode: contentMode)
            }

            return solidImage().map { LayerImage(image: $0, contentMode: .stretch) }
        }

        /// Draws what `layerImage` shows, for a caller that needs it in a context.
        ///
        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func draw(in context: CGContext, size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            guard let image = loaded?.image else {
                if let placeholder {
                    context.setFillColor(
                        red: placeholder.color.red,
                        green: placeholder.color.green,
                        blue: placeholder.color.blue,
                        alpha: placeholder.color.alpha
                    )
                    context.fill(CGRect(origin: .zero, size: size))
                }
                return
            }
            let imageWidth = CGFloat(image.width)
            let imageHeight = CGFloat(image.height)
            let box = CGRect(origin: .zero, size: size)
            let destination: CGRect
            switch contentMode {
            case .stretch:
                destination = box
            case .fit, .fill:
                let horizontal = size.width / imageWidth
                let vertical = size.height / imageHeight
                let factor =
                    contentMode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
                let width = imageWidth * factor
                let height = imageHeight * factor
                destination = CGRect(
                    x: (size.width - width) / 2,
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
            }
            context.clip(to: box)
            context.draw(image, in: destination)
        }

        /// A single pixel of the placeholder's color, kept until the color changes: the
        /// renderer compares contents by reference, and a new pixel each render would replace
        /// them every time.
        private func solidImage() -> CGImage? {
            let color = placeholder?.color
            if let solid, solid.color == color { return solid.image }

            guard
                let context = CGContext(
                    data: nil,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            else { return nil }

            if let color {
                context.setFillColor(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: color.alpha
                )
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            guard let image = context.makeImage() else { return nil }

            solid = (color, image)
            return image
        }

        private func reload() {
            revision &+= 1
            sourceGeneration &+= 1
            detailGeneration &+= 1
            loadTask?.cancel()
            detailTask?.cancel()
            loadTask = nil
            detailTask = nil
            requestedPixelDimension = nil
            loaded = nil
            pixelSize = nil
            decodedPixelSize = nil
            phaseState.value = source == nil ? .empty : .loading
            setNeedsLayout()
            host?.setNeedsRender()
            guard !isSuspended else { return }

            startFirstLoad()
        }

        private func startFirstLoad() {
            guard let source else { return }

            let request = sourceGeneration
            let pipeline = pipeline
            loadTask = Task { [weak self] in
                do {
                    let result = try await pipeline.load(
                        source,
                        targetPixelDimension: pipeline.previewPixelDimension
                    )
                    guard !Task.isCancelled, let self, self.sourceGeneration == request else {
                        return
                    }
                    self.loaded = result
                    self.pixelSize = result.size
                    self.decodedPixelSize = LayoutSize(
                        width: Double(result.image.width),
                        height: Double(result.image.height)
                    )
                    self.phaseState.value = .ready
                    self.revision &+= 1
                    self.setNeedsLayout()
                    self.host?.setNeedsRender()
                } catch {
                    guard !Task.isCancelled, let self, self.sourceGeneration == request else {
                        return
                    }
                    self.phaseState.value = .failed
                    self.revision &+= 1
                    self.host?.setNeedsRender()
                }
            }
        }
    }
#endif
