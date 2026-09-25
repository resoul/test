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
    /// away from the main actor, with a pixel limit independent of disk storage.
    ///
    /// Ownership: the caller owns the pipeline and its cache. Isolation: actor. Errors: image,
    /// file, and network errors are thrown. Cancellation: the caller's task cancels loading.
    public actor ImagePipeline {
        /// Ownership: shared actor. Isolation: actor. Errors: none. Cancellation: not applicable.
        public static let shared = ImagePipeline()

        /// Ownership: the pipeline owns the cache. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public let cache: ImageCache

        /// Maximum decoded width or height. The original encoded data stays intact in the
        /// disk cache; this limit only reduces memory used by display images.
        ///
        /// Ownership: value. Isolation: actor. Errors: none. Cancellation: not applicable.
        public let maximumDecodedPixelDimension: Int

        /// Ownership: the caller owns the pipeline. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            cache: ImageCache = ImageCache(),
            maximumDecodedPixelDimension: Int = 4096
        ) {
            self.cache = cache
            self.maximumDecodedPixelDimension = max(1, maximumDecodedPixelDimension)
        }

        func load(_ source: ImageSource) async throws -> LoadedImage {
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

            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: maximumDecodedPixelDimension,
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

    /// A static image node. Its encoded source is loaded once per change and the bitmap is
    /// redrawn at the size the layout gives it. A late result from an old source is discarded.
    ///
    /// Ownership: the creator owns the node; the node owns its load task. Isolation:
    /// MainActor. Errors: a failed load leaves the node empty. Cancellation: replacing the
    /// source or releasing the node cancels the old load.
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
                    host?.setNeedsRender()
                }
            }
        }

        /// The original oriented dimensions in pixels, or `nil` until loading succeeds.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public private(set) var pixelSize: LayoutSize?

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

        deinit { loadTask?.cancel() }

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
            loadTask?.cancel()
            loadTask = nil
            loaded = nil
            pixelSize = nil
            setNeedsLayout()
            host?.setNeedsRender()
            guard let source else { return }

            let request = revision
            let pipeline = pipeline
            loadTask = Task { [weak self] in
                do {
                    let result = try await pipeline.load(source)
                    guard !Task.isCancelled, let self, self.revision == request else { return }
                    self.loaded = result
                    self.pixelSize = result.size
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
