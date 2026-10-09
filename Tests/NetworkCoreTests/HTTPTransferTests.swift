import Foundation
import NetworkCore
import Testing
import os

private func clientWithBase(_ base: String?) -> HTTPClient {
    HTTPClient(
        transport: FakeTransport(script: [.success(reply(200))]),
        baseURL: base.flatMap { URL(string: $0) }
    )
}

private func workspace() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("transfer-core-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: Base URL

@Test
func aPathContinuesTheBaseURLsOwnPath() throws {
    let client = clientWithBase("https://api.example.com/v1")

    #expect(try client.url(for: "items/3").absoluteString == "https://api.example.com/v1/items/3")
    #expect(try client.url(for: "/items/3").absoluteString == "https://api.example.com/v1/items/3")
    #expect(try client.url(for: "").absoluteString == "https://api.example.com/v1/")
    #expect(
        try clientWithBase("https://api.example.com/v1/").url(for: "items").absoluteString
            == "https://api.example.com/v1/items"
    )
    #expect(
        try clientWithBase("http://localhost:8080").url(for: "ping").absoluteString
            == "http://localhost:8080/ping"
    )
}

@Test
func eachSegmentIsEncodedOnItsOwn() throws {
    let client = clientWithBase("https://api.example.com")

    // A space and a question mark are part of the name, not of the address's structure.
    #expect(
        try client.url(for: "files/a b?.txt").absoluteString
            == "https://api.example.com/files/a%20b%3F.txt"
    )
    // A percent sign is data too: the text is taken as written, not as already encoded.
    #expect(
        try client.url(for: "files/100%").absoluteString == "https://api.example.com/files/100%25"
    )
    #expect(
        try client.url(for: "a//b/").absoluteString == "https://api.example.com/a/b",
        "empty segments are dropped"
    )
}

@Test
func queryValuesAreEncodedSoThatPlusAndAmpersandStayData() throws {
    let client = clientWithBase("https://api.example.com")

    let url = try client.url(
        for: "search",
        query: [
            URLQueryItem(name: "q", value: "a+b&c=d"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "empty", value: nil),
        ]
    )

    #expect(url.absoluteString == "https://api.example.com/search?q=a%2Bb%26c%3Dd&page=2&empty=")
}

@Test
func theBaseURLsQueryAndFragmentAreNotCarriedOver() throws {
    let client = clientWithBase("https://api.example.com/v1?token=secret#frag")

    #expect(try client.url(for: "items").absoluteString == "https://api.example.com/v1/items")
}

@Test
func aPathCannotClimbOutOfTheBasePath() {
    let client = clientWithBase("https://api.example.com/v1")

    for path in ["../admin", "items/../../admin", "./items", "items/.."] {
        do {
            _ = try client.url(for: path)
            Issue.record("\(path) was accepted")
        } catch {
            guard case .invalidRequest = error else {
                Issue.record("expected invalidRequest for \(path), got \(error)")
                continue
            }
        }
    }
}

@Test
func withoutAUsableBaseURLNothingIsBuilt() {
    for base in [nil, "ftp://files.example.com", "/relative/only"] {
        do {
            _ = try clientWithBase(base).url(for: "items")
            Issue.record("\(base ?? "nil") was accepted")
        } catch {
            guard case .invalidRequest = error else {
                Issue.record("expected invalidRequest for \(base ?? "nil"), got \(error)")
                continue
            }
        }
    }
}

@Test
func aBuiltRequestCarriesItsMethodHeadersAndJSONBody() throws {
    let client = clientWithBase("https://api.example.com/v1")

    let plain = try client.request(
        .delete,
        "items/3",
        headers: ["X-Mine": "1"],
        timeout: 5
    )
    let json = try client.request(.post, "items", json: Item(id: 1, name: "a"))

    #expect(plain.method == .delete)
    #expect(plain.url.absoluteString == "https://api.example.com/v1/items/3")
    #expect(plain.headers["x-mine"] == "1")
    #expect(plain.timeout == 5)
    #expect(json.url.absoluteString == "https://api.example.com/v1/items")
    #expect(json.headers["content-type"] == "application/json")
    #expect(try JSONDecoder().decode(Item.self, from: try #require(json.body)) == Item(id: 1, name: "a"))
}

// MARK: Download through the client

/// A transport that writes a real file for each download, as a streaming one does, and remembers
/// them so that a test can tell what was cleaned up.
private actor StreamingTransport: HTTPTransport {
    typealias Plan = @Sendable (Int) -> (status: Int, content: String)

    private let plan: Plan
    private let cancelsTheCaller: Bool
    private(set) var files: [URL] = []
    private(set) var downloads = 0

    init(cancelsTheCaller: Bool = false, _ plan: @escaping Plan) {
        self.plan = plan
        self.cancelsTheCaller = cancelsTheCaller
    }

    func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        throw .invalidRequest("this transport only downloads")
    }

    func download(_ request: HTTPRequest, maxBytes: Int?, partial: PartialDownload?)
        async throws(HTTPError) -> HTTPDownload
    {
        downloads += 1
        let (status, content) = plan(downloads)
        let response = HTTPResponse(status: status, url: request.url)
        guard (200...299).contains(status) else {
            var failed = response
            failed.body = Data(content.utf8)
            return HTTPDownload(response: failed, file: nil, bytes: 0)
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamed-" + UUID().uuidString)
        do {
            try Data(content.utf8).write(to: file)
        } catch {
            throw .fileSystem(underlying: error)
        }
        files.append(file)
        if cancelsTheCaller { withUnsafeCurrentTask { $0?.cancel() } }
        return HTTPDownload(response: response, file: file, bytes: content.utf8.count)
    }
}

@Test
func aDownloadIsPutAtItsDestinationWithMissingDirectoriesCreated() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = StreamingTransport { _ in (200, "hello") }
    let client = makeClient(transport)
    let destination = directory.appendingPathComponent("a/b/file.txt")

    let download = try await client.download(HTTPRequest(.get, testURL), to: destination)

    #expect(download.file == destination)
    #expect(download.bytes == 5)
    #expect(download.response.body.isEmpty)
    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "hello")
    for file in await transport.files {
        #expect(!FileManager.default.fileExists(atPath: file.path), "the temporary file was moved")
    }
}

@Test
func aRefusedAttemptsFileIsRemovedAndTheRetryIsWhatIsKept() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The first attempt gets a 2xx the caller does not accept; the second gets what it wants.
    let transport = StreamingTransport { attempt in
        attempt == 1 ? (200, "wrong") : (404, "missing")
    }
    let client = makeClient(transport)
    let destination = directory.appendingPathComponent("file.txt")
    try Data("old".utf8).write(to: destination)

    do {
        _ = try await client.download(
            HTTPRequest(.get, testURL),
            to: destination,
            expecting: .only(404)
        )
        Issue.record("a 200 was accepted although only 404 was")
    } catch {
        guard case .status(let response) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(response.status == 200)
    }

    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "old")
    for file in await transport.files {
        #expect(!FileManager.default.fileExists(atPath: file.path), "a refused file is removed")
    }
}

@Test
func anAcceptedAnswerWithoutAFileLeavesTheDestinationAlone() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = StreamingTransport { _ in (404, "no such thing") }
    let client = makeClient(transport)
    let destination = directory.appendingPathComponent("file.txt")

    let download = try await client.download(
        HTTPRequest(.get, testURL),
        to: destination,
        expecting: .success(or: 404)
    )

    #expect(download.response.status == 404)
    #expect(download.file == nil)
    #expect(String(decoding: download.response.body, as: UTF8.self) == "no such thing")
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func aDownloadCancelledAfterTheTransportReturnedLeavesNothing() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = StreamingTransport(cancelsTheCaller: true) { _ in (200, "late") }
    let client = makeClient(transport)
    let destination = directory.appendingPathComponent("file.txt")

    let task = Task { try await client.download(HTTPRequest(.get, testURL), to: destination) }
    do {
        _ = try await task.value
        Issue.record("the cancelled download completed")
    } catch {
        guard case .cancelled = error as? HTTPError else {
            Issue.record("expected cancelled, got \(error)")
            return
        }
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
    for file in await transport.files {
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test
func aDestinationThatCannotBeWrittenIsAFileSystemErrorAndLeavesNoTemporaryFile() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appendingPathComponent("blocker")
    try Data("a file, not a directory".utf8).write(to: blocker)
    let transport = StreamingTransport { _ in (200, "x") }
    let client = makeClient(transport)

    do {
        _ = try await client.download(
            HTTPRequest(.get, testURL),
            to: blocker.appendingPathComponent("inside.txt")
        )
        Issue.record("a destination under a file was accepted")
    } catch {
        guard case .fileSystem = error else {
            Issue.record("expected fileSystem, got \(error)")
            return
        }
    }
    for file in await transport.files {
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test
func theDefaultDownloadWritesTheBodyOfASendAndPassesTheLimit() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = FakeTransport(script: [.success(reply(200, "from send"))])
    let client = makeClient(transport)
    let destination = directory.appendingPathComponent("file.txt")

    let download = try await client.download(
        HTTPRequest(.get, testURL),
        to: destination,
        maxBytes: 1234
    )

    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "from send")
    #expect(download.bytes == 9)
    #expect(await transport.limits == [1234])
}

// MARK: Upload through the client

@Test
func theDefaultUploadSendsTheFileInPlaceOfTheBody() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt")
    try Data("from a file".utf8).write(to: source)
    let transport = FakeTransport(script: [.success(reply(201, "stored"))])
    let client = makeClient(transport)

    let response = try await client.upload(
        HTTPRequest(.put, testURL, body: Data("not this".utf8)),
        fromFile: source
    )

    #expect(response.status == 201)
    let sent = try #require(await transport.requests.first)
    #expect(String(decoding: try #require(sent.body), as: UTF8.self) == "from a file")
}

@Test
func anUploadOfAMissingFileIsAFileSystemErrorAndSendsNothing() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = FakeTransport(script: [.success(reply(200))])
    let client = makeClient(transport)

    do {
        _ = try await client.upload(
            HTTPRequest(.put, testURL),
            fromFile: directory.appendingPathComponent("missing.txt")
        )
        Issue.record("a missing file was accepted")
    } catch {
        guard case .fileSystem = error else {
            Issue.record("expected fileSystem, got \(error)")
            return
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func anUploadIsRetriedLikeAnyRequestOfItsMethod() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt")
    try Data("again".utf8).write(to: source)
    let transport = FakeTransport(script: [.success(reply(503)), .success(reply(200, "ok"))])
    let waits = Waits()
    let client = makeClient(transport, retry: RetryPolicy(maxAttempts: 3), waits: waits)

    let retried = try await client.upload(HTTPRequest(.put, testURL), fromFile: source)
    #expect(retried.status == 200)
    #expect(await transport.requests.count == 2)

    // A POST is not repeated on its own, so the 503 is the answer.
    let posts = FakeTransport(script: [.success(reply(503)), .success(reply(200))])
    let postClient = makeClient(posts, retry: RetryPolicy(maxAttempts: 3))
    do {
        _ = try await postClient.upload(HTTPRequest(.post, testURL), fromFile: source)
        Issue.record("a POST upload was repeated")
    } catch {
        guard case .status(let response) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(response.status == 503)
    }
    #expect(await posts.requests.count == 1)
}

// MARK: Uploading a stream through the default

@Test
func theDefaultUploadOfAStreamReadsItAndSendsItsBytes() async throws {
    let transport = FakeTransport(script: [.success(reply(200, "ok"))])
    let client = makeClient(transport)
    let made = OSAllocatedUnfairLock(initialState: 0)

    let response = try await client.upload(
        HTTPRequest(.put, testURL, body: Data("not this".utf8)),
        from: HTTPBodyStream(length: 5) {
            made.withLock { $0 += 1 }
            return InputStream(data: Data("hello".utf8))
        }
    )

    #expect(response.status == 200)
    let sent = try #require(await transport.requests.first)
    #expect(String(decoding: try #require(sent.body), as: UTF8.self) == "hello")
    #expect(made.withLock { $0 } == 1)
}

@Test
func aStreamThatCannotBeMadeIsAFileSystemErrorAndNothingIsSent() async throws {
    let transport = FakeTransport(script: [.success(reply(200))])
    let client = makeClient(transport)
    struct Broken: Error {}

    do {
        _ = try await client.upload(
            HTTPRequest(.put, testURL),
            from: HTTPBodyStream { throw Broken() }
        )
        Issue.record("a broken stream was sent")
    } catch {
        guard case .fileSystem = error else {
            Issue.record("expected fileSystem, got \(error)")
            return
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func aRetryOfAStreamThroughTheDefaultTakesANewStreamEachTime() async throws {
    let transport = FakeTransport(script: [.success(reply(503)), .success(reply(200))])
    let client = makeClient(transport, retry: RetryPolicy(maxAttempts: 3))
    let made = OSAllocatedUnfairLock(initialState: 0)

    _ = try await client.upload(
        HTTPRequest(.put, testURL),
        from: HTTPBodyStream {
            made.withLock { $0 += 1 }
            return InputStream(data: Data("again".utf8))
        }
    )

    #expect(made.withLock { $0 } == 2)
    #expect(await transport.requests.count == 2)
}

@Test
func aDataBodyStreamHasItsLengthAndCanBeStartedOverAsOftenAsWanted() throws {
    let body = HTTPBodyStream.data(Data("abc".utf8))

    #expect(body.length == 3)
    #expect(try body.readAll() == Data("abc".utf8))
    #expect(try body.readAll() == Data("abc".utf8))
}

// MARK: Continuing a download

@Test
func aDownloadCanBeContinuedOnlyWithBytesAndAValidatorThatIfRangeAccepts() throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let partial = PartialDownload(file: directory.appendingPathComponent("a.part"))
    #expect(partial.resumeHeaders() == nil, "no file")

    try Data("hello".utf8).write(to: partial.file)
    #expect(partial.resumeHeaders() == nil, "bytes with no record")

    partial.store(HTTPValidators(etag: "\"abc\""))
    let strong = try #require(partial.resumeHeaders())
    #expect(strong["Range"] == "bytes=5-")
    #expect(strong["If-Range"] == "\"abc\"")

    partial.store(HTTPValidators(etag: "W/\"abc\"", lastModified: "Sat, 01 Jan 2022 00:00:00 GMT"))
    #expect(
        partial.resumeHeaders()?["If-Range"] == "Sat, 01 Jan 2022 00:00:00 GMT",
        "a weak tag is not allowed in If-Range, so the date is used"
    )

    partial.store(HTTPValidators(etag: "W/\"abc\""))
    #expect(partial.resumeHeaders() == nil, "a weak tag alone cannot be used")

    partial.store(HTTPValidators(freshUntil: Date()))
    #expect(partial.resumeHeaders() == nil, "freshness is not a validator")

    partial.discard()
    #expect(!FileManager.default.fileExists(atPath: partial.file.path))
    #expect(!FileManager.default.fileExists(atPath: partial.validatorsFile.path))
}

@Test
func theContentRangeIsReadForItsFirstByteAndTotal() {
    func read(_ text: String) -> (first: Int64?, total: Int64?)? {
        var headers = HTTPHeaders()
        headers["Content-Range"] = text
        return PartialDownload.contentRange(of: headers)
    }

    #expect(read("bytes 5-10/11")?.first == 5)
    #expect(read("bytes 5-10/11")?.total == 11)
    #expect(read("bytes */11")?.first == nil)
    #expect(read("bytes */11")?.total == 11)
    #expect(read("bytes 0-9/*")?.total == nil)
    #expect(read("items 0-9/10") == nil)
    #expect(read("bytes nonsense") == nil)
    #expect(PartialDownload.contentRange(of: HTTPHeaders()) == nil)
}

@Test
func theDefaultTransportAddsASixteenHundredAndSixPartToTheFileAndAnythingElseStartsOver() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let partial = PartialDownload(file: directory.appendingPathComponent("a.part"))
    try Data("hello".utf8).write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))
    let part = reply(
        206,
        " world",
        headers: ["Content-Range": "bytes 5-10/11", "ETag": "\"v1\""]
    )
    let transport = FakeTransport(script: [.success(part)])
    let client = makeClient(transport)
    let destination = directory.appendingPathComponent("a.txt")

    let download = try await client.download(
        HTTPRequest(.get, testURL),
        to: destination,
        continuing: partial
    )

    let sent = try #require(await transport.requests.first)
    #expect(sent.headers["Range"] == "bytes=5-")
    #expect(sent.headers["If-Range"] == "\"v1\"")
    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "hello world")
    #expect(download.bytes == 11)
    #expect(!FileManager.default.fileExists(atPath: partial.file.path))

    // The same file, now answered with the whole thing: it starts over.
    try Data("hello".utf8).write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))
    let whole = FakeTransport(script: [.success(reply(200, "brand new", headers: ["ETag": "\"v2\""]))])
    _ = try await makeClient(whole).download(
        HTTPRequest(.get, testURL),
        to: destination,
        continuing: partial
    )
    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "brand new")
}

@Test
func theDefaultTransportRefusesAPartThatDoesNotFollowTheFile() async throws {
    let directory = try workspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let partial = PartialDownload(file: directory.appendingPathComponent("a.part"))
    try Data("hello".utf8).write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))
    let transport = FakeTransport(
        script: [.success(reply(206, "xx", headers: ["Content-Range": "bytes 0-1/7"]))]
    )

    do {
        _ = try await makeClient(transport).download(
            HTTPRequest(.get, testURL),
            to: directory.appendingPathComponent("a.txt"),
            continuing: partial
        )
        Issue.record("a misplaced part was accepted")
    } catch {
        guard case .status(let response) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(response.status == 206)
    }
    #expect(String(decoding: try Data(contentsOf: partial.file), as: UTF8.self) == "hello")
}
