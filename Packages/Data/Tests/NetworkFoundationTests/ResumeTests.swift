import Foundation
import NetworkCore
import Testing
import os

@testable import NetworkFoundation

private struct Workspace {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func client(retry: RetryPolicy = .none) -> HTTPClient {
        HTTPClient(
            transport: URLSessionTransport(
                session: URLSession(configuration: .ephemeral),
                downloadDirectory: directory
            ),
            retry: retry,
            environment: HTTPClient.Environment(sleep: { _ in })
        )
    }
}

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
}

/// What a server that supports ranges says: the whole thing, or the part asked for when the condition
/// matches, or that the range is beyond the end.
private func ranged(_ request: ServerRequest, content: Data, etag: String) -> ServerReply {
    let validators = [("ETag", etag), ("Accept-Ranges", "bytes")]
    guard let range = request.headers["range"], range.hasPrefix("bytes="),
        let start = Int(range.dropFirst(6).split(separator: "-").first ?? ""),
        request.headers["if-range"] == nil || request.headers["if-range"] == etag
    else {
        var whole = ServerReply(200, headers: validators)
        whole.body = content
        return whole
    }

    guard start < content.count else {
        return ServerReply(416, headers: [("Content-Range", "bytes */\(content.count)")])
    }

    var part = ServerReply(
        206,
        headers: validators + [
            ("Content-Range", "bytes \(start)-\(content.count - 1)/\(content.count)")
        ]
    )
    part.body = content.suffix(from: start)
    return part
}

/// A reply that breaks off: it announces all of `content` and sends `sent` bytes of it.
private func brokenOff(content: Data, sent: Int, etag: String) -> ServerReply {
    var reply = ServerReply(200, headers: [("ETag", etag), ("Accept-Ranges", "bytes")])
    reply.body = content.prefix(sent)
    reply.announcedLength = content.count
    return reply
}

private final class Calls: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func aDownloadThatBrokeOffKeepsItsBytesAndTheNextCallAsksForTheRest() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(1024 * 1024)
    let calls = Calls()
    let server = try await LocalServer.start { request in
        calls.next() == 1
            ? brokenOff(content: content, sent: 400 * 1024, etag: "\"v1\"")
            : ranged(request, content: content, etag: "\"v1\"")
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    let destination = workspace.file("big.bin")
    let client = workspace.client()

    do {
        _ = try await client.download(
            HTTPRequest(.get, server.url("/big")),
            to: destination,
            continuing: partial
        )
        Issue.record("a download that broke off was accepted")
    } catch {}
    let kept = partial.size
    #expect(kept > 0 && kept <= 400 * 1024, "what had arrived stayed: \(kept)")
    #expect(partial.validators()?.etag == "\"v1\"")
    #expect(!FileManager.default.fileExists(atPath: destination.path))

    let download = try await client.download(
        HTTPRequest(.get, server.url("/big")),
        to: destination,
        continuing: partial
    )

    let second = try #require(server.requests.last)
    #expect(second.headers["range"] == "bytes=\(kept)-")
    #expect(second.headers["if-range"] == "\"v1\"")
    #expect(download.response.status == 206)
    #expect(download.file == destination)
    #expect(download.bytes == content.count)
    #expect(try Data(contentsOf: destination) == content)
    #expect(!FileManager.default.fileExists(atPath: partial.file.path), "the file was moved")
    #expect(!FileManager.default.fileExists(atPath: partial.validatorsFile.path))
}

@Test(.timeLimit(.minutes(1)))
func aRetryInsideOneCallContinuesWhereTheConnectionBrokeOff() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(1024 * 1024)
    let calls = Calls()
    let server = try await LocalServer.start { request in
        calls.next() == 1
            ? brokenOff(content: content, sent: 300 * 1024, etag: "\"v1\"")
            : ranged(request, content: content, etag: "\"v1\"")
    }
    defer { server.stop() }
    var retry = RetryPolicy(maxAttempts: 3)
    retry.transportFailures = [.timedOut, .connectionLost, .other, .cannotConnect]
    let destination = workspace.file("big.bin")

    let download = try await workspace.client(retry: retry).download(
        HTTPRequest(.get, server.url("/big")),
        to: destination,
        continuing: PartialDownload(file: workspace.file("big.part"))
    )

    #expect(try Data(contentsOf: destination) == content)
    #expect(server.requests.count == 2)
    #expect(server.requests[0].headers["range"] == nil)
    #expect(server.requests[1].headers["range"] != nil, "the second try asked for the rest only")
    #expect(download.bytes == content.count)
}

@Test(.timeLimit(.minutes(1)))
func aThingThatChangedStartsOverAndIsNeverAMixtureOfTwoVersions() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let old = pattern(200 * 1024)
    let changed = Data(pattern(300 * 1024).reversed())
    let server = try await LocalServer.start { request in
        ranged(request, content: changed, etag: "\"v2\"")
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    try old.prefix(100 * 1024).write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))
    let destination = workspace.file("big.bin")

    let download = try await workspace.client().download(
        HTTPRequest(.get, server.url("/big")),
        to: destination,
        continuing: partial
    )

    #expect(server.requests.first?.headers["if-range"] == "\"v1\"")
    #expect(download.response.status == 200, "the server sent the whole of the new thing")
    #expect(try Data(contentsOf: destination) == changed)
}

@Test(.timeLimit(.minutes(1)))
func bytesWithoutARecordAreNotContinuedBecauseNothingSaysWhatTheyAre() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(100 * 1024)
    let server = try await LocalServer.start { request in
        ranged(request, content: content, etag: "\"v1\"")
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    try Data("unknown bytes".utf8).write(to: partial.file)
    let destination = workspace.file("big.bin")

    _ = try await workspace.client().download(
        HTTPRequest(.get, server.url("/big")),
        to: destination,
        continuing: partial
    )

    #expect(server.requests.first?.headers["range"] == nil)
    #expect(try Data(contentsOf: destination) == content)
}

@Test(.timeLimit(.minutes(1)))
func aFileThatIsAlreadyWholeIsTakenForTheThingWhenTheServerSaysTheRangeIsBeyondTheEnd() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(64 * 1024)
    let server = try await LocalServer.start { request in
        ranged(request, content: content, etag: "\"v1\"")
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    try content.write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))
    let destination = workspace.file("big.bin")

    let download = try await workspace.client().download(
        HTTPRequest(.get, server.url("/big")),
        to: destination,
        continuing: partial
    )

    #expect(download.response.status == 416)
    #expect(download.file == destination)
    #expect(try Data(contentsOf: destination) == content)
    #expect(server.requests.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aFileBiggerThanTheThingIsDiscardedAndTheDownloadIsMadeAgainWhole() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(32 * 1024)
    let server = try await LocalServer.start { request in
        ranged(request, content: content, etag: "\"v1\"")
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    try pattern(100 * 1024).write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))
    let destination = workspace.file("big.bin")

    _ = try await workspace.client().download(
        HTTPRequest(.get, server.url("/big")),
        to: destination,
        continuing: partial
    )

    #expect(server.requests.count == 2)
    #expect(server.requests[1].headers["range"] == nil, "the second request is for the whole")
    #expect(try Data(contentsOf: destination) == content)
}

@Test(.timeLimit(.minutes(1)))
func aPartThatDoesNotFollowTheFileIsRefusedAndTheFileIsLeftAsItWas() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let server = try await LocalServer.start { _ in
        // A server that answers a range with another range.
        var reply = ServerReply(206, headers: [("Content-Range", "bytes 0-9/100"), ("ETag", "\"v1\"")])
        reply.body = Data(repeating: 1, count: 10)
        return reply
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    let before = pattern(50)
    try before.write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))

    do {
        _ = try await workspace.client().download(
            HTTPRequest(.get, server.url("/big")),
            to: workspace.file("big.bin"),
            continuing: partial
        )
        Issue.record("a part that does not follow the file was accepted")
    } catch {
        guard case .status(let response) = error else {
            Issue.record("expected status, got \(error)")
            return
        }
        #expect(response.status == 206)
    }
    #expect(try Data(contentsOf: partial.file) == before)
}

@Test(.timeLimit(.minutes(1)))
func theLimitIsForTheWholeFileAndAnOverlongOneIsDiscarded() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(300 * 1024)
    let server = try await LocalServer.start { request in
        ranged(request, content: content, etag: "\"v1\"")
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    try content.prefix(200 * 1024).write(to: partial.file)
    partial.store(HTTPValidators(etag: "\"v1\""))

    do {
        _ = try await workspace.client().download(
            HTTPRequest(.get, server.url("/big")),
            to: workspace.file("big.bin"),
            maxBytes: 250 * 1024,
            continuing: partial
        )
        Issue.record("a file over the limit was accepted")
    } catch {
        guard case .responseTooLarge = error else {
            Issue.record("expected responseTooLarge, got \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: partial.file.path))
    #expect(!FileManager.default.fileExists(atPath: partial.validatorsFile.path))
}

@Test(.timeLimit(.minutes(1)))
func aCancelledContinuationKeepsWhatItHad() async throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let content = pattern(1024 * 1024)
    let server = try await LocalServer.start { _ in
        var reply = brokenOff(content: content, sent: 100 * 1024, etag: "\"v1\"")
        reply.keepOpen = .seconds(30)
        return reply
    }
    defer { server.stop() }
    let partial = PartialDownload(file: workspace.file("big.part"))
    let client = workspace.client()

    let task = Task {
        try await client.download(
            HTTPRequest(.get, server.url("/big")),
            to: workspace.file("big.bin"),
            continuing: partial
        )
    }
    var started = false
    for _ in 0..<200 where !started {
        try await Task.sleep(for: .milliseconds(25))
        started = partial.size > 0
    }
    #expect(started)
    task.cancel()
    _ = try? await task.value

    #expect(partial.size > 0, "the bytes that came stay for the next try")
    #expect(partial.validators()?.etag == "\"v1\"")
}
