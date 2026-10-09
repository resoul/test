import Foundation
import NetworkCore
import Testing
import os

@testable import NetworkFoundation

/// Tests that go through the system's daemon. One background session for the whole run. The system keeps a session for an identifier until it
/// is told otherwise, and a transfer that was left behind (a server that went away, a test that
/// failed) stays with it for days, so a session named anew for every test would pile them up and
/// slow the system's daemon for all that come after. Tests share this one, tell their transfers
/// apart by name, and the first use clears what an earlier run left.
private enum Shared {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("background-tests-shared", isDirectory: true)
    static let transfers = URLSessionBackgroundTransfers(
        identifier: "tests.background.shared",
        directory: directory
    )
    private static let cleared = Task { await clear(transfers, directory: directory) }

    static func ready() async -> URLSessionBackgroundTransfers {
        await cleared.value
        return transfers
    }

    /// Cancels what is left of earlier runs and forgets their outcomes.
    static func clear(_ transfers: URLSessionBackgroundTransfers, directory: URL) async {
        for transfer in await transfers.transfers() { await transfers.cancel(transfer.id) }
        while !(await transfers.transfers().isEmpty) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A destination no other test uses, inside the shared directory.
    static func path(_ name: String) -> String { UUID().uuidString + "/" + name }

    static func url(_ path: String) -> URL { directory.appendingPathComponent(path) }
}

/// A session of its own, with the identifier fixed so that a later run can find what this one left.
private func dedicated(
    _ name: String,
    timeout: TimeInterval? = nil,
    maxReplyBytes: Int = 1024 * 1024
) async throws -> URLSessionBackgroundTransfers {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("background-tests-" + name, isDirectory: true)
    let transfers = URLSessionBackgroundTransfers(
        identifier: "tests.background." + name,
        directory: directory,
        timeout: timeout,
        maxReplyBytes: maxReplyBytes
    )
    await Shared.clear(transfers, directory: directory)
    return transfers
}

/// A folder for the files a test makes for itself.
private struct Workspace {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
}

/// The outcome of transfer `id` as `transfers` gives it, or `nil` when none comes within `seconds`.
/// The outcome is acknowledged, so that it does not wait for the next run.
private func outcome(
    of id: BackgroundTransferID,
    from transfers: some BackgroundTransfers,
    within seconds: Double = 45,
    acknowledging: Bool = true
) async -> BackgroundTransferOutcome? {
    let found = await withTaskGroup(of: BackgroundTransferOutcome?.self) { group in
        group.addTask {
            for await outcome in transfers.outcomes() where outcome.id == id { return outcome }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    if acknowledging, found != nil { await transfers.acknowledge(id) }
    return found
}

@Suite(.serialized)
struct BackgroundSystemTests {
    @Test(.timeLimit(.minutes(2)))
    func aBackgroundDownloadPutsTheFileInPlaceAndReportsTheAnswer() async throws {
        let transfers = await Shared.ready()
        let content = pattern(1024 * 1024)
        let server = try await LocalServer.start { _ in
            var reply = ServerReply(200, headers: [("X-Version", "7")])
            reply.body = content
            return reply
        }
        defer { server.stop() }
        let path = Shared.path("big.bin")

        let id = try await transfers.download(HTTPRequest(.get, server.url("/big")), to: path)

        let outcome = try #require(await outcome(of: id, from: transfers))
        #expect(outcome.kind == .download)
        #expect(outcome.status == 200)
        #expect(outcome.headers["X-Version"] == "7")
        #expect(outcome.isSuccess)
        #expect(outcome.failure == nil)
        #expect(outcome.body.isEmpty, "the content is in the file")
        let file = try #require(outcome.file)
        #expect(file.standardizedFileURL.path == Shared.url(path).standardizedFileURL.path)
        #expect(try Data(contentsOf: file) == content)
        #expect(await transfers.transfers().contains { $0.id == id } == false)
    }

    @Test(.timeLimit(.minutes(2)))
    func aRefusedDownloadWritesNoFileAndKeepsTheReason() async throws {
        let transfers = await Shared.ready()
        let server = try await LocalServer.start { _ in ServerReply(404, "no such thing") }
        defer { server.stop() }
        let path = Shared.path("gone.bin")

        let id = try await transfers.download(HTTPRequest(.get, server.url("/gone")), to: path)

        let outcome = try #require(await outcome(of: id, from: transfers))
        #expect(outcome.status == 404)
        #expect(!outcome.isSuccess)
        #expect(outcome.failure == nil, "the server did answer")
        #expect(outcome.file == nil)
        #expect(String(decoding: outcome.body, as: UTF8.self) == "no such thing")
        #expect(!FileManager.default.fileExists(atPath: Shared.url(path).path))
    }

    @Test(.timeLimit(.minutes(2)))
    func aDownloadWhoseServerIsGoneKeepsTryingUntilTheTimeIsUp() async throws {
        let transfers = try await dedicated("timeout", timeout: 3)
        let server = try await LocalServer.start { _ in ServerReply() }
        let url = server.url("/")
        server.stop()
        try await Task.sleep(for: .milliseconds(100))

        let id = try await transfers.download(HTTPRequest(.get, url), to: "x.bin")

        // The refused connection does not end it at once: the system waits for the server to come back.
        let started = ContinuousClock.now
        let outcome = try #require(await outcome(of: id, from: transfers, within: 30))
        #expect(ContinuousClock.now - started > .seconds(1.5))
        #expect(outcome.status == nil)
        #expect(!outcome.isSuccess)
        #expect(outcome.failure != nil)
        #expect(outcome.file == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func aBackgroundUploadSendsTheFileAndKeepsTheReply() async throws {
        let transfers = await Shared.ready()
        let workspace = try Workspace()
        defer { workspace.remove() }
        let content = pattern(200_000)
        try content.write(to: workspace.file("payload.bin"))
        let server = try await LocalServer.start { request in
            ServerReply(201, "got \(request.body.count) of \(request.method)")
        }
        defer { server.stop() }

        let id = try await transfers.upload(
            HTTPRequest(.post, server.url("/up"), headers: ["X-Token": "abc"]),
            fromFile: workspace.file("payload.bin")
        )

        let outcome = try #require(await outcome(of: id, from: transfers))
        #expect(outcome.kind == .upload)
        #expect(outcome.status == 201)
        #expect(String(decoding: outcome.body, as: UTF8.self) == "got 200000 of POST")
        #expect(outcome.file == nil)
        #expect(server.requests.first?.body == content)
        #expect(server.requests.first?.headers["x-token"] == "abc")
    }

    @Test(.timeLimit(.minutes(2)))
    func aTransferScheduledTwiceUnderOneNameRunsOnce() async throws {
        let transfers = await Shared.ready()
        let server = try await LocalServer.start { _ in ServerReply(200, "once", delay: .seconds(1))
        }
        defer { server.stop() }
        let request = HTTPRequest(.get, server.url("/"))
        let path = Shared.path("a.bin")
        let id = BackgroundTransferID.unique()

        async let first = transfers.download(request, to: path, id: id)
        async let second = transfers.download(request, to: path, id: id)
        _ = try await (first, second)
        #expect(await transfers.transfers().filter { $0.id == id }.count == 1)
        _ = try #require(await outcome(of: id, from: transfers, acknowledging: false))
        #expect(server.requests.count == 1)

        // The outcome is not acknowledged yet: asking again does not repeat the transfer.
        try await transfers.download(request, to: path, id: id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.requests.count == 1)

        // Once it is acknowledged the name is free.
        await transfers.acknowledge(id)
        try await transfers.download(request, to: path, id: id)
        _ = try #require(await outcome(of: id, from: transfers))
        #expect(server.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(2)))
    func cancellingATransferEndsItWithACancelledOutcome() async throws {
        let transfers = await Shared.ready()
        let server = try await LocalServer.start { _ in
            ServerReply(200, "late", delay: .seconds(30))
        }
        defer { server.stop() }
        let path = Shared.path("late.bin")
        let id = try await transfers.download(HTTPRequest(.get, server.url("/")), to: path)
        while await transfers.transfers().filter({ $0.id == id }).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        await transfers.cancel(id)

        let outcome = try #require(await outcome(of: id, from: transfers))
        #expect(outcome.failure?.kind == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: Shared.url(path).path))
    }

    @Test(.timeLimit(.minutes(2)))
    func theProgressOfARunningDownloadIsReported() async throws {
        let transfers = await Shared.ready()
        let content = pattern(8 * 1024 * 1024)
        let server = try await LocalServer.start { _ in
            var reply = ServerReply(200)
            reply.body = content
            return reply
        }
        defer { server.stop() }
        let progress = transfers.progress()

        let id = try await transfers.download(
            HTTPRequest(.get, server.url("/")),
            to: Shared.path("p.bin")
        )

        _ = try #require(await outcome(of: id, from: transfers))
        var iterator = progress.makeAsyncIterator()
        var last: BackgroundTransferProgress?
        // The sequence also carries other tests' transfers; the last of this one is the one to read.
        while let next = await iterator.next() {
            if next.id == id { last = next }
            if next.id == id, next.total == Int64(content.count), next.completed > 0 { break }
        }
        #expect(last?.completed ?? 0 > 0)
        #expect(last?.total == Int64(content.count))
    }

    @Test(.timeLimit(.minutes(2)))
    func theClientSignsABackgroundDownloadWithItsCredentialsAndDefaultHeaders() async throws {
        let transfers = await Shared.ready()
        let server = try await LocalServer.start { _ in ServerReply(200, "signed") }
        defer { server.stop() }
        let origin = try #require(HTTPOrigin(server.url("/")))
        let client = HTTPClient(
            transport: URLSessionTransport(),
            defaultHeaders: ["X-App": "demo"],
            authorizer: TokenAuthorizer(origin: origin, token: { "secret" }, refresh: {})
        )

        let id = try await client.download(
            HTTPRequest(.get, server.url("/")),
            inBackground: transfers,
            to: Shared.path("s.bin")
        )

        #expect(try #require(await outcome(of: id, from: transfers)).isSuccess)
        let request = try #require(server.requests.first)
        #expect(request.headers["authorization"] == "Bearer secret")
        #expect(request.headers["x-app"] == "demo")
    }

    @Test(.timeLimit(.minutes(2)))
    func aRedirectToAnotherOriginDoesNotCarryTheCredentials() async throws {
        let transfers = await Shared.ready()
        let target = try await LocalServer.start { _ in ServerReply(200, "elsewhere") }
        defer { target.stop() }
        let origin = try await LocalServer.start { _ in
            ServerReply(302, headers: [("Location", target.url("/final").absoluteString)])
        }
        defer { origin.stop() }

        let id = try await transfers.download(
            HTTPRequest(.get, origin.url("/start"), headers: ["Authorization": "Bearer secret"]),
            to: Shared.path("r.bin")
        )

        let outcome = try #require(await outcome(of: id, from: transfers))
        #expect(outcome.isSuccess)
        #expect(origin.requests.first?.headers["authorization"] == "Bearer secret")
        #expect(target.requests.first?.headers["authorization"] == nil)
    }
}
