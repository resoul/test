#if canImport(ImageIO)
    import CryptoKit
    import Foundation
    import ImageIO

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

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(
            directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("image-cache", isDirectory: true),
            maximumBytes: Int = 256 * 1024 * 1024,
            maximumAge: TimeInterval = 7 * 24 * 60 * 60,
            metadata: ImageMetadataPolicy = .preserve,
            compression: ImageCompressionPolicy = .original,
            minimumCompressionBytes: Int = 1_000_000
        ) {
            self.directory = directory
            self.maximumBytes = maximumBytes
            self.maximumAge = maximumAge
            self.metadata = metadata
            self.compression = compression
            self.minimumCompressionBytes = minimumCompressionBytes
        }
    }

    /// A file cache for downloaded image data. Entries are keyed by URL and processing policy,
    /// expire after insertion, and are evicted by last use when the byte limit is reached.
    ///
    /// Ownership: the caller owns the cache and its directory. Isolation: actor. Errors:
    /// invalid images, file errors, and network errors are thrown. Cancellation: a cancelled
    /// load does not write an entry.
    public actor ImageCache {
        /// Ownership: value. Isolation: actor. Errors: none. Cancellation: not applicable.
        public let configuration: ImageCacheConfiguration

        /// Ownership: the caller owns the cache. Isolation: actor. Errors: none.
        /// Cancellation: not applicable.
        public init(configuration: ImageCacheConfiguration = ImageCacheConfiguration()) {
            self.configuration = configuration
        }

        /// Returns cached bytes, or downloads and stores them. File URLs are read directly.
        ///
        /// Ownership: returns data. Isolation: actor. Errors: network, image, and file errors.
        /// Cancellation: cancellation of the caller cancels the download before a disk write.
        public func load(_ url: URL) async throws -> Data {
            if url.isFileURL { return try Data(contentsOf: url) }
            if let cached = try cachedData(for: url) { return cached }

            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                (200...299).contains(response.statusCode)
            else { throw ImageCacheError.invalidResponse }

            try store(data, for: url)
            return try cachedData(for: url) ?? data
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

    /// Failure to read or store a usable image.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ImageCacheError: Error, Sendable {
        case invalidResponse
        case invalidImage
        case processingFailed
    }
#endif
