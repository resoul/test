#if canImport(ImageIO)
    import CryptoKit
    import Foundation
    import ImageIO
    import os

    /// Metadata kept when an image is written to the disk cache.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageMetadataPolicy: String, Sendable {
        case preserve
        case removeLocation
        case removeLocationAndXMP
    }

    /// How the disk cache stores image bytes. A lossless PNG rewrite is kept only when it is
    /// smaller than the input; other formats keep their encoded pixels unchanged.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageCompressionPolicy: String, Sendable {
        case original
        case losslessIfSmaller
    }

    /// Limits and file processing for one disk cache.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct ImageCacheConfiguration: Sendable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var directory: URL
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var maximumBytes: Int
        /// Time since insertion after which an entry expires.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var maximumAge: TimeInterval
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var metadata: ImageMetadataPolicy
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var compression: ImageCompressionPolicy
        /// Encoded size from which a lossless PNG rewrite is attempted.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var minimumCompressionBytes: Int
        /// Largest response body accepted from the network, or `nil` for no limit. A response
        /// that announces a larger size is abandoned at its headers; one that grows past the
        /// limit is abandoned as soon as it does.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var maximumDownloadBytes: Int?

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(
            directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("image-cache", isDirectory: true),
            maximumBytes: Int = 256 * 1024 * 1024,
            maximumAge: TimeInterval = 7 * 24 * 60 * 60,
            metadata: ImageMetadataPolicy = .preserve,
            compression: ImageCompressionPolicy = .original,
            minimumCompressionBytes: Int = 1_000_000,
            maximumDownloadBytes: Int? = nil
        ) {
            self.directory = directory
            self.maximumBytes = maximumBytes
            self.maximumAge = maximumAge
            self.metadata = metadata
            self.compression = compression
            self.minimumCompressionBytes = minimumCompressionBytes
            self.maximumDownloadBytes = maximumDownloadBytes
        }
    }

    /// A file cache for downloaded image data. Entries are keyed by URL and processing policy,
    /// expire after insertion, and are evicted by last use when the byte limit is reached.
    ///
    /// Ownership: the caller owns the cache and its directory. Isolation: actor. Errors:
    /// invalid images, file errors, and network errors are thrown. Cancellation: a download
    /// that every caller left does not write an entry.
    public actor ImageCache {
        /// Ownership: value. Isolation: actor. Errors: none. Cancellation: not applicable.
        public let configuration: ImageCacheConfiguration

        /// The session downloads go through: its configuration supplies headers, timeouts,
        /// and authentication.
        ///
        /// Ownership: the caller owns the session. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public let session: URLSession

        private struct Download {
            let id: UInt64
            let task: Task<Data, Error>
            var waiters: Set<UInt64>
        }

        private var downloads: [URL: Download] = [:]
        private var nextID: UInt64 = 0

        /// Ownership: the caller owns the cache and the session. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            configuration: ImageCacheConfiguration = ImageCacheConfiguration(),
            session: URLSession = .shared
        ) {
            self.configuration = configuration
            self.session = session
        }

        /// Returns cached bytes, or downloads and stores them. File URLs are read directly.
        /// Simultaneous loads of one URL share one download. An image whose format cannot take
        /// the metadata policy is returned uncached.
        ///
        /// Ownership: returns data. Isolation: actor. Errors: network, image, and file errors.
        /// Cancellation: a caller leaves a shared download; the last departing caller cancels
        /// it before a disk write.
        public func load(_ url: URL) async throws -> Data {
            if url.isFileURL { return try Data(contentsOf: url) }
            if let cached = try cachedData(for: url) { return cached }

            nextID &+= 1
            let waiter = nextID
            let download: Download
            if var existing = downloads[url] {
                existing.waiters.insert(waiter)
                downloads[url] = existing
                download = existing
            } else {
                let id = waiter
                download = Download(
                    id: id,
                    task: Task { try await self.download(url, id: id) },
                    waiters: [waiter]
                )
                downloads[url] = download
            }

            let id = download.id
            return try await withTaskCancellationHandler {
                let data = try await download.task.value
                try Task.checkCancellation()
                return data
            } onCancel: {
                Task { await self.leave(waiter, from: url, id: id) }
            }
        }

        /// Reads a disk entry without fetching its URL.
        ///
        /// Ownership: returns data. Isolation: actor. Errors: file errors. Cancellation: none.
        public func cachedData(for url: URL) throws -> Data? {
            let file = fileURL(for: url)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let date = attributes[.creationDate] as? Date,
                Date().timeIntervalSince(date) > max(configuration.maximumAge, 0)
            {
                try FileManager.default.removeItem(at: file)
                return nil
            }

            let data = try Data(contentsOf: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: file.path
            )
            return data
        }

        /// Stores a validated image under a URL after applying the configured policies.
        ///
        /// Ownership: writes to the cache directory. Isolation: actor. Errors: invalid image
        /// or file error. Cancellation: cancellation before the write leaves no new entry.
        public func store(_ data: Data, for url: URL) throws {
            let prepared = try prepare(data)
            try Task.checkCancellation()
            guard configuration.maximumBytes > 0,
                prepared.count <= configuration.maximumBytes
            else { return }

            let manager = FileManager.default
            try manager.createDirectory(
                at: configuration.directory,
                withIntermediateDirectories: true
            )
            try prepared.write(to: fileURL(for: url), options: .atomic)
            try evictIfNeeded()
        }

        func downloadWaiters(for url: URL) -> Int {
            downloads[url]?.waiters.count ?? 0
        }

        private func download(_ url: URL, id: UInt64) async throws -> Data {
            // Later loads find the file on disk, or start over after a failure.
            defer { if downloads[url]?.id == id { downloads[url] = nil } }

            let (data, response) = try await fetch(url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                (200...299).contains(response.statusCode)
            else { throw ImageCacheError.invalidResponse }

            do {
                try store(data, for: url)
            } catch ImageCacheError.processingFailed {
                // The metadata policy cannot be applied to this format: Image I/O reads WebP,
                // for one, but cannot write it. Storing the original would keep on disk what
                // the policy removes, so the image is shown but not cached.
                return data
            }
            return try cachedData(for: url) ?? data
        }

        private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
            guard let limit = configuration.maximumDownloadBytes else {
                return try await session.data(from: url)
            }

            let watch = DownloadLimit(bytes: max(0, limit))
            let result: (Data, URLResponse)
            do {
                result = try await session.data(from: url, delegate: watch)
            } catch {
                if watch.exceeded { throw ImageCacheError.responseTooLarge }
                throw error
            }
            guard result.0.count <= limit else { throw ImageCacheError.responseTooLarge }
            return result
        }

        private func leave(_ waiter: UInt64, from url: URL, id: UInt64) {
            guard var download = downloads[url], download.id == id else { return }
            download.waiters.remove(waiter)
            if download.waiters.isEmpty {
                download.task.cancel()
                downloads[url] = nil
            } else {
                downloads[url] = download
            }
        }

        private func fileURL(for url: URL) -> URL {
            let identity =
                "v1|\(configuration.metadata.rawValue)|\(configuration.compression.rawValue)|\(configuration.minimumCompressionBytes)|\(url.absoluteString)"
            let digest = SHA256.hash(data: Data(identity.utf8))
            let name = digest.map { String(format: "%02x", $0) }.joined()
            return configuration.directory.appendingPathComponent(name)
        }

        private func prepare(_ data: Data) throws -> Data {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceGetCount(source) > 0,
                let type = CGImageSourceGetType(source)
            else { throw ImageCacheError.invalidImage }

            var result = data
            if configuration.metadata != .preserve {
                let output = NSMutableData()
                guard
                    let destination = CGImageDestinationCreateWithData(
                        output,
                        type,
                        CGImageSourceGetCount(source),
                        nil
                    )
                else { throw ImageCacheError.processingFailed }
                var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
                if configuration.metadata == .removeLocationAndXMP {
                    options[kCGImageMetadataShouldExcludeXMP] = true
                }
                guard
                    CGImageDestinationCopyImageSource(
                        destination,
                        source,
                        options as CFDictionary,
                        nil
                    )
                else { throw ImageCacheError.processingFailed }
                result = output as Data
            }

            if configuration.compression == .losslessIfSmaller,
                result.count >= max(0, configuration.minimumCompressionBytes),
                type as String == "public.png",
                CGImageSourceGetCount(source) == 1,
                let preparedSource = CGImageSourceCreateWithData(result as CFData, nil),
                CGImageSourceCreateImageAtIndex(preparedSource, 0, nil) != nil
            {
                let output = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(output, type, 1, nil) {
                    CGImageDestinationAddImageFromSource(destination, preparedSource, 0, nil)
                    if CGImageDestinationFinalize(destination), output.length < result.count {
                        result = output as Data
                    }
                }
            }
            return result
        }

        private func evictIfNeeded() throws {
            let manager = FileManager.default
            let files = try manager.contentsOfDirectory(
                at: configuration.directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            var entries: [(url: URL, size: Int, date: Date)] = []
            var total = 0
            for file in files {
                let values = try file.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                ])
                let size = values.fileSize ?? 0
                total += size
                entries.append((file, size, values.contentModificationDate ?? .distantPast))
            }
            for entry in entries.sorted(by: { $0.date < $1.date })
            where total > configuration.maximumBytes {
                try manager.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }

    /// Cancels a download once its announced or received size passes the limit, so at most
    /// the limit and one network chunk are held in memory. The async `URLSession` calls do not
    /// forward data callbacks to a task delegate; only the task's creation, so the delegate
    /// watches the task's byte counters.
    private final class DownloadLimit: NSObject, URLSessionTaskDelegate {
        private let bytes: Int64
        private let state = OSAllocatedUnfairLock(
            initialState: (exceeded: false, observation: NSKeyValueObservation?.none)
        )

        init(bytes: Int) {
            self.bytes = Int64(bytes)
        }

        var exceeded: Bool { state.withLock { $0.exceeded } }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let limit = bytes
            let observation = task.observe(\.countOfBytesReceived, options: [.initial, .new]) {
                [weak self] task, _ in
                guard
                    task.countOfBytesReceived > limit || task.countOfBytesExpectedToReceive > limit
                else { return }

                self?.state.withLock { $0.exceeded = true }
                task.cancel()
            }
            state.withLock { $0.observation = observation }
        }
    }

    /// Failure to read or store a usable image.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageCacheError: Error, Sendable {
        /// The response body was larger than `maximumDownloadBytes`.
        case responseTooLarge
        case invalidResponse
        case invalidImage
        case processingFailed
    }
#endif
