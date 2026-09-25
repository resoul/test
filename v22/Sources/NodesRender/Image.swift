#if canImport(ImageIO)
    import Foundation
    import ImageIO
    import LayoutCore
    import Nodes
    import QuartzCore

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

    /// Loads and decodes static images. The disk cache holds encoded bytes; decoding happens
    /// away from the main actor. A small preview is followed by pixels matched to the frame.
    ///
    /// Ownership: the caller owns the pipeline and its cache. Isolation: actor. Errors: image,
    /// file, and network errors are thrown. Cancellation: the caller's task cancels loading.
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

        /// Ownership: the caller owns the pipeline. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            cache: ImageCache = ImageCache(),
            maximumDecodedPixelDimension: Int? = nil,
            previewPixelDimension: Int = 256
        ) {
            self.cache = cache
            self.maximumDecodedPixelDimension = maximumDecodedPixelDimension.map { max(1, $0) }
            self.previewPixelDimension = max(1, previewPixelDimension)
        }

        func load(_ source: ImageSource, targetPixelDimension: Int) async throws -> LoadedImage {
            let data: Data
            switch source {
            case let .data(value): data = value
            case let .url(url): data = try await cache.load(url)
            }
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

            let limit =
                maximumDecodedPixelDimension.map {
                    min(max(1, targetPixelDimension), $0)
                } ?? max(1, targetPixelDimension)
            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: limit,
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

    struct LoadedImage: Sendable {
        let image: CGImage
        let size: LayoutSize
    }

    /// A static image node. It decodes a preview, then pixels for its frame and display scale.
    /// An old result is discarded when the source, frame, or display scale changes.
    ///
    /// Ownership: the creator owns the node; the node owns its load task. Isolation:
    /// MainActor. Errors: a failed load leaves the node empty. Cancellation: replacing the
    /// source, requested pixel size, or releasing the node cancels the old load.
    @MainActor
    public final class Image: Node, LayerDrawing {
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: replaces load.
        public var source: ImageSource? {
            didSet { if source != oldValue { reload() } }
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
            .size(pixelSize ?? LayoutSize(width: 0, height: 0))
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var accessibilityContentTraits: AccessibilityTraits { .image }

        private let pipeline: ImagePipeline
        private var loaded: LoadedImage?
        private var loadTask: Task<Void, Never>?
        private var detailTask: Task<Void, Never>?
        private var sourceGeneration: UInt64 = 0
        private var detailGeneration: UInt64 = 0
        private var requestedPixelDimension: Int?
        private var revision: UInt64 = 0

        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: the load stops when the source changes or the node is released.
        public init(
            source: ImageSource? = nil,
            contentMode: ImageContentMode = .fit,
            pipeline: ImagePipeline = .shared
        ) {
            self.source = source
            self.contentMode = contentMode
            self.pipeline = pipeline
            super.init()
            reload()
        }

        deinit {
            loadTask?.cancel()
            detailTask?.cancel()
        }

        /// Requests only the pixels needed to cover the visible frame at the display scale.
        /// Fill and stretch can need more source pixels than fit because they crop or distort.
        ///
        /// Ownership: starts a task owned by the node. Isolation: MainActor. Errors: a failed
        /// refinement leaves the last decoded image visible. Cancellation: a new request
        /// cancels the old one.
        public func prepareDrawing(size: CGSize, scale: Double) {
            guard let source, let pixelSize,
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

        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func draw(in context: CGContext, size: CGSize) {
            guard let image = loaded?.image, size.width > 0, size.height > 0 else { return }
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
            setNeedsLayout()
            host?.setNeedsRender()
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
                    self.revision &+= 1
                    self.setNeedsLayout()
                    self.host?.setNeedsRender()
                } catch {
                    // The node stays empty. Replacing the source starts a new request.
                }
            }
        }
    }
#endif
