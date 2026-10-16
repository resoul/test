import Foundation
import NetworkCore
import NetworkStorage
import StorageCore
import StorageFoundation
import Testing

/// A transport that answers every request with one response, as a server would.
private struct CannedTransport: HTTPTransport {
    var status = 200
    var body = Data()

    func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        HTTPResponse(status: status, body: body, url: request.url)
    }
}

private let url = URL(string: "https://files.example.com/report.pdf")!

private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-storage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test
func aDownloadLandsInTheStoreAndTheStagingFileIsGone() async throws {
    let staging = try directory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let store = MemoryFileStore()
    let client = HTTPClient(transport: CannedTransport(body: Data("pdf bytes".utf8)))

    let stored = try await client.download(
        HTTPRequest(.get, url),
        into: store,
        at: try FilePath("reports/report.pdf"),
        temporaryDirectory: staging
    )

    #expect(stored.path == (try FilePath("reports/report.pdf")))
    #expect(stored.bytes == 9)
    #expect(stored.response.body.isEmpty)
    #expect(try await store.read(try FilePath("reports/report.pdf")) == Data("pdf bytes".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test
func aRefusedAnswerTouchesNeitherTheStoreNorTheStagingDirectory() async throws {
    let staging = try directory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let store = MemoryFileStore()
    let path = try FilePath("report.pdf")
    try await store.write(Data("old".utf8), to: path)
    let client = HTTPClient(transport: CannedTransport(status: 404, body: Data("gone".utf8)))

    do {
        _ = try await client.download(
            HTTPRequest(.get, url),
            into: store,
            at: path,
            temporaryDirectory: staging
        )
        Issue.record("a 404 was accepted")
    } catch {
        guard case .http(.status(let response)) = error else {
            Issue.record("expected an HTTP status error, got \(error)")
            return
        }
        #expect(response.status == 404)
    }
    #expect(try await store.read(path) == Data("old".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test
func anAcceptedAnswerWithoutAFileLeavesTheStoreAlone() async throws {
    let staging = try directory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let store = MemoryFileStore()
    let path = try FilePath("report.pdf")
    let client = HTTPClient(transport: CannedTransport(status: 404, body: Data("gone".utf8)))

    let stored = try await client.download(
        HTTPRequest(.get, url),
        into: store,
        at: path,
        expecting: .success(or: 404),
        temporaryDirectory: staging
    )

    #expect(stored.path == nil)
    #expect(stored.response.status == 404)
    #expect(try await store.metadata(of: path) == nil)
}

@Test
func aStoreThatRefusesTheFileIsAFileErrorAndKeepsTheOldFile() async throws {
    let staging = try directory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    // A store that takes files of ten bytes at most.
    let store = DiskFileStore(root: root, maxFileSize: 10)
    let path = try FilePath("report.pdf")
    try await store.write(Data("old".utf8), to: path)
    let client = HTTPClient(
        transport: CannedTransport(body: Data(repeating: 7, count: 100))
    )

    do {
        _ = try await client.download(
            HTTPRequest(.get, url),
            into: store,
            at: path,
            temporaryDirectory: staging
        )
        Issue.record("a file over the limit was stored")
    } catch {
        guard case .file(.tooLarge) = error else {
            Issue.record("expected a file error, got \(error)")
            return
        }
    }
    #expect(try await store.read(path) == Data("old".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test
func aDownloadIntoADiskStoreReplacesTheOldFileWhole() async throws {
    let staging = try directory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DiskFileStore(root: root)
    let path = try FilePath("a/b/report.pdf")
    try await store.write(Data("old".utf8), to: path)
    let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
    let client = HTTPClient(transport: CannedTransport(body: content))

    _ = try await client.download(
        HTTPRequest(.get, url),
        into: store,
        at: path,
        temporaryDirectory: staging
    )

    #expect(try await store.read(path) == content)
}
