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
        /// Time since insertion after which an entry expires and is deleted, whatever the
        /// server said. Within it, an entry the server gave a shorter freshness
        /// (`Cache-Control: max-age`, `no-cache`, `Expires`) is checked with the server once
        /// that passes — with its `ETag` or `Last-Modified`, so an unchanged image is not
        /// downloaded again; an entry without them is downloaded again. An entry the server
        /// said nothing about stays fresh for all of it.
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
            let urgency: SharedUrgency
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
            try await load(url, urgency: nil)
        }

        /// The entry's bytes when the server's freshness for them has not run out; `nil` for
        /// a missing, expired, or stale entry. A stale entry stays for a check with the
        /// server.
        private func freshData(for url: URL) throws -> Data? {
            let file = fileURL(for: url)
            if let freshUntil = HTTPValidators.read(at: file)?.freshUntil, Date() >= freshUntil {
                return nil
            }
            return try cachedData(for: url)
        }

        /// `load(_:)` for a caller whose `urgency` sets the priority of the download while it
        /// runs: high while the caller's node is on screen, low otherwise. A shared download
        /// is as urgent as the most urgent of its callers.
        func load(_ url: URL, urgency: LoadUrgency?) async throws -> Data {
            if url.isFileURL { return try Data(contentsOf: url) }
            if let cached = try freshData(for: url) { return cached }

            nextID &+= 1
            let waiter = nextID
            let download: Download
            if var existing = downloads[url] {
                existing.waiters.insert(waiter)
                existing.urgency.add(urgency, for: waiter)
                downloads[url] = existing
                download = existing
            } else {
                let id = waiter
                let shared = SharedUrgency()
                shared.add(urgency, for: waiter)
                download = Download(
                    id: id,
                    task: Task { [removals] in
                        try await self.download(
                            url,
                            id: id,
                            urgency: shared,
                            removalsAtStart: removals
                        )
                    },
                    urgency: shared,
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
            // A stale entry is to be checked with the server before its bytes are used again.
            if let freshUntil = HTTPValidators.read(at: file)?.freshUntil, Date() >= freshUntil {
                return nil
            }

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
            urgency: SharedUrgency,
            removalsAtStart: UInt64
        ) async throws -> Data {
            // Later loads find the file on disk, or start over after a failure.
            defer { if downloads[url]?.id == id { downloads[url] = nil } }

            let file = fileURL(for: url)
            // A stale entry with validators is checked with the server rather than fetched.
            let stored = HTTPValidators.read(at: file).flatMap { $0.canRevalidate ? $0 : nil }
            let (data, response) = try await fetch(url, urgency: urgency, validators: stored)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw ImageCacheError.invalidResponse
            }

            let now = Date()
            if response.statusCode == 304, let stored {
                // Unchanged: the entry is fresh again for as long as the new answer says.
                guard let cached = try cachedData(for: url) else {
                    // The entry went meanwhile (another cache sharing the directory, its age):
                    // there is nothing to keep, so the image is fetched whole.
                    return try await download(
                        url,
                        id: id,
                        urgency: urgency,
                        removalsAtStart: removalsAtStart
                    )
                }
                HTTPValidators(response: response, now: now, keeping: stored).write(at: file)
                return cached
            }
            guard (200...299).contains(response.statusCode) else {
                throw ImageCacheError.invalidResponse
            }

            // After a removal of all entries, such as at sign-out, nothing fetched before it
            // is written back; nor is what the server asks not to store, whose older copy goes.
            guard removals == removalsAtStart else { return data }
            if HTTPValidators.forbidsStoring(response) {
                try? remove(for: url)
                return data
            }

            do {
                try store(data, for: url)
            } catch ImageCacheError.processingFailed {
                // The metadata policy cannot be applied to this format: Image I/O reads WebP,
                // for one, but cannot write it. Storing the original would keep on disk what
                // the policy removes, so the image is shown but not cached.
                return data
            }
            HTTPValidators(response: response, now: now, keeping: nil).write(at: file)
            return try cachedData(for: url) ?? data
        }

        private func fetch(
            _ url: URL,
            urgency: SharedUrgency,
            validators: HTTPValidators?
        ) async throws -> (Data, URLResponse) {
            let limit = configuration.maximumDownloadBytes.map { max(0, $0) }
            let watch = DownloadWatch(bytes: limit, urgency: urgency)
            // The disk entries are the cache: the session's own is neither asked nor needed.
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            if let validators {
                if let etag = validators.etag {
                    request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
                if let lastModified = validators.lastModified {
                    request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
                }
            }
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request, delegate: watch)
            } catch {
                if watch.exceeded { throw ImageCacheError.responseTooLarge }
                throw error
            }
            if let limit, result.0.count > limit { throw ImageCacheError.responseTooLarge }
            return result
        }

        private func leave(_ waiter: UInt64, from url: URL, id: UInt64) {
            guard var download = downloads[url], download.id == id else { return }
            download.waiters.remove(waiter)
            download.urgency.remove(waiter)
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
                // Without metadata to write, Image I/O replaces the source's with none —
                // orientation included, turning camera photos on their side. So the source's
                // metadata is passed on, and the GPS flag drops the coordinates from it.
                var options: [CFString: Any] = [
                    kCGImageMetadataShouldExcludeGPS: true,
                    kCGImageDestinationMergeMetadata: false,
                ]
                if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                    options[kCGImageDestinationMetadata] =
                        configuration.metadata == .removeLocationAndXMP
                        ? Self.exifAndTIFF(of: metadata) : metadata
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

        /// The tags stored as EXIF or TIFF — orientation among them — without XMP-only ones
        /// or IPTC. With these as the whole metadata, the rest is not written: the XMP
        /// exclusion flag has no effect once metadata is passed explicitly.
        private static func exifAndTIFF(of metadata: CGImageMetadata) -> CGImageMetadata {
            let kept: Set<String> = [
                kCGImageMetadataNamespaceExif as String,
                kCGImageMetadataNamespaceExifAux as String,
                kCGImageMetadataNamespaceExifEX as String,
                kCGImageMetadataNamespaceTIFF as String,
            ]
            let result = CGImageMetadataCreateMutable()
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
                if let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                    kept.contains(namespace)
                {
                    CGImageMetadataSetTagWithPath(result, nil, path, tag)
                }
                return true
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

    /// Watches one download's task: gives it the priority of its callers' urgency, again at
    /// each change, and — with a limit — cancels it once its announced or received size passes
    /// the limit, so at most the limit and one network chunk are held in memory. The async
    /// `URLSession` calls do not forward data callbacks to a task delegate; only the task's
    /// creation, so the delegate watches the task's byte counters.
    private final class DownloadWatch: NSObject, URLSessionTaskDelegate {
        private let bytes: Int64?
        private let urgency: SharedUrgency
        private let state = OSAllocatedUnfairLock(
            initialState: (exceeded: false, observation: NSKeyValueObservation?.none)
        )

        init(bytes: Int?, urgency: SharedUrgency) {
            self.bytes = bytes.map(Int64.init)
            self.urgency = urgency
        }

        var exceeded: Bool { state.withLock { $0.exceeded } }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let urgency = urgency
            let prioritize: @Sendable () -> Void = { [weak task] in
                task?.priority =
                    urgency.isUrgent ? URLSessionTask.highPriority : URLSessionTask.lowPriority
            }
            prioritize()
            urgency.watch(prioritize)

            guard let limit = bytes else { return }

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

    /// What the server said about a stored response: its validators, and until when it may be
    /// used without asking again. Kept in an extended attribute of the entry's file, so the
    /// directory holds nothing but entries; a rewritten file starts without one.
    struct HTTPValidators: Codable, Sendable, Equatable {
        var etag: String?
        var lastModified: String?
        /// `nil`: fresh for as long as the cache keeps the entry.
        var freshUntil: Date?

        /// The attribute's name; like the entries' names, it says what it holds.
        private static let attribute = "image-cache.http"

        var canRevalidate: Bool { etag != nil || lastModified != nil }

        /// From a response received at `now`; a 304 answer keeps the validators it does not
        /// repeat.
        init(response: HTTPURLResponse, now: Date, keeping stored: HTTPValidators?) {
            etag = response.value(forHTTPHeaderField: "ETag") ?? stored?.etag
            lastModified =
                response.value(forHTTPHeaderField: "Last-Modified") ?? stored?.lastModified
            freshUntil = HTTPValidators.freshUntil(response, now: now)
        }

        /// `Cache-Control: no-store`: the response must not be written anywhere.
        static func forbidsStoring(_ response: HTTPURLResponse) -> Bool {
            directives(response).keys.contains("no-store")
        }

        /// RFC 9111 §4.2.1: `no-cache` is stale at once; `max-age` counts from the response
        /// minus its `Age`; else `Expires`. Without any of them, `nil`.
        private static func freshUntil(_ response: HTTPURLResponse, now: Date) -> Date? {
            let directives = directives(response)
            if directives.keys.contains("no-cache") { return now }
            if let value = directives["max-age"], let seconds = value.flatMap(Double.init) {
                let age = response.value(forHTTPHeaderField: "Age").flatMap(Double.init) ?? 0
                return now.addingTimeInterval(max(0, seconds - max(0, age)))
            }
            if let expires = response.value(forHTTPHeaderField: "Expires") {
                // An invalid date means already expired (RFC 9111 §5.3).
                return httpDate(expires) ?? now
            }
            return nil
        }

        /// `Cache-Control` directives by lowercased name, with their values.
        private static func directives(_ response: HTTPURLResponse) -> [String: String?] {
            guard let header = response.value(forHTTPHeaderField: "Cache-Control") else {
                return [:]
            }

            var directives: [String: String?] = [:]
            for part in header.split(separator: ",") {
                let pair = part.split(separator: "=", maxSplits: 1)
                guard let name = pair.first?.trimmingCharacters(in: .whitespaces).lowercased(),
                    !name.isEmpty
                else { continue }

                directives[name] =
                    pair.count > 1
                    ? pair[1].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    : String?.none
            }
            return directives
        }

        /// An HTTP date in its preferred form, `Sun, 06 Nov 1994 08:49:37 GMT`.
        private static func httpDate(_ text: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: text)
        }

        static func read(at file: URL) -> HTTPValidators? {
            let size = getxattr(file.path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }

            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes {
                getxattr(file.path, attribute, $0.baseAddress, size, 0, 0)
            }
            guard read == size else { return nil }

            return try? JSONDecoder().decode(HTTPValidators.self, from: data)
        }

        /// Writes the attribute, or removes it when there is nothing to keep.
        func write(at file: URL) {
            guard etag != nil || lastModified != nil || freshUntil != nil,
                let data = try? JSONEncoder().encode(self)
            else {
                removexattr(file.path, HTTPValidators.attribute, 0)
                return
            }

            _ = data.withUnsafeBytes {
                setxattr(file.path, HTTPValidators.attribute, $0.baseAddress, data.count, 0, 0)
            }
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
