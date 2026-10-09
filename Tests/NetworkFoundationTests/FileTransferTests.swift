import Foundation
import NetworkCore
import Testing
import os

@testable import NetworkFoundation

/// A directory of its own for the files a test downloads, so that "nothing was left behind" can be
/// read off it.
private struct Workspace {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    var leftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func transport(redirects: URLSessionTransport.RedirectPolicy = .follow) -> URLSessionTransport {
        URLSessionTransport(
            session: URLSession(configuration: .ephemeral),
            redirects: redirects,
            downloadDirectory: directory
        )
    }
}

/// Bytes that are not all the same, so that a chunk written in the wrong place shows.
private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
}

// MARK: Downloading

@Test(.timeLimit(.minutes(1)))
func aDownloadWritesTheBodyToAFileAndReturnsAnEmptyBody() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(3 * 1024 * 1024)
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200, headers: [("Content-Type", "application/octet-stream")])
        reply.body = content
        return reply
    }
    defer { server.stop() }

    let download = try await workspace.transport().download(
        HTTPRequest(.get, server.url("/big")),
        maxBytes: nil
    )

    #expect(download.response.status == 200)
    #expect(download.response.body.isEmpty)
    #expect(download.bytes == content.count)
    let file = try #require(download.file)
    #expect(try Data(contentsOf: file) == content)
    #expect(workspace.leftovers == [file.lastPathComponent])
}

@Test(.timeLimit(.minutes(1)))
func anAnswerThatAnnouncesMoreThanTheLimitIsRefusedAndLeavesNoFile() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200)
        reply.body = pattern(1024 * 1024)
        return reply
    }
    defer { server.stop() }

    do {
        _ = try await workspace.transport().download(
            HTTPRequest(.get, server.url("/big")),
            maxBytes: 100 * 1024
        )
        Issue.record("the download was not refused")
    } catch {
        guard case .responseTooLarge(let limit) = error else {
            Issue.record("expected responseTooLarge, got \(error)")
            return
        }
        #expect(limit == 100 * 1024)
    }
    #expect(workspace.leftovers.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aBodyThatPassesTheLimitWithoutAnnouncingItsSizeIsCutOffAndLeavesNoFile() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200)
        reply.body = pattern(1024 * 1024)
        reply.announcesLength = false
        return reply
    }
    defer { server.stop() }

    do {
        _ = try await workspace.transport().download(
            HTTPRequest(.get, server.url("/stream")),
            maxBytes: 100 * 1024
        )
        Issue.record("the download was not stopped")
    } catch {
        guard case .responseTooLarge = error else {
            Issue.record("expected responseTooLarge, got \(error)")
            return
        }
    }
    #expect(workspace.leftovers.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func anAnswerThatIsNotASuccessIsNotWrittenAndItsBodyIsCut() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { request in
        var reply = ServerReply(request.path == "/long" ? 500 : 404, "gone")
        if request.path == "/long" { reply.body = pattern(200 * 1024) }
        return reply
    }
    defer { server.stop() }
    let transport = workspace.transport()

    let missing = try await transport.download(
        HTTPRequest(.get, server.url("/missing")),
        maxBytes: nil
    )
    let long = try await transport.download(HTTPRequest(.get, server.url("/long")), maxBytes: nil)

    #expect(missing.response.status == 404)
    #expect(missing.file == nil)
    #expect(String(decoding: missing.response.body, as: UTF8.self) == "gone")
    #expect(long.response.status == 500)
    #expect(long.file == nil)
    #expect(long.response.body.count == HTTPDownload.errorBodyLimit)
    #expect(workspace.leftovers.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func cancellingADownloadInTheMiddleRemovesTheFile() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    // Announces ten mebibytes, sends a hundred kibibytes and goes quiet.
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200)
        reply.body = pattern(100 * 1024)
        reply.announcedLength = 10 * 1024 * 1024
        reply.keepOpen = .seconds(30)
        return reply
    }
    defer { server.stop() }
    let transport = workspace.transport()

    let task = Task {
        try await transport.download(HTTPRequest(.get, server.url("/slow")), maxBytes: nil)
    }
    // Wait until some of the body is on disk, then cancel.
    var started = false
    for _ in 0..<200 where !started {
        try await Task.sleep(for: .milliseconds(25))
        started = !workspace.leftovers.isEmpty
    }
    #expect(started)
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("the download was not cancelled")
    } catch {
        guard case .cancelled = error as? HTTPError else {
            Issue.record("expected cancelled, got \(error)")
            return
        }
    }
    #expect(workspace.leftovers.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aDownloadRedirectedToAnotherOriginLosesTheCredentials() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let elsewhere = try await LocalServer.start { _ in ServerReply(200, "elsewhere") }
    defer { elsewhere.stop() }
    let origin = try await LocalServer.start { _ in
        ServerReply(302, headers: [("Location", elsewhere.url("/landing").absoluteString)])
    }
    defer { origin.stop() }

    let download = try await workspace.transport().download(
        HTTPRequest(
            .get,
            origin.url("/start"),
            headers: ["Authorization": "Bearer secret", "X-Trace": "keep"]
        ),
        maxBytes: nil
    )

    let file = try #require(download.file)
    #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "elsewhere")
    let landed = try #require(elsewhere.requests.first)
    #expect(landed.headers["authorization"] == nil)
    #expect(landed.headers["x-trace"] == "keep")
}

@Test(.timeLimit(.minutes(1)))
func aHeadRequestCannotBeDownloaded() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }

    do {
        _ = try await workspace.transport().download(
            HTTPRequest(.head, URL(string: "http://127.0.0.1:1/")!),
            maxBytes: nil
        )
        Issue.record("a HEAD download was accepted")
    } catch {
        guard case .invalidRequest = error else {
            Issue.record("expected invalidRequest, got \(error)")
            return
        }
    }
}

// MARK: Uploading

@Test(.timeLimit(.minutes(1)))
func anUploadSendsTheFileAsTheBody() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(5 * 1024 * 1024)
    let source = workspace.file("source.bin")
    try content.write(to: source)
    let server = try await LocalServer.start { request in
        ServerReply(200, "got \(request.body.count)")
    }
    defer { server.stop() }

    let response = try await workspace.transport().upload(
        HTTPRequest(
            .put,
            server.url("/blob"),
            headers: ["Content-Type": "application/octet-stream"],
            // Ignored: the file is the body.
            body: Data("not this".utf8)
        ),
        fromFile: source,
        maxResponseBytes: nil
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "got \(content.count)")
    let seen = try #require(server.requests.first)
    #expect(seen.method == "PUT")
    #expect(seen.body == content)
    #expect(seen.headers["content-type"] == "application/octet-stream")
    #expect(seen.headers["content-length"] == "\(content.count)")
}

@Test(.timeLimit(.minutes(1)))
func anUploadWhoseAnswerPassesTheLimitIsStopped() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let source = workspace.file("source.bin")
    try pattern(1024).write(to: source)
    let server = try await LocalServer.start { _ in
        var reply = ServerReply(200)
        reply.body = pattern(500 * 1024)
        return reply
    }
    defer { server.stop() }

    do {
        _ = try await workspace.transport().upload(
            HTTPRequest(.post, server.url("/blob")),
            fromFile: source,
            maxResponseBytes: 1024
        )
        Issue.record("the answer was not refused")
    } catch {
        guard case .responseTooLarge = error else {
            Issue.record("expected responseTooLarge, got \(error)")
            return
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func anUploadOfAFileThatIsNotThereFailsBeforeAnythingIsSent() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in ServerReply(200) }
    defer { server.stop() }

    do {
        _ = try await workspace.transport().upload(
            HTTPRequest(.post, server.url("/blob")),
            fromFile: workspace.file("missing.bin"),
            maxResponseBytes: nil
        )
        Issue.record("a missing file was accepted")
    } catch {
        guard case .fileSystem = error else {
            Issue.record("expected fileSystem, got \(error)")
            return
        }
    }
    #expect(server.requests.isEmpty)
}

// MARK: Through the client

@Test(.timeLimit(.minutes(1)))
func theClientPutsADownloadAtItsDestinationOnlyOnceTheAnswerIsAccepted() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(256 * 1024)
    let calls = CallCounter()
    let server = try await LocalServer.start { _ in
        // The first answer is refused as unavailable; the retry gets the file.
        if calls.next() == 1 { return ServerReply(503, "later") }
        var reply = ServerReply(200)
        reply.body = content
        return reply
    }
    defer { server.stop() }
    let client = HTTPClient(
        transport: workspace.transport(),
        retry: RetryPolicy(maxAttempts: 3),
        environment: HTTPClient.Environment(sleep: { _ in })
    )
    let destination = workspace.directory.appendingPathComponent("kept/one.bin")

    let download = try await client.download(
        HTTPRequest(.get, server.url("/file")),
        to: destination
    )

    #expect(download.file == destination)
    #expect(try Data(contentsOf: destination) == content)
    #expect(server.requests.count == 2)
    // Only the destination remains: the refused attempt's file never existed, and the accepted
    // attempt's file was moved.
    #expect(workspace.leftovers == ["kept"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["one.bin"])
}

@Test(.timeLimit(.minutes(1)))
func aRefusedDownloadLeavesTheDestinationAsItWas() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in ServerReply(404, "no such file") }
    defer { server.stop() }
    let client = HTTPClient(transport: workspace.transport())
    let destination = workspace.file("kept.bin")
    try Data("old".utf8).write(to: destination)

    do {
        _ = try await client.download(HTTPRequest(.get, server.url("/file")), to: destination)
        Issue.record("a 404 was accepted")
    } catch {
        guard case .status(let response) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(response.status == 404)
        #expect(String(decoding: response.body, as: UTF8.self) == "no such file")
    }
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(workspace.leftovers == ["kept.bin"])
}

@Test(.timeLimit(.minutes(1)))
func aSuccessfulDownloadReplacesAnExistingFile() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in ServerReply(200, "new content") }
    defer { server.stop() }
    let client = HTTPClient(transport: workspace.transport())
    let destination = workspace.file("kept.bin")
    try Data("old".utf8).write(to: destination)

    _ = try await client.download(HTTPRequest(.get, server.url("/file")), to: destination)

    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "new content")
    #expect(workspace.leftovers == ["kept.bin"])
}

@Test(.timeLimit(.minutes(1)))
func theClientUploadsAFileAndRetriesItFromTheStart() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(64 * 1024)
    let source = workspace.file("source.bin")
    try content.write(to: source)
    let calls = CallCounter()
    let server = try await LocalServer.start { _ in
        calls.next() == 1 ? ServerReply(503) : ServerReply(200, "stored")
    }
    defer { server.stop() }
    let client = HTTPClient(
        transport: workspace.transport(),
        retry: RetryPolicy(maxAttempts: 3),
        environment: HTTPClient.Environment(sleep: { _ in })
    )

    let response = try await client.upload(
        HTTPRequest(.put, server.url("/blob")),
        fromFile: source
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "stored")
    #expect(server.requests.count == 2)
    #expect(server.requests.allSatisfy { $0.body == content })
}

private final class CallCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    /// The number of this call, counting from one.
    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

// MARK: Uploading a stream

/// A stream of `content`, read from memory but counted: how many were made says how many times the
/// body was started.
private final class CountedBody: Sendable {
    private let made = OSAllocatedUnfairLock(initialState: 0)
    let content: Data

    init(_ content: Data) { self.content = content }

    var count: Int { made.withLock { $0 } }

    func body(length: Int64?) -> HTTPBodyStream {
        HTTPBodyStream(length: length) { [self] in
            made.withLock { $0 += 1 }
            return InputStream(data: content)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func aStreamOfKnownLengthIsSentWithItsLength() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let counted = CountedBody(pattern(300 * 1024))
    let server = try await LocalServer.start { request in
        ServerReply(200, "got \(request.body.count)")
    }
    defer { server.stop() }

    let response = try await workspace.transport().upload(
        HTTPRequest(.put, server.url("/blob"), headers: ["Content-Type": "application/octet-stream"]),
        from: counted.body(length: Int64(counted.content.count)),
        maxResponseBytes: nil
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "got \(counted.content.count)")
    let seen = try #require(server.requests.first)
    #expect(seen.body == counted.content)
    #expect(seen.headers["content-length"] == "\(counted.content.count)")
    #expect(seen.headers["transfer-encoding"] == nil)
    #expect(counted.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aStreamOfUnknownLengthIsSentInChunks() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let counted = CountedBody(pattern(200 * 1024))
    let server = try await LocalServer.start { request in
        ServerReply(200, "got \(request.body.count)")
    }
    defer { server.stop() }

    let response = try await workspace.transport().upload(
        HTTPRequest(.post, server.url("/blob")),
        from: counted.body(length: nil),
        maxResponseBytes: nil
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "got \(counted.content.count)")
    let seen = try #require(server.requests.first)
    #expect(seen.body == counted.content)
    #expect(seen.headers["transfer-encoding"]?.lowercased().contains("chunked") == true)
    #expect(seen.headers["content-length"] == nil)
}

@Test(.timeLimit(.minutes(1)))
func aRetryOfAStreamTakesANewStreamAndSendsTheSameBody() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let counted = CountedBody(pattern(64 * 1024))
    let calls = CallCounter()
    let server = try await LocalServer.start { _ in
        calls.next() == 1 ? ServerReply(503) : ServerReply(200, "stored")
    }
    defer { server.stop() }
    let client = HTTPClient(
        transport: workspace.transport(),
        retry: RetryPolicy(maxAttempts: 3),
        environment: HTTPClient.Environment(sleep: { _ in })
    )

    let response = try await client.upload(
        HTTPRequest(.put, server.url("/blob")),
        from: counted.body(length: Int64(counted.content.count))
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "stored")
    #expect(server.requests.count == 2)
    #expect(server.requests.allSatisfy { $0.body == counted.content })
    #expect(counted.count == 2, "each attempt took a new stream")
}

@Test(.timeLimit(.minutes(1)))
func aStreamThatCannotBeMadeFailsTheRequestWithThatReason() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in ServerReply(200) }
    defer { server.stop() }
    struct Broken: Error {}

    do {
        _ = try await workspace.transport().upload(
            HTTPRequest(.put, server.url("/blob")),
            from: HTTPBodyStream(length: 10) { throw Broken() },
            maxResponseBytes: nil
        )
        Issue.record("a broken stream was sent")
    } catch {
        guard case .fileSystem(let underlying) = error, underlying is Broken else {
            Issue.record("expected fileSystem with the stream's error, got \(error)")
            return
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func aFileStreamSendsTheFileAndReportsItsSize() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(100 * 1024)
    let source = workspace.file("source.bin")
    try content.write(to: source)
    let server = try await LocalServer.start { request in
        ServerReply(200, "got \(request.body.count)")
    }
    defer { server.stop() }
    let body = HTTPBodyStream.file(at: source)

    _ = try await workspace.transport().upload(
        HTTPRequest(.put, server.url("/blob")),
        from: body,
        maxResponseBytes: nil
    )

    #expect(body.length == Int64(content.count))
    #expect(server.requests.first?.body == content)
}
