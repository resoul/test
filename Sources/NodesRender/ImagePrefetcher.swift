#if canImport(ImageIO)
    import Foundation

    /// Downloads images into the pipeline's disk cache before their nodes exist, so that an
    /// `Image` that shows one later finds the bytes on disk: fed from ``LazyStack/prefetch``
    /// and ``LazyStack/cancelPrefetch``.
    ///
    ///     stack.prefetch = { [prefetcher] posts in prefetcher.prefetch(posts.map(\.imageURL)) }
    ///     stack.cancelPrefetch = { [prefetcher] posts in prefetcher.cancel(posts.map(\.imageURL)) }
    ///
    /// A download runs at low priority and nothing is decoded: decoding depends on the size the
    /// node shows the image at, which is not known yet. Failures are dropped; the node tries
    /// again when it shows the image, and reports the failure then.
    ///
    /// Ownership: the prefetcher owns the downloads it started; the pipeline outlives it.
    /// Isolation: MainActor. Errors: none. Cancellation: ``cancel(_:)``, ``cancelAll()``, and
    /// releasing the prefetcher.
    @MainActor
    public final class ImagePrefetcher {
        /// The pipeline whose disk cache receives the images.
        public let pipeline: ImagePipeline

        private var downloads: [URL: Download] = [:]
        private var nextToken: UInt64 = 0

        private struct Download {
            let token: UInt64
            let task: Task<Void, Never>
        }

        /// Ownership: the prefetcher keeps the pipeline. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(pipeline: ImagePipeline = .shared) {
            self.pipeline = pipeline
        }

        deinit {
            for download in downloads.values { download.task.cancel() }
        }

        /// How many downloads are on their way.
        public var activeCount: Int { downloads.count }

        /// Starts downloading `urls` that are not on their way already. File URLs are skipped:
        /// they are on disk. An image the cache already holds fresh is answered at once and
        /// costs nothing.
        public func prefetch(_ urls: [URL]) {
            let cache = pipeline.cache
            for url in urls where !url.isFileURL && downloads[url] == nil {
                nextToken &+= 1
                let token = nextToken
                let task = Task(priority: .utility) { [weak self] in
                    _ = try? await cache.load(url)
                    self?.finished(url, token: token)
                }
                downloads[url] = Download(token: token, task: task)
            }
        }

        /// Stops the downloads of `urls` that are still on their way. A download that a node
        /// asked for as well goes on for the node.
        public func cancel(_ urls: [URL]) {
            for url in urls {
                downloads.removeValue(forKey: url)?.task.cancel()
            }
        }

        /// Stops every download on its way.
        public func cancelAll() {
            for download in downloads.values { download.task.cancel() }
            downloads = [:]
        }

        private func finished(_ url: URL, token: UInt64) {
            guard downloads[url]?.token == token else { return }

            downloads[url] = nil
        }
    }
#endif
