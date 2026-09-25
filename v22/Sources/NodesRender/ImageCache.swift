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

        /// Marks the files written under this cache's processing policies. Caches that share a
        /// directory count limits and ages only over files carrying their own mark.
        private let policyTag: String
        private var downloads: [URL: Download] = [:]
        private var nextID: UInt64 = 0
        /// Bytes of this cache's entries as last counted plus the writes since, or `nil`
        /// before the first count.
        private var storedBytes: Int?
        private var writesSinceCount = 0
        private var directoryScans = 0
        /// Grows with every removal of all entries; a download started before one does not
        /// write its result after it.
        private var removals: UInt64 = 0

        /// Ownership: the caller owns the cache and the session. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            configuration: ImageCacheConfiguration = ImageCacheConfiguration(),
            session: URLSession = .shared
        ) {
            self.configuration = configuration
            self.session = session
            let policies =
                "\(configuration.metadata.rawValue)|\(configuration.compression.rawValue)|\(configuration.minimumCompressionBytes)"
            policyTag = Self.hex(SHA256.hash(data: Data(policies.utf8))).prefix(8).description
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
                    task: Task { [removals] in
                        try await self.download(url, id: id, removalsAtStart: removals)
                    },
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

        /// What identifies the current bytes behind `url` without reading them: a file's size
        /// and dates, or those of the disk entry for a remote URL. `nil` when there is nothing
        /// to read or the entry has expired. Checking an entry counts as a use of it.
        func stamp(for url: URL) -> ImageFileStamp? {
            // File attributes are read fresh each time: `URL.resourceValues` caches them in
            // the URL, and a stale size or date would pass a replaced file for the old one.
            if url.isFileURL {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let size = (attributes[.size] as? NSNumber)?.intValue
                else { return nil }

                return ImageFileStamp(
                    size: size,
                    created: attributes[.creationDate] as? Date,
                    modified: attributes[.modificationDate] as? Date
                )
            }

            let file = fileURL(for: url)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                let size = (attributes[.size] as? NSNumber)?.intValue,
                let created = attributes[.creationDate] as? Date,
                Date().timeIntervalSince(created) <= max(configuration.maximumAge, 0)
            else { return nil }

            // Reading an entry marks it as recently used for eviction; so does finding it here.
            // Its modification date is that mark, so only the creation date, renewed when the
            // entry is rewritten, identifies the bytes.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: file.path
            )
            return ImageFileStamp(size: size, created: created, modified: nil)
        }

        /// Reads a disk entry without fetching its URL. An expired entry is deleted.
        ///
        /// Ownership: returns data. Isolation: actor. Errors: none thrown today; a missing or
        /// unreadable entry is a miss. Cancellation: none.
        public func cachedData(for url: URL) throws -> Data? {
            let file = fileURL(for: url)
            let manager = FileManager.default
            // Another cache sharing the directory can delete the entry at any moment, so a
            // missing file is a miss rather than an error.
            guard let attributes = try? manager.attributesOfItem(atPath: file.path) else {
                return nil
            }

            if let date = attributes[.creationDate] as? Date,
                Date().timeIntervalSince(date) > max(configuration.maximumAge, 0)
            {
                try? manager.removeItem(at: file)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                storedBytes = storedBytes.map { max(0, $0 - size) }
                return nil
            }

            guard let data = try? Data(contentsOf: file) else { return nil }

            try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
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
            let file = fileURL(for: url)
            let replaced =
                (try? manager.attributesOfItem(atPath: file.path))
                .flatMap { ($0[.size] as? NSNumber)?.intValue } ?? 0
            try prepared.write(to: file, options: .atomic)
            storedBytes = storedBytes.map { $0 + prepared.count - replaced }
            writesSinceCount += 1
            // The running total spares a directory scan on each write. It is recounted when
            // it passes the limit, and every 64 writes, since another cache or process sharing
            // the directory changes it unseen.
            if storedBytes.map({ $0 > configuration.maximumBytes }) ?? true
                || writesSinceCount >= 64
            {
                try removeExpired()
            }
        }

        /// Deletes every entry in the directory, whatever policies wrote it, as signing out
        /// needs; other files there are left alone. A download already running still returns its image but does not
        /// store it. Decoded images held by pipelines and nodes are not affected.
        ///
        /// Ownership: deletes files in the cache directory. Isolation: actor. Errors: file
        /// errors. Cancellation: none.
        public func removeAll() throws {
            removals &+= 1
            for entry in try entries() {
                try FileManager.default.removeItem(at: entry.url)
            }
            storedBytes = 0
            writesSinceCount = 0
        }

        /// Deletes the entry for `url` under this cache's policies. Entries written for the
        /// same URL under other policies stay.
        ///
        /// Ownership: deletes one file. Isolation: actor. Errors: file errors other than a
        /// missing entry. Cancellation: none.
        public func remove(for url: URL) throws {
            let file = fileURL(for: url)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            else { return }

            try FileManager.default.removeItem(at: file)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            storedBytes = storedBytes.map { max(0, $0 - size) }
        }

        /// Deletes this cache's expired entries, then its least recently used ones while their
        /// total is over `maximumBytes`. Entries of other policies in a shared directory are
        /// left to their caches; files of the earlier naming, which no cache counts, are
        /// deleted. Writes do this as needed; call it at launch to reclaim space from entries
        /// that are no longer read.
        ///
        /// Ownership: deletes files in the cache directory. Isolation: actor. Errors: file
        /// errors. Cancellation: none.
        public func removeExpired() throws {
            let manager = FileManager.default
            let now = Date()
            var kept: [Entry] = []
            for entry in try entries() {
                switch entry.naming {
                case .tagged(policyTag):
                    if now.timeIntervalSince(entry.created) > max(configuration.maximumAge, 0) {
                        try manager.removeItem(at: entry.url)
                    } else {
                        kept.append(entry)
                    }
                case .legacy:
                    // Counted by no cache, so it would otherwise stay forever.
                    try manager.removeItem(at: entry.url)
                case .tagged:
                    // Other policies' entries belong to the caches that use them.
                    break
                }
            }

            var total = kept.reduce(0) { $0 + $1.size }
            for entry in kept.sorted(by: { $0.used < $1.used })
            where total > configuration.maximumBytes {
                try manager.removeItem(at: entry.url)
                total -= entry.size
            }
            storedBytes = total
            writesSinceCount = 0
        }

        func directoryScanCount() -> Int { directoryScans }

        func downloadWaiters(for url: URL) -> Int {
            downloads[url]?.waiters.count ?? 0
        }

        /// `removalsAtStart` is taken when the download is created, not when its task first
        /// runs: a removal of all entries can reach the actor in between.
        private func download(
            _ url: URL,
            id: UInt64,
            removalsAtStart: UInt64
        ) async throws -> Data {
            // Later loads find the file on disk, or start over after a failure.
            defer { if downloads[url]?.id == id { downloads[url] = nil } }

            let (data, response) = try await fetch(url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                (200...299).contains(response.statusCode)
            else { throw ImageCacheError.invalidResponse }

            // After a removal of all entries, such as at sign-out, nothing fetched before it
            // is written back.
            guard removals == removalsAtStart else { return data }

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
            let digest = Self.hex(SHA256.hash(data: Data(url.absoluteString.utf8)))
            return configuration.directory.appendingPathComponent("\(policyTag)-\(digest)")
        }

        private static func hex(_ digest: some Sequence<UInt8>) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
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

        private struct Entry {
            let url: URL
            let naming: Naming
            let size: Int
            let created: Date
            let used: Date
        }

        /// The cache's own files in the directory: those named like an entry. Anything else
        /// placed there is neither counted nor deleted.
        private func entries() throws -> [Entry] {
            directoryScans += 1
            let manager = FileManager.default
            guard manager.fileExists(atPath: configuration.directory.path) else { return [] }

            let keys: [URLResourceKey] = [
                .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey,
            ]
            var result: [Entry] = []
            for file in try manager.contentsOfDirectory(
                at: configuration.directory,
                includingPropertiesForKeys: keys
            ) {
                guard let naming = Self.naming(of: file.lastPathComponent) else { continue }

                let values = try file.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }

                result.append(
                    Entry(
                        url: file,
                        naming: naming,
                        size: values.fileSize ?? 0,
                        created: values.creationDate ?? .distantPast,
                        used: values.contentModificationDate ?? .distantPast
                    )
                )
            }
            return result
        }

        /// How an entry's file is named: an 8-digit policy mark, a dash, and a 64-digit URL
        /// digest, all lowercase hexadecimal; or, from before the mark, the bare digest.
        private enum Naming: Equatable {
            case tagged(String)
            case legacy
        }

        /// `nil` for a file that is not an entry.
        private static func naming(of name: String) -> Naming? {
            func isHex(_ part: Substring) -> Bool {
                part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }

            if name.utf8.count == 64, isHex(name[...]) { return .legacy }

            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].utf8.count == 8, parts[1].utf8.count == 64,
                isHex(parts[0]), isHex(parts[1])
            else { return nil }

            return .tagged(String(parts[0]))
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

    /// A file's size and dates: changes whenever its bytes may have changed.
    struct ImageFileStamp: Hashable, Sendable {
        let size: Int
        let created: Date?
        let modified: Date?
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
