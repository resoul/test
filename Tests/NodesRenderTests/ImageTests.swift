#if canImport(ImageIO)
    import ImageIO
    import LayoutCore
    import Nodes
    import os
    @testable import NodesRender
    import QuartzCore
    import Testing

    private func encodedImage(
        width: Int,
        height: Int,
        type: CFString = "public.png" as CFString,
        metadata: [String: Any] = [:]
    ) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bitmap = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Encodes pixels in four quarters — red at the top left, blue at the top right, green at
    /// the bottom left, white at the bottom right — tagged with an EXIF orientation, as a
    /// camera writes a JPEG it did not rotate. Where the red and blue corners show tells every
    /// orientation apart, mirrored and transposed ones too.
    private func quartersJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        let halfWidth = width / 2
        let halfHeight = height / 2
        // Core Graphics counts y upward: the top quarters are the upper half.
        let quarters: [(CGRect, CGColor)] = [
            (
                CGRect(x: 0, y: halfHeight, width: halfWidth, height: height - halfHeight),
                CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            ),
            (
                CGRect(
                    x: halfWidth,
                    y: halfHeight,
                    width: width - halfWidth,
                    height: height - halfHeight
                ),
                CGColor(red: 0, green: 0, blue: 1, alpha: 1)
            ),
            (
                CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight),
                CGColor(red: 0, green: 1, blue: 0, alpha: 1)
            ),
            (
                CGRect(x: halfWidth, y: 0, width: width - halfWidth, height: halfHeight),
                CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ),
        ]
        for (rect, color) in quarters {
            context.setFillColor(color)
            context.fill(rect)
        }
        let bitmap = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: orientation,
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
        ]
        CGImageDestinationAddImage(destination, bitmap, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test
    func diskCacheKeepsTheOriginalByDefaultAndEvictsOldEntries() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try encodedImage(width: 20, height: 20)
        let second = try encodedImage(width: 30, height: 30)
        let limit = max(first.count, second.count)
        let cache = ImageCache(
            configuration: ImageCacheConfiguration(
                directory: directory,
                maximumBytes: limit
            )
        )
        let firstURL = URL(string: "https://example.test/first.png")!
        let secondURL = URL(string: "https://example.test/second.png")!
        try await cache.store(first, for: firstURL)
        #expect(try await cache.cachedData(for: firstURL) == first)

        try await cache.store(second, for: secondURL)
        #expect(try await cache.cachedData(for: firstURL) == nil)
        #expect(try await cache.cachedData(for: secondURL) == second)
    }

    @Test
    func evictionAndRemovalLeaveOtherFilesInTheDirectory() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try encodedImage(width: 20, height: 20)
        let cache = ImageCache(
            configuration: ImageCacheConfiguration(
                directory: directory,
                maximumBytes: image.count
            )
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data(repeating: 1, count: image.count * 4).write(to: notes)

        let first = URL(string: "https://example.test/first.png")!
        let second = URL(string: "https://example.test/second.png")!
        try await cache.store(image, for: first)
        try await cache.store(image, for: second)
        #expect(try await cache.cachedData(for: first) == nil)
        #expect(try await cache.cachedData(for: second) == image)

        try await cache.removeAll()
        #expect(try await cache.cachedData(for: second) == nil)
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    @Test
    func cachesSharingADirectoryKeepTheirOwnLimits() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try encodedImage(width: 20, height: 20)
        let small = ImageCache(
            configuration: ImageCacheConfiguration(directory: directory, maximumBytes: image.count)
        )
        let large = ImageCache(
            configuration: ImageCacheConfiguration(directory: directory, metadata: .removeLocation)
        )
        let sameAsSmall = ImageCache(configuration: ImageCacheConfiguration(directory: directory))
        let urls = (0..<3).map { URL(string: "https://example.test/\($0).png")! }
        for url in urls { try await large.store(image, for: url) }
        let largeStored = try #require(await large.cachedData(for: urls[0]))

        try await small.store(image, for: urls[0])
        try await small.store(image, for: urls[1])
        try await small.removeExpired()
        #expect(try await small.cachedData(for: urls[0]) == nil)
        #expect(try await small.cachedData(for: urls[1]) == image)
        #expect(try await sameAsSmall.cachedData(for: urls[1]) == image)
        for url in urls {
            #expect(try await large.cachedData(for: url) == largeStored)
        }

        try await small.removeAll()
        #expect(try await large.cachedData(for: urls[2]) == nil)
    }

    @Test
    func filesOfTheEarlierNamingAreRemovedOnRecount() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent(String(repeating: "ab", count: 32))
        try Data([1, 2, 3]).write(to: legacy)
        let cache = ImageCache(configuration: ImageCacheConfiguration(directory: directory))
        try await cache.removeExpired()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test
    func removingOneURLKeepsTheOthers() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try encodedImage(width: 8, height: 8)
        let cache = ImageCache(configuration: ImageCacheConfiguration(directory: directory))
        let kept = URL(string: "https://example.test/kept.png")!
        let removed = URL(string: "https://example.test/removed.png")!
        try await cache.store(image, for: kept)
        try await cache.store(image, for: removed)
        try await cache.remove(for: removed)
        try await cache.remove(for: removed)
        #expect(try await cache.cachedData(for: removed) == nil)
        #expect(try await cache.cachedData(for: kept) == image)
    }

    @Test
    func expiredEntriesAreRemovedWithoutBeingRead() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try encodedImage(width: 8, height: 8)
        let cache = ImageCache(
            configuration: ImageCacheConfiguration(directory: directory, maximumAge: 0.2)
        )
        try await cache.store(image, for: URL(string: "https://example.test/old.png")!)
        try await Task.sleep(for: .milliseconds(300))
        let fresh = URL(string: "https://example.test/fresh.png")!
        try await cache.store(image, for: fresh)

        try await cache.removeExpired()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1)
        #expect(try await cache.cachedData(for: fresh) == image)
    }

    @Test
    func writesDoNotScanTheDirectoryEachTime() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try encodedImage(width: 8, height: 8)
        let cache = ImageCache(
            configuration: ImageCacheConfiguration(
                directory: directory,
                maximumBytes: image.count * 10
            )
        )
        for index in 0..<10 {
            try await cache.store(image, for: URL(string: "https://example.test/\(index).png")!)
        }
        #expect(await cache.directoryScanCount() == 1)

        // Past the limit the running total asks for a recount, which evicts.
        try await cache.store(image, for: URL(string: "https://example.test/10.png")!)
        #expect(await cache.directoryScanCount() == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 10)
    }

    @Test
    func downloadFinishingAfterRemoveAllIsNotStored() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/sign-out-slow.webp")!
        let loading = Task { try await cache.load(url) }
        while await cache.downloadWaiters(for: url) < 1 { await Task.yield() }

        try await cache.removeAll()
        #expect(try await loading.value == webP)
        #expect(try await cache.cachedData(for: url) == nil)
    }

    /// A camera-like JPEG: pixels stored turned (EXIF orientation 6), full GPS coordinates,
    /// a capture date, and XMP with a headline and a city.
    private func cameraJPEG() throws -> Data {
        let pixels = try #require(
            CGImageSourceCreateWithData(try encodedImage(width: 12, height: 8) as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        )
        let xmp = try #require(CGImageMetadataCreateMutable())
        for (path, value) in [("photoshop:Headline", "Bridge"), ("photoshop:City", "Kyiv")] {
            #expect(CGImageMetadataSetValueWithPath(xmp, nil, path as CFString, value as CFString))
        }
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 50.45, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 30.52, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:25 10:00:00"
            ],
        ]
        CGImageDestinationAddImageAndMetadata(destination, pixels, xmp, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// What of `cameraJPEG()`'s metadata some encoded bytes still carry.
    struct Kept: Equatable, Sendable {
        var orientation: Int?
        var gps: Bool
        var date: Bool
        var headline: Bool
        var city: Bool
    }

    private func kept(_ data: Data) throws -> Kept {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        func has(_ path: String) -> Bool {
            metadata.flatMap { CGImageMetadataCopyTagWithPath($0, nil, path as CFString) } != nil
        }
        let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return Kept(
            orientation: (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?
                .intValue,
            gps: properties?[kCGImagePropertyGPSDictionary as String] != nil
                || has("exif:GPSLatitude"),
            date: exif?[kCGImagePropertyExifDateTimeOriginal as String] != nil,
            headline: has("photoshop:Headline"),
            city: has("photoshop:City")
        )
    }

    @Test(
        arguments: [
            (
                ImageMetadataPolicy.removeLocation,
                Kept(orientation: 6, gps: false, date: true, headline: true, city: true)
            ),
            (
                ImageMetadataPolicy.removeLocationAndXMP,
                Kept(orientation: 6, gps: false, date: false, headline: false, city: false)
            ),
        ]
    )
    func metadataPoliciesKeepOrientationAndPixels(
        policy: ImageMetadataPolicy,
        expected: Kept
    ) async throws {
        let original = try cameraJPEG()
        #expect(
            try kept(original)
                == Kept(orientation: 6, gps: true, date: true, headline: true, city: true)
        )

        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(
            configuration: ImageCacheConfiguration(directory: directory, metadata: policy)
        )
        let url = URL(string: "https://example.test/camera.jpg")!
        try await cache.store(original, for: url)
        let saved = try #require(await cache.cachedData(for: url))
        #expect(try kept(saved) == expected)

        let before = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let after = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
        let sourcePixels = try #require(CGImageSourceCreateImageAtIndex(before, 0, nil))
        let savedPixels = try #require(CGImageSourceCreateImageAtIndex(after, 0, nil))
        #expect(sourcePixels.dataProvider?.data as Data? == savedPixels.dataProvider?.data as Data?)
        // Shown turned upright, as the original would be.
        let shown = try await ImagePipeline().load(.data(saved), targetPixelDimension: 64)
        #expect(shown.size == LayoutSize(width: 8, height: 12))
    }

    /// A lossless 1×1 WebP. Image I/O decodes WebP but cannot encode it.
    private let webP = Data(
        base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="
    )!

    /// Requests the stub server has answered, by URL path.
    private let stubRequests = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// Conditional requests the stub server has answered with 304, by URL path.
    private let stubRevalidations = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// The response headers of paths containing `http-`: `etag` and `lastmod` give validators,
    /// `fresh` `max-age=3600`, `stale` `no-cache`, `nostore` `no-store`, `aged` `max-age=3600`
    /// with `Age: 3600`, and `expires-past` an `Expires` in the past.
    private func httpHeaders(for path: String) -> [String: String] {
        var headers: [String: String] = [:]
        if path.contains("etag") { headers["ETag"] = "\"v1\"" }
        if path.contains("lastmod") { headers["Last-Modified"] = "Sun, 06 Nov 1994 08:49:37 GMT" }
        if path.contains("fresh") { headers["Cache-Control"] = "public, Max-Age=\"3600\"" }
        if path.contains("stale") { headers["Cache-Control"] = "no-cache" }
        if path.contains("nostore") { headers["Cache-Control"] = "no-store" }
        if path.contains("aged") {
            headers["Cache-Control"] = "max-age=3600"
            headers["Age"] = "3600"
        }
        if path.contains("expires-past") { headers["Expires"] = "Sun, 06 Nov 1994 08:49:37 GMT" }
        return headers
    }

    /// The priority of each request's task as the stub server began to answer and as it
    /// finished, by URL path.
    private let stubPriorities = OSAllocatedUnfairLock(initialState: [String: [Float]]())

    /// Paths the stub server holds the answer to until a test takes them out.
    private let stubHeld = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Held paths whose requests were cancelled before the stub server answered them.
    private let stubStopped = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Answers requests to `image-cache.test`, so the download path of the disk cache runs
    /// without a network: the WebP above by default, 100 000 bytes in chunks for paths
    /// containing `large` (without `Content-Length` when the path also has `chunked`), and 404 for paths containing `missing`. Paths containing `slow` answer after
    /// 0.3 s, so that loads overlap; paths in `stubHeld` answer once a test takes them out,
    /// or not at all when the request is cancelled first.
    private final class StubServer: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "image-cache.test"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            if url.path.contains("http-") {
                answerWithCacheHeaders(url)
                return
            }
            if url.path.contains("offline") {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let body = url.path.contains("large") ? Data(count: 100_000) : webP
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: url.path.contains("missing") ? 404 : 200,
                    httpVersion: nil,
                    headerFields: url.path.contains("chunked")
                        ? ["Content-Type": "image/webp"]
                        : ["Content-Type": "image/webp", "Content-Length": String(body.count)]
                )
            else { return }
            let priority = task?.priority ?? -1
            stubPriorities.withLock { $0[url.path] = [priority] }
            stubRequests.withLock { $0[url.path, default: 0] += 1 }
            if url.path.contains("slow") { Thread.sleep(forTimeInterval: 0.3) }
            // `stopLoading()` comes on this thread, so the wait watches the task instead.
            while stubHeld.withLock({ $0.contains(url.path) }), task?.state == .running {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard task?.state ?? .running == .running else {
                stubStopped.withLock { _ = $0.insert(url.path) }
                return
            }
            let finalPriority = task?.priority ?? -1
            stubPriorities.withLock { $0[url.path, default: []].append(finalPriority) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // In 10 000-byte chunks, as a network delivers a large body.
            for start in stride(from: 0, to: body.count, by: 10_000) {
                client?.urlProtocol(self, didLoad: body[start..<min(start + 10_000, body.count)])
                if body.count > 10_000 { Thread.sleep(forTimeInterval: 0.01) }
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// The WebP with `httpHeaders(for:)`, or 304 to a request whose validator matches.
        private func answerWithCacheHeaders(_ url: URL) {
            var headers = httpHeaders(for: url.path)
            stubRequests.withLock { $0[url.path, default: 0] += 1 }
            let matches =
                (headers["ETag"] != nil
                    && request.value(forHTTPHeaderField: "If-None-Match") == headers["ETag"])
                || (headers["Last-Modified"] != nil
                    && request.value(forHTTPHeaderField: "If-Modified-Since")
                        == headers["Last-Modified"])
            if matches {
                stubRevalidations.withLock { $0[url.path, default: 0] += 1 }
            } else {
                headers["Content-Type"] = "image/webp"
                headers["Content-Length"] = String(webP.count)
            }
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: matches ? 304 : 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !matches {
                client?.urlProtocol(self, didLoad: webP)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// A session that reaches only the stub server's host through it.
    private let stubSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }()

    private func stubCache(
        _ directory: URL,
        metadata: ImageMetadataPolicy = .preserve,
        maximumDownloadBytes: Int? = nil
    ) -> ImageCache {
        ImageCache(
            configuration: ImageCacheConfiguration(
                directory: directory,
                metadata: metadata,
                maximumDownloadBytes: maximumDownloadBytes
            ),
            session: stubSession
        )
    }

    /// Loads `path` from the stub server `times` times through one cache.
    private func load(_ path: String, times: Int, through cache: ImageCache) async throws -> URL {
        let url = URL(string: "https://image-cache.test/\(path)")!
        for _ in 0..<times {
            #expect(try await cache.load(url) == webP)
        }
        return url
    }

    @Test
    func anEntryTheServerCallsFreshIsReadFromDisk() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await load("http-etag-fresh.webp", times: 3, through: stubCache(directory))

        #expect(stubRequests.withLock { $0[url.path] } == 1)
    }

    @Test
    func aStaleEntryIsCheckedWithItsETagAndNotDownloadedAgain() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = try await load("http-etag-stale.webp", times: 1, through: cache)
        let stamp = await cache.stamp(for: url)
        #expect(stamp == nil)

        _ = try await load("http-etag-stale.webp", times: 2, through: cache)

        // `no-cache`: every use asks; each answer is 304, and the entry is the same file.
        #expect(stubRequests.withLock { $0[url.path] } == 3)
        #expect(stubRevalidations.withLock { $0[url.path] } == 2)
        #expect(try await cache.cachedData(for: url) == webP)
    }

    @Test
    func aStaleEntryIsCheckedWithItsLastModifiedDate() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await load("http-lastmod-stale.webp", times: 2, through: stubCache(directory))

        #expect(stubRequests.withLock { $0[url.path] } == 2)
        #expect(stubRevalidations.withLock { $0[url.path] } == 1)
    }

    @Test
    func anEntryWhoseAgeUsedItsFreshnessUpIsChecked() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await load("http-etag-aged.webp", times: 2, through: stubCache(directory))

        #expect(stubRevalidations.withLock { $0[url.path] } == 1)
    }

    @Test
    func aStaleEntryWithoutValidatorsIsDownloadedAgain() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await load("http-expires-past.webp", times: 2, through: stubCache(directory))

        #expect(stubRequests.withLock { $0[url.path] } == 2)
        #expect(stubRevalidations.withLock { $0[url.path] } == nil)
    }

    @Test
    func aResponseTheServerForbidsStoringIsNotWritten() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = try await load("http-nostore.webp", times: 2, through: cache)

        #expect(stubRequests.withLock { $0[url.path] } == 2)
        #expect(try await cache.cachedData(for: url) == nil)
    }

    @Test
    func thePipelineAsksTheServerAgainForAStaleImageItDecodedBefore() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(cache: stubCache(directory))
        let url = URL(string: "https://image-cache.test/http-etag-stale-pipeline.webp")!

        // The second load finds the entry before and after it, and remembers its stamp; the
        // third would take the decoded image by that stamp without asking the server.
        for _ in 0..<3 {
            _ = try await pipeline.load(.url(url), targetPixelDimension: 8)
        }

        #expect(stubRevalidations.withLock { $0[url.path] } == 2)
    }

    @Test
    func imageThatCannotTakeTheMetadataPolicyIsShownButNotCached() async throws {
        let source = try #require(CGImageSourceCreateWithData(webP as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)

        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory, metadata: .removeLocation)
        let url = URL(string: "https://image-cache.test/photo.webp")!
        #expect(try await cache.load(url) == webP)
        #expect(try await cache.cachedData(for: url) == nil)

        let pipeline = ImagePipeline(cache: cache)
        let image = try await pipeline.load(.url(url), targetPixelDimension: 8)
        #expect(image.size == LayoutSize(width: 1, height: 1))
    }

    @Test
    func simultaneousLoadsOfOneURLShareOneDownload() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/shared-slow.webp")!
        async let first = cache.load(url)
        async let second = cache.load(url)
        async let third = cache.load(url)
        let loads = try await [first, second, third]
        #expect(loads.allSatisfy { $0 == webP })
        #expect(stubRequests.withLock { $0[url.path] } == 1)

        #expect(try await cache.load(url) == webP)
        #expect(stubRequests.withLock { $0[url.path] } == 1)
    }

    @Test
    func aCancelledLoadLeavesTheSharedDownloadToTheOthers() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/leave-slow.webp")!
        let leaving = Task { try await cache.load(url) }
        let staying = Task { try await cache.load(url) }
        while await cache.downloadWaiters(for: url) < 2 { await Task.yield() }

        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(try await staying.value == webP)
        #expect(try await cache.cachedData(for: url) == webP)
        #expect(stubRequests.withLock { $0[url.path] } == 1)
    }

    @Test
    func responseOverTheDownloadLimitIsRejectedAndNotCached() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory, maximumDownloadBytes: 10_000)
        for path in ["large.webp", "large-chunked.webp"] {
            let large = URL(string: "https://image-cache.test/" + path)!
            await #expect(throws: ImageCacheError.responseTooLarge) { try await cache.load(large) }
            #expect(try await cache.cachedData(for: large) == nil)
        }

        let small = URL(string: "https://image-cache.test/small.webp")!
        #expect(try await cache.load(small) == webP)
        #expect(try await cache.cachedData(for: small) == webP)
    }

    @Test
    func errorResponsesAreNotCached() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/missing.webp")!
        await #expect(throws: ImageCacheError.status(404)) { try await cache.load(url) }
        #expect(try await cache.cachedData(for: url) == nil)
    }

    @Test
    func cachePoliciesUseDifferentDiskEntries() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try encodedImage(width: 8, height: 8)
        let url = URL(string: "https://example.test/policy.png")!
        let originalCache = ImageCache(configuration: ImageCacheConfiguration(directory: directory))
        let privateCache = ImageCache(
            configuration: ImageCacheConfiguration(
                directory: directory,
                metadata: .removeLocation
            )
        )
        try await originalCache.store(original, for: url)
        #expect(try await privateCache.cachedData(for: url) == nil)
    }

    @Test
    func losslessPngSettingNeverStoresMoreThanTheInput() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try encodedImage(width: 100, height: 100) + Data(repeating: 0, count: 2048)
        let cache = ImageCache(
            configuration: ImageCacheConfiguration(
                directory: directory,
                compression: .losslessIfSmaller,
                minimumCompressionBytes: 0
            )
        )
        let url = URL(string: "https://example.test/flat.png")!
        try await cache.store(original, for: url)
        let saved = try #require(await cache.cachedData(for: url))
        #expect(saved.count < original.count)
        let source = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 100)
        #expect(image.height == 100)
        let before = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let originalPixels = try #require(CGImageSourceCreateImageAtIndex(before, 0, nil))
        #expect(image.dataProvider?.data as Data? == originalPixels.dataProvider?.data as Data?)
    }

    @Test @MainActor
    func imageUsesTheLatestSourceAndItsIntrinsicSize() async throws {
        let first = try encodedImage(width: 20, height: 20)
        let second = try encodedImage(width: 40, height: 10)
        let image = Image(source: .data(first))
        image.source = .data(second)
        for _ in 0..<100 where image.pixelSize == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.pixelSize == LayoutSize(width: 40, height: 10))
        #expect(image.accessibilityContentTraits.contains(.image))
    }

    /// Lays out one image as a column's item, the way a screen places it.
    @MainActor
    private final class Column: Node {
        let image: Image
        let width: Length
        let alignment: AlignItems

        init(_ image: Image, width: Length = .auto, alignment: AlignItems = .start) {
            self.image = image
            self.width = width
            self.alignment = alignment
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                FlexContainer(.column) { image }
                    .width(width)
                    .alignItems(alignment)
            }
            .alignItems(.start)
        }
    }

    @MainActor
    private func loaded(_ image: Image) async throws {
        for _ in 0..<100 where image.pixelSize == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.pixelSize != nil)
    }

    /// Holds an image it shows or leaves out of its layout, as a screen keeps an optional
    /// element in a property.
    @MainActor
    private final class Shelf: Node {
        let image: Image
        var shows = true {
            didSet { setNeedsLayout() }
        }

        init(_ image: Image) {
            self.image = image
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                if shows { image }
            }
            .alignItems(.start)
        }
    }

    @Test @MainActor
    func retryUsesTheDiskCopyUntilTheEntryIsRemoved() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/retry.webp")!
        let image = Image(source: .url(url), pipeline: ImagePipeline(cache: cache))
        for _ in 0..<1000 where image.phase != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(stubRequests.withLock { $0[url.path] } == 1)

        image.retry()
        for _ in 0..<1000 where image.phase != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(stubRequests.withLock { $0[url.path] } == 1)

        try await cache.remove(for: url)
        image.retry()
        for _ in 0..<1000 where image.phase != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.phase == .ready)
        #expect(stubRequests.withLock { $0[url.path] } == 2)
    }

    @Test @MainActor
    func releasingTheNodeCancelsItsDownload() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/released-slow.webp")!
        var image: Image? = Image(source: .url(url), pipeline: ImagePipeline(cache: cache))
        while await cache.downloadWaiters(for: url) < 1 { await Task.yield() }
        weak let released = image

        image = nil
        #expect(released == nil)
        while await cache.downloadWaiters(for: url) > 0 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await cache.cachedData(for: url) == nil)
    }

    @Test @MainActor
    func imageLeavingTheTreeReleasesPixelsAndGetsThemBack() async throws {
        let pipeline = ImagePipeline(previewPixelDimension: 64)
        let image = Image(
            source: .data(try encodedImage(width: 400, height: 200)),
            pipeline: pipeline
        )
        try await loaded(image)
        let shelf = Shelf(image)
        let host = NodeHost(root: shelf, size: LayoutSize(width: 600, height: 600))
        defer { host.detach() }
        let renderer = LayerRenderer()
        host.layoutIfNeeded()
        renderer.render(shelf, in: CALayer())
        for _ in 0..<100 where image.decodedPixelSize?.width != 400 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.decodedPixelSize?.width == 400)

        shelf.shows = false
        host.layoutIfNeeded()
        #expect(!image.isMounted)
        #expect(image.decodedPixelSize == nil)
        #expect(image.pixelSize == LayoutSize(width: 400, height: 200))
        #expect(image.phase == .ready)

        shelf.shows = true
        host.layoutIfNeeded()
        renderer.render(shelf, in: CALayer())
        for _ in 0..<100 where image.decodedPixelSize?.width != 400 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.decodedPixelSize?.width == 400)
    }

    @Test @MainActor
    func imageLeavingTheTreeCancelsItsDownloadAndResumesOnReturn() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let url = URL(string: "https://image-cache.test/away-held.webp")!
        // The server answers only when the test lets it: the image leaves while its download
        // is certainly under way.
        stubHeld.withLock { _ = $0.insert(url.path) }
        defer { stubHeld.withLock { _ = $0.remove(url.path) } }
        let image = Image(source: .url(url), pipeline: ImagePipeline(cache: cache))
        let shelf = Shelf(image)
        let host = NodeHost(root: shelf, size: LayoutSize(width: 600, height: 600))
        defer { host.detach() }
        host.layoutIfNeeded()
        while await cache.downloadWaiters(for: url) < 1 { await Task.yield() }

        shelf.shows = false
        host.layoutIfNeeded()
        while await cache.downloadWaiters(for: url) > 0 { await Task.yield() }
        // The request was cancelled on the server's side.
        for _ in 0..<1000 where !stubStopped.withLock({ $0.contains(url.path) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(stubStopped.withLock { $0.contains(url.path) })
        #expect(image.phase == .loading)
        #expect(image.pixelSize == nil)
        #expect(try await cache.cachedData(for: url) == nil)

        stubHeld.withLock { _ = $0.remove(url.path) }
        shelf.shows = true
        host.layoutIfNeeded()
        // Other tests' slow stub responses can hold the loading threads, so allow seconds.
        for _ in 0..<1000 where image.phase != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.phase == .ready)
        #expect(image.pixelSize == LayoutSize(width: 1, height: 1))
    }

    /// A button showing only an icon.
    @MainActor
    private final class IconButton: Node {
        let icon = Image(placeholder: ImagePlaceholder(size: LayoutSize(width: 24, height: 24)))

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { icon }
        }
    }

    /// A row with an icon-only button and a picture, as a profile header has.
    @MainActor
    private final class Header: Node {
        let button = IconButton()
        let picture = Image(placeholder: ImagePlaceholder(size: LayoutSize(width: 48, height: 48)))
        var icon: Image { button.icon }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                button
                picture
            }
            .alignItems(.start)
        }
    }

    @Test @MainActor
    func imagesAreDecorativeUntilLabeledAndNameTheirButtons() {
        let header = Header()
        header.button.onTap = {}
        let host = NodeHost(root: header, size: LayoutSize(width: 300, height: 100))
        defer { host.detach() }
        host.layoutIfNeeded()
        var items = host.accessibilityItems()
        #expect(!items.contains { $0.node == header.picture.id })
        let unnamed = items.first { $0.node == header.button.id }
        #expect(unnamed?.label == "")

        header.icon.accessibility.label = "Settings"
        header.picture.accessibility.label = "Portrait of Ada"
        host.layoutIfNeeded()
        items = host.accessibilityItems()
        let button = try? #require(items.first { $0.node == header.button.id })
        #expect(button?.label == "Settings")
        #expect(button?.traits.contains(.button) == true)
        let picture = try? #require(items.first { $0.node == header.picture.id })
        #expect(picture?.label == "Portrait of Ada")
        #expect(picture?.traits.contains(.image) == true)
    }

    /// Chromium 152 lays out a 400×200 `<img>` the same way in these containers.
    @Test @MainActor
    func imageKeepsItsProportionsForTheWidthItGets() async throws {
        let data = try encodedImage(width: 400, height: 200)
        let cases: [(Length, AlignItems, LayoutSize)] = [
            (.auto, .start, LayoutSize(width: 400, height: 200)),
            (.points(100), .stretch, LayoutSize(width: 100, height: 50)),
            (.points(100), .center, LayoutSize(width: 400, height: 200)),
        ]
        for (width, alignment, expected) in cases {
            let image = Image(source: .data(data))
            try await loaded(image)
            let host = NodeHost(
                root: Column(image, width: width, alignment: alignment),
                size: LayoutSize(width: 600, height: 600)
            )
            host.layoutIfNeeded()
            #expect(image.frame.size == expected, "width \(width), \(alignment)")
            host.detach()
        }
    }

    /// Holds an image in a row of a fixed height, with or without a height of its own.
    @MainActor
    private final class Strip: Node {
        let image: Image
        let height: Length

        init(_ image: Image, height: Length) {
            self.image = image
            self.height = height
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                FlexContainer(.row) { image.height(height) }
                    .height(.points(40))
            }
            .alignItems(.start)
        }
    }

    /// Chromium 153 gives a 400×200 `<img>` in a row 40 points high, or with a height of 40, a
    /// width of 80: the width follows the height through the proportions.
    @Test @MainActor
    func imageTakesItsWidthFromItsHeight() async throws {
        let data = try encodedImage(width: 400, height: 200)
        for height in [Length.auto, .points(40)] {
            let image = Image(source: .data(data))
            try await loaded(image)
            let host = NodeHost(
                root: Strip(image, height: height),
                size: LayoutSize(width: 600, height: 600)
            )
            host.layoutIfNeeded()
            #expect(image.frame.size == LayoutSize(width: 80, height: 40), "height \(height)")
            host.detach()
        }
    }

    @Test @MainActor
    func scaleTurnsSourcePixelsIntoPoints() async throws {
        let image = Image(source: .data(try encodedImage(width: 400, height: 200)), scale: 2)
        try await loaded(image)
        let host = NodeHost(root: Column(image), size: LayoutSize(width: 600, height: 600))
        defer { host.detach() }
        host.layoutIfNeeded()
        #expect(image.frame.size == LayoutSize(width: 200, height: 100))
        #expect(image.pixelSize == LayoutSize(width: 400, height: 200))

        image.scale = 4
        host.layoutIfNeeded()
        #expect(image.frame.size == LayoutSize(width: 100, height: 50))
    }

    @Test @MainActor
    func placeholderSizeKeepsItsProportionsToo() {
        let image = Image(
            placeholder: ImagePlaceholder(size: LayoutSize(width: 40, height: 20))
        )
        let host = NodeHost(
            root: Column(image, width: .points(100), alignment: .stretch),
            size: LayoutSize(width: 600, height: 600)
        )
        defer { host.detach() }
        host.layoutIfNeeded()
        #expect(image.frame.size == LayoutSize(width: 100, height: 50))
    }

    /// A corner of the shown image.
    enum Corner: Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Every EXIF orientation: where the stored top left (red) and top right (blue) corners
    /// show. The stored picture is 40 × 20; orientations 5–8 swap its sides.
    @Test(
        arguments: [
            (1, Corner.topLeft, Corner.topRight),
            (2, .topRight, .topLeft),
            (3, .bottomRight, .bottomLeft),
            (4, .bottomLeft, .bottomRight),
            (5, .topLeft, .bottomLeft),
            (6, .topRight, .bottomRight),
            (7, .bottomRight, .topRight),
            (8, .bottomLeft, .topLeft),
        ]
    )
    @MainActor
    func exifOrientationIsAppliedToSizeLayoutAndPixels(
        orientation: Int,
        red: Corner,
        blue: Corner
    ) async throws {
        let data = try quartersJPEG(width: 40, height: 20, orientation: orientation)
        let image = Image(source: .data(data))
        try await loaded(image)
        let size =
            orientation >= 5
            ? LayoutSize(width: 20, height: 40) : LayoutSize(width: 40, height: 20)
        #expect(image.pixelSize == size)

        let host = NodeHost(root: Column(image), size: LayoutSize(width: 200, height: 200))
        defer { host.detach() }
        host.layoutIfNeeded()
        #expect(image.frame.size == size)

        // The layer shows this image as it is, top row at the top.
        let shown = try #require(image.layerImage?.image)
        #expect(shown.width == Int(size.width))
        #expect(shown.height == Int(size.height))
        func color(at corner: Corner) -> (red: UInt8, blue: UInt8) {
            let right = corner == .topRight || corner == .bottomRight
            let bottom = corner == .bottomLeft || corner == .bottomRight
            return pixel(
                of: shown,
                x: right ? shown.width - 3 : 2,
                y: bottom ? shown.height - 3 : 2
            )
        }
        let redPixel = color(at: red)
        let bluePixel = color(at: blue)
        #expect(redPixel.red > 200 && redPixel.blue < 60, "orientation \(orientation)")
        #expect(bluePixel.blue > 200 && bluePixel.red < 60, "orientation \(orientation)")
    }

    @Test @MainActor
    func changingContentModeRedrawsTheSameFrame() async throws {
        let data = try encodedImage(width: 40, height: 10)
        let image = Image(source: .data(data))
        for _ in 0..<100 where image.pixelSize == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.pixelSize != nil)

        let host = NodeHost(root: image, size: LayoutSize(width: 40, height: 40))
        defer { host.detach() }
        let renderer = LayerRenderer()
        let container = CALayer()
        host.layoutIfNeeded()
        renderer.render(image, in: container)
        let layer = try #require(renderer.layer(for: image))
        let fitted = try snapshot(layer)
        #expect(alphaAtCorner(fitted) == 0)

        image.contentMode = .fill
        renderer.render(image, in: container)
        let filled = try snapshot(layer)
        #expect(alphaAtCorner(filled) > 0)
    }

    @Test @MainActor
    func layerShowsTheDecodedImageWithoutACopy() async throws {
        let pipeline = ImagePipeline(previewPixelDimension: 64)
        let image = Image(
            source: .data(try encodedImage(width: 400, height: 100)),
            contentMode: .fill,
            placeholder: ImagePlaceholder(size: LayoutSize(width: 100, height: 100)),
            pipeline: pipeline
        )
        let host = NodeHost(root: image, size: LayoutSize(width: 100, height: 100))
        defer { host.detach() }
        let renderer = LayerRenderer()
        host.layoutIfNeeded()
        renderer.render(image, in: CALayer(), scale: 2)
        let layer = try #require(renderer.layer(for: image))
        // The placeholder is one pixel stretched over the frame, not a frame-sized bitmap.
        let placeholder = try #require(layer.contents.map { $0 as AnyObject as! CGImage })
        #expect(placeholder.width == 1)

        try await loaded(image)
        host.layoutIfNeeded()
        renderer.render(image, in: CALayer(), scale: 2)
        // The crop needs more pixels than the source has, so the original is decoded.
        for _ in 0..<100 where image.decodedPixelSize != LayoutSize(width: 400, height: 100) {
            try await Task.sleep(for: .milliseconds(5))
        }
        renderer.render(image, in: CALayer(), scale: 2)
        let decoded = try #require(image.layerImage?.image)
        #expect(decoded.width == 400)
        #expect(layer.contents.map { $0 as AnyObject } === decoded)
        #expect(layer.contentsRect == CGRect(x: 0.375, y: 0, width: 0.25, height: 1))
        #expect(pixelAtCorner(try snapshot(layer)).red > 200)
    }

    @Test
    func fillCropKeepsTheCenterAtTheImagesProportions() {
        #expect(
            LayerRenderer.fillCrop(
                image: CGSize(width: 400, height: 100),
                frame: CGSize(width: 100, height: 100)
            ) == CGRect(x: 0.375, y: 0, width: 0.25, height: 1)
        )
        #expect(
            LayerRenderer.fillCrop(
                image: CGSize(width: 100, height: 400),
                frame: CGSize(width: 200, height: 100)
            ) == CGRect(x: 0, y: 0.4375, width: 1, height: 0.125)
        )
    }

    @Test @MainActor
    func imageDecodesAgainForTheFrameAndDisplayScale() async throws {
        let data = try encodedImage(width: 800, height: 400)
        let pipeline = ImagePipeline(previewPixelDimension: 64)
        let image = Image(source: .data(data), pipeline: pipeline)
        for _ in 0..<100 where image.pixelSize == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.pixelSize == LayoutSize(width: 800, height: 400))
        let preview = try #require(image.decodedPixelSize)
        #expect(preview.width <= 64)

        let host = NodeHost(root: image, size: LayoutSize(width: 40, height: 40))
        defer { host.detach() }
        let renderer = LayerRenderer()
        let container = CALayer()
        host.layoutIfNeeded()
        renderer.render(image, in: container, scale: 2)
        for _ in 0..<100 where image.decodedPixelSize?.width == preview.width {
            try await Task.sleep(for: .milliseconds(5))
        }
        let small = try #require(image.decodedPixelSize)
        #expect(small.width > preview.width)
        #expect(small.width <= 80)

        host.size = LayoutSize(width: 300, height: 300)
        host.layoutIfNeeded()
        renderer.render(image, in: container, scale: 2)
        for _ in 0..<100 where image.decodedPixelSize?.width == small.width {
            try await Task.sleep(for: .milliseconds(5))
        }
        let large = try #require(image.decodedPixelSize)
        #expect(large.width > small.width)
        #expect(large.width <= 600)
        #expect(image.pixelSize == LayoutSize(width: 800, height: 400))
    }

    @Test @MainActor
    func fillDecodesEnoughPixelsForTheCrop() async throws {
        let data = try encodedImage(width: 800, height: 100)
        let pipeline = ImagePipeline(previewPixelDimension: 64)
        let image = Image(source: .data(data), contentMode: .fill, pipeline: pipeline)
        for _ in 0..<100 where image.pixelSize == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.pixelSize != nil)

        let host = NodeHost(root: image, size: LayoutSize(width: 100, height: 100))
        defer { host.detach() }
        let renderer = LayerRenderer()
        host.layoutIfNeeded()
        renderer.render(image, in: CALayer(), scale: 2)
        for _ in 0..<100 where image.decodedPixelSize?.width != 800 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.decodedPixelSize?.width == 800)
    }

    @Test
    func decodedImagesAreSharedWithinTheMemoryBudget() async throws {
        let firstData = try encodedImage(width: 100, height: 100)
        let secondData = try encodedImage(width: 90, height: 90)
        let thirdData = try encodedImage(width: 80, height: 80)
        let pipeline = ImagePipeline(maximumDecodedCacheBytes: 80_000)

        let first = try await pipeline.load(.data(firstData), targetPixelDimension: 100)
        let reused = try await pipeline.load(.data(firstData), targetPixelDimension: 100)
        #expect(first.image === reused.image)
        var state = await pipeline.decodedCacheState()
        #expect(state.entries == 1)
        #expect(state.decodes == 1)
        #expect(state.bytes <= 80_000)

        _ = try await pipeline.load(.data(secondData), targetPixelDimension: 90)
        state = await pipeline.decodedCacheState()
        #expect(state.entries == 2)
        #expect(state.decodes == 2)
        #expect(state.bytes <= 80_000)

        _ = try await pipeline.load(.data(firstData), targetPixelDimension: 100)
        _ = try await pipeline.load(.data(thirdData), targetPixelDimension: 80)
        state = await pipeline.decodedCacheState()
        #expect(state.decodes == 3)
        #expect(state.entries == 2)
        #expect(state.bytes <= 80_000)
        _ = try await pipeline.load(.data(firstData), targetPixelDimension: 100)
        #expect(await pipeline.decodedCacheState().decodes == 3)
        _ = try await pipeline.load(.data(secondData), targetPixelDimension: 90)
        #expect(await pipeline.decodedCacheState().decodes == 4)

        await pipeline.clearDecodedCache()
        state = await pipeline.decodedCacheState()
        #expect(state.entries == 0)
        #expect(state.bytes == 0)
    }

    @Test
    func decodedDimensionLimitCapsTheBitmapOnly() async throws {
        let data = try encodedImage(width: 800, height: 400)
        let pipeline = ImagePipeline(maximumDecodedPixelDimension: 50)
        let loaded = try await pipeline.load(.data(data), targetPixelDimension: 600)
        #expect(max(loaded.image.width, loaded.image.height) == 50)
        #expect(loaded.size == LayoutSize(width: 800, height: 400))
    }

    @Test
    func decodesRunningDuringAClearDoNotRefillTheCache() async throws {
        let first = try encodedImage(width: 3000, height: 3000)
        let second = try encodedImage(width: 2990, height: 3000)
        let pipeline = ImagePipeline()
        async let one = pipeline.load(.data(first), targetPixelDimension: 3000)
        async let two = pipeline.load(.data(second), targetPixelDimension: 3000)
        // Both decodes are under way (one runs, one waits its turn) before the clear.
        while await pipeline.decodedCacheState().decodes < 2 { await Task.yield() }

        await pipeline.clearDecodedCache()
        _ = try await (one, two)
        let state = await pipeline.decodedCacheState()
        #expect(state.entries == 0)
        #expect(state.bytes == 0)
    }

    @Test
    func simultaneousRequestsShareOneDecode() async throws {
        let data = try encodedImage(width: 800, height: 400)
        let pipeline = ImagePipeline()
        async let first = pipeline.load(.data(data), targetPixelDimension: 600)
        async let second = pipeline.load(.data(data), targetPixelDimension: 600)
        let (one, two) = try await (first, second)
        #expect(one.image === two.image)
        let state = await pipeline.decodedCacheState()
        #expect(state.decodes == 1)
    }

    @Test
    func differentImagesDecodeOneAtATime() async throws {
        let sources = try (0..<6).map { index in
            try encodedImage(width: 1600 + index * 16, height: 1600)
        }
        let pipeline = ImagePipeline(maximumDecodedCacheBytes: 0)
        let widths = try await withThrowingTaskGroup(of: Int.self) { group in
            for data in sources {
                group.addTask {
                    try await pipeline.load(.data(data), targetPixelDimension: 1700).image.width
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(widths.sorted() == (0..<6).map { 1600 + $0 * 16 })
        let state = await pipeline.decodedCacheState()
        #expect(state.decodes == 6)
        #expect(state.peakRunning == 1)
    }

    @Test
    func cancelledQueuedDecodeLeavesTheQueue() async throws {
        let gate = DecodeGate()
        try await gate.acquire()
        let queued = Task { try await gate.acquire() }
        while await gate.waitingCount == 0 { await Task.yield() }

        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await gate.waitingCount == 0)

        // The slot is still held by the first caller; releasing it frees the gate for the
        // next one instead of handing it to the cancelled caller.
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    /// Takes a slot of `gate` and records `name` once it has one, releasing it at once.
    private func decode(
        _ name: String,
        in gate: DecodeGate,
        order: OSAllocatedUnfairLock<[String]>,
        isUrgent: @escaping @Sendable () -> Bool = { false }
    ) -> Task<Void, Error> {
        Task {
            try await gate.acquire(isUrgent: isUrgent)
            order.withLock { $0.append(name) }
            await gate.release()
        }
    }

    @Test
    func anUrgentDecodeGoesBeforeTheOnesWaitingLonger() async throws {
        let gate = DecodeGate()
        let order = OSAllocatedUnfairLock(initialState: [String]())
        try await gate.acquire()
        let first = decode("first", in: gate, order: order)
        while await gate.waitingCount < 1 { await Task.yield() }
        let urgent = decode("urgent", in: gate, order: order, isUrgent: { true })
        while await gate.waitingCount < 2 { await Task.yield() }
        let last = decode("last", in: gate, order: order)
        while await gate.waitingCount < 3 { await Task.yield() }

        await gate.release()
        for task in [first, urgent, last] { try await task.value }

        #expect(order.withLock { $0 } == ["urgent", "first", "last"])
    }

    @Test
    func aDecodeThatBecomesUrgentWhileWaitingOvertakes() async throws {
        let gate = DecodeGate()
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let urgency = LoadUrgency()
        try await gate.acquire()
        let first = decode("first", in: gate, order: order)
        while await gate.waitingCount < 1 { await Task.yield() }
        let second = decode("second", in: gate, order: order, isUrgent: { urgency.isUrgent })
        while await gate.waitingCount < 2 { await Task.yield() }

        // Its node scrolled into sight.
        urgency.isUrgent = true
        await gate.release()
        for task in [first, second] { try await task.value }

        #expect(order.withLock { $0 } == ["second", "first"])
    }

    @Test
    func thePipelineDecodesAnImageOnScreenBeforeOnesQueuedEarlier() async throws {
        let gate = DecodeGate()
        let pipeline = ImagePipeline(
            cache: ImageCache(),
            maximumDecodedPixelDimension: nil,
            previewPixelDimension: 256,
            maximumDecodedCacheBytes: 0,
            decodeGate: gate
        )
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let offScreen = LoadUrgency()
        let onScreen = LoadUrgency()
        onScreen.isUrgent = true
        // Another decode holds the gate while these two queue behind it.
        try await gate.acquire()
        func load(_ name: String, width: Int, urgency: LoadUrgency) throws -> Task<Void, Error> {
            let data = try encodedImage(width: width, height: 10)
            return Task {
                _ = try await pipeline.load(.data(data), targetPixelDimension: 64, urgency: urgency)
                order.withLock { $0.append(name) }
            }
        }
        let first = try load("off screen", width: 20, urgency: offScreen)
        while await gate.waitingCount < 1 { await Task.yield() }
        let second = try load("on screen", width: 30, urgency: onScreen)
        while await gate.waitingCount < 2 { await Task.yield() }

        await gate.release()
        for task in [first, second] { try await task.value }
        #expect(order.withLock { $0 } == ["on screen", "off screen"])
    }

    @Test
    func aDownloadGoesAtHighPriorityWhileItsImageIsOnScreen() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let onScreen = LoadUrgency()
        onScreen.isUrgent = true

        let shown = URL(string: "https://image-cache.test/priority-shown.webp")!
        let near = URL(string: "https://image-cache.test/priority-near.webp")!
        _ = try await cache.load(shown, urgency: onScreen)
        _ = try await cache.load(near, urgency: LoadUrgency())

        #expect(stubPriorities.withLock { $0[shown.path] } == [0.75, 0.75])
        #expect(stubPriorities.withLock { $0[near.path] } == [0.25, 0.25])
    }

    @Test
    func aRunningDownloadTakesTheNewPriorityWhenItsImageComesOnScreen() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let urgency = LoadUrgency()
        let url = URL(string: "https://image-cache.test/priority-slow.webp")!

        let loading = Task { try await cache.load(url, urgency: urgency) }
        while stubPriorities.withLock({ $0[url.path] }) == nil { await Task.yield() }
        // Scrolled into sight while the server answers.
        urgency.isUrgent = true
        _ = try await loading.value

        #expect(stubPriorities.withLock { $0[url.path] } == [0.25, 0.75])
    }

    @Test
    func aSharedDownloadIsUrgentOnceAnUrgentCallerJoinsIt() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = stubCache(directory)
        let onScreen = LoadUrgency()
        onScreen.isUrgent = true
        let url = URL(string: "https://image-cache.test/priority-shared-slow.webp")!

        let near = Task { try await cache.load(url, urgency: LoadUrgency()) }
        while stubPriorities.withLock({ $0[url.path] }) == nil { await Task.yield() }
        let shown = Task { try await cache.load(url, urgency: onScreen) }
        while await cache.downloadWaiters(for: url) < 2 { await Task.yield() }
        _ = try await near.value
        _ = try await shown.value

        #expect(stubPriorities.withLock { $0[url.path] } == [0.25, 0.75])
    }

    @Test
    func anUrgencyStopsBeingWatchedOnceItsLoadsAreDone() async throws {
        let urgency = LoadUrgency()
        let pipeline = ImagePipeline()
        _ = try await pipeline.load(
            .data(try encodedImage(width: 20, height: 10)),
            targetPixelDimension: 20,
            urgency: urgency
        )

        for _ in 0..<100 where urgency.watcherCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(urgency.watcherCount == 0)
    }

    @Test
    func aSharedDecodeIsUrgentWhileAnyOfItsCallersIs() {
        let shared = SharedUrgency()
        let onScreen = LoadUrgency()
        onScreen.isUrgent = true
        shared.add(LoadUrgency(), for: 1)
        #expect(!shared.isUrgent)
        shared.add(onScreen, for: 2)
        #expect(shared.isUrgent)
        shared.remove(2)
        #expect(!shared.isUrgent)
    }

    /// Two images in a scroll 100 points tall: one at the top, one 300 points down.
    @MainActor
    private final class Pair: Node {
        let top = Image(placeholder: ImagePlaceholder(size: LayoutSize(width: 40, height: 40)))
        let below = Image(placeholder: ImagePlaceholder(size: LayoutSize(width: 40, height: 40)))
        lazy var scroll = Scroll(.vertical, content: Stacked(top, below))

        final class Stacked: Node {
            let first: Image
            let second: Image

            init(_ first: Image, _ second: Image) {
                self.first = first
                self.second = second
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) {
                    first
                    second
                }
                .gap(260)
                .alignItems(.start)
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @Test @MainActor
    func anImageLoadsFirstWhileItIsOnScreen() {
        let pair = Pair()
        let host = NodeHost(root: pair, size: LayoutSize(width: 100, height: 100))
        host.layoutIfNeeded()
        #expect(pair.top.urgency.isUrgent)
        #expect(!pair.below.urgency.isUrgent)

        pair.scroll.contentOffset = LayoutPoint(x: 0, y: 280)
        #expect(!pair.top.urgency.isUrgent)
        #expect(pair.below.urgency.isUrgent)

        host.detach()
        #expect(!pair.below.urgency.isUrgent)
    }

    @Test
    func unchangedFileIsNotReadAgainForADecodedSize() async throws {
        let file = temporaryCache().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: file) }
        try encodedImage(width: 20, height: 10).write(to: file)
        let pipeline = ImagePipeline()
        let first = try await pipeline.load(.url(file), targetPixelDimension: 40)
        let second = try await pipeline.load(.url(file), targetPixelDimension: 40)
        #expect(first.image === second.image)
        #expect(await pipeline.decodedCacheState().sourceReads == 1)

        try encodedImage(width: 30, height: 10).write(to: file)
        let changed = try await pipeline.load(.url(file), targetPixelDimension: 40)
        #expect(changed.image.width == 30)
        #expect(await pipeline.decodedCacheState().sourceReads == 2)
    }

    @Test
    func cachedRemoteImageIsNotReadAgainForADecodedSize() async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(cache: stubCache(directory))
        let url = URL(string: "https://image-cache.test/stamp.webp")!
        for _ in 0..<4 {
            #expect(try await pipeline.load(.url(url), targetPixelDimension: 8).image.width == 1)
        }
        // The download, then a read of the fresh disk entry that remembers its stamp.
        #expect(await pipeline.decodedCacheState().sourceReads == 2)
        #expect(stubRequests.withLock { $0[url.path] } == 1)
    }

    @Test
    func replacingFileBytesDoesNotReuseAnOldBitmap() async throws {
        let file = temporaryCache().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: file) }
        try encodedImage(width: 20, height: 10).write(to: file)
        let pipeline = ImagePipeline()
        let first = try await pipeline.load(.url(file), targetPixelDimension: 40)
        #expect(first.image.width == 20)

        try encodedImage(width: 30, height: 10).write(to: file)
        let second = try await pipeline.load(.url(file), targetPixelDimension: 40)
        #expect(second.image.width == 30)
        let state = await pipeline.decodedCacheState()
        #expect(state.decodes == 2)
    }

    @Test @MainActor
    func placeholderGivesSizeAndIsReplacedByTheFirstPreview() async throws {
        let data = try encodedImage(width: 40, height: 40)
        let placeholder = ImagePlaceholder(
            color: Color(red: 0, green: 0, blue: 1),
            size: LayoutSize(width: 24, height: 24)
        )
        let image = Image(source: .data(data), placeholder: placeholder)
        #expect(image.phase == .loading)
        let measured = NodeHost(root: Column(image), size: LayoutSize(width: 200, height: 200))
        measured.layoutIfNeeded()
        #expect(image.frame.size == LayoutSize(width: 24, height: 24))
        measured.detach()

        let host = NodeHost(root: image, size: LayoutSize(width: 24, height: 24))
        defer { host.detach() }
        let renderer = LayerRenderer()
        host.layoutIfNeeded()
        renderer.render(image, in: CALayer())
        let layer = try #require(renderer.layer(for: image))
        let before = try snapshot(layer)
        #expect(pixelAtCorner(before).blue > 200)

        for _ in 0..<100 where image.phase != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.phase == .ready)
        host.layoutIfNeeded()
        renderer.render(image, in: CALayer())
        let after = try snapshot(layer)
        #expect(pixelAtCorner(after).red > 200)
    }

    /// Where an image fails to load, and the reason its phase gives.
    enum FailingSource: CaseIterable, Sendable {
        case missingFile, notAnImage, notFound, offline, tooLarge

        var expected: ImageLoadFailure {
            switch self {
            case .missingFile: .file
            case .notAnImage: .invalidImage
            case .notFound: .status(404)
            case .offline: .network(.notConnectedToInternet)
            case .tooLarge: .tooLarge
            }
        }
    }

    @Test(arguments: FailingSource.allCases) @MainActor
    func aFailedImageSaysWhy(_ failing: FailingSource) async throws {
        let directory = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(cache: stubCache(directory, maximumDownloadBytes: 10_000))
        let source: ImageSource
        switch failing {
        case .missingFile:
            source = .url(directory.appendingPathComponent("nothing-here.png"))
        case .notAnImage:
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appendingPathComponent("garbage.png")
            try Data([0, 1, 2]).write(to: file)
            source = .url(file)
        case .notFound:
            source = .url(URL(string: "https://image-cache.test/missing-reason.webp")!)
        case .offline:
            source = .url(URL(string: "https://image-cache.test/offline.webp")!)
        case .tooLarge:
            source = .url(URL(string: "https://image-cache.test/large-reason.webp")!)
        }
        let image = Image(source: source, pipeline: pipeline)

        for _ in 0..<1000 where image.phase.failure == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(image.phase == .failed(failing.expected))
    }

    @Test @MainActor
    func failedImageKeepsPlaceholderAndCanRetry() async throws {
        let file = temporaryCache().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0, 1, 2]).write(to: file)
        let placeholder = ImagePlaceholder(
            color: Color(red: 0, green: 0, blue: 1),
            size: LayoutSize(width: 16, height: 16)
        )
        let image = Image(source: .url(file), placeholder: placeholder)
        for _ in 0..<100 where image.phase.failure == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.phase == .failed(.invalidImage))
        let host = NodeHost(root: image, size: LayoutSize(width: 16, height: 16))
        defer { host.detach() }
        let renderer = LayerRenderer()
        host.layoutIfNeeded()
        renderer.render(image, in: CALayer())
        let layer = try #require(renderer.layer(for: image))
        let shown = try snapshot(layer)
        #expect(pixelAtCorner(shown).blue > 200)

        try encodedImage(width: 32, height: 16).write(to: file)
        image.retry()
        #expect(image.phase == .loading)
        for _ in 0..<100 where image.phase != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(image.phase == .ready)
        #expect(image.pixelSize == LayoutSize(width: 32, height: 16))
        image.source = nil
        #expect(image.phase == .empty)
    }

    /// What the layer shows, as Core Animation places its contents in its bounds.
    @MainActor
    private func snapshot(_ layer: CALayer) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: max(1, Int(layer.bounds.width.rounded(.up))),
                height: max(1, Int(layer.bounds.height.rounded(.up))),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        layer.render(in: context)
        return try #require(context.makeImage())
    }

    /// The pixel at `x`, `y` counted from the top left, as the image is shown.
    private func pixel(of image: CGImage, x: Int, y: Int) -> (red: UInt8, blue: UInt8) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            // The first row in memory is the top row of the image.
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (y * image.width + x) * 4
        return (pixels[index], pixels[index + 2])
    }

    private func alphaAtCorner(_ image: CGImage) -> UInt8 {
        pixelAtCorner(image).alpha
    }

    private func pixelAtCorner(_ image: CGImage) -> (
        red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    ) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (pixels[0], pixels[1], pixels[2], pixels[3])
    }
#endif
