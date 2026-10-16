import Foundation
import NetworkCore
import StorageCore

/// Why a download into a file store failed: the request, or the store.
public enum DownloadError: Error, Sendable {
    /// The request failed or was refused; nothing was put in the store.
    case http(HTTPError)
    /// The answer was fine but the store could not take the file. The store keeps whatever it had
    /// at the path.
    case file(FileError)
}

/// The outcome of ``HTTPClient/download(_:into:at:expecting:maxBytes:temporaryDirectory:)``.
public struct StoredDownload: Sendable {
    /// The answer, with an empty body when a file was stored.
    public var response: HTTPResponse
    /// Where the file is in the store; `nil` when the answer was accepted but is not a `2xx`
    /// (a `404` taken as an answer, say), which has no file. The store is untouched then.
    public var path: FilePath?
    /// How many bytes were stored.
    public var bytes: Int

    public init(response: HTTPResponse, path: FilePath?, bytes: Int) {
        self.response = response
        self.path = path
        self.bytes = bytes
    }
}

extension HTTPClient {
    /// Downloads the answer to `request` into `store` at `path`.
    ///
    /// The body is written to a temporary file as it arrives, not held in memory, and copied into
    /// the store once the answer is accepted, so the store's own guarantees apply to it: the file
    /// appears whole or not at all, an existing file at `path` is replaced only by a complete
    /// copy, and the store's size limit is enforced. The temporary file is removed whatever
    /// happens. Statuses, retries and credentials are those of ``send(_:expecting:)``.
    ///
    /// Cancelling the task cancels the request while it runs and the copy while it copies; after
    /// the copy has replaced the file at `path`, cancellation undoes nothing.
    ///
    /// - Parameters:
    ///   - maxBytes: The most body bytes to accept; `nil` for no limit. See
    ///     ``HTTPClient/download(_:to:expecting:maxBytes:)``.
    ///   - temporaryDirectory: Where the file waits before it is copied; it must exist and have
    ///     room for the whole body.
    /// - Throws: ``DownloadError/http(_:)`` for anything the request does wrong,
    ///   ``DownloadError/file(_:)`` when the store refuses the file.
    public func download(
        _ request: HTTPRequest,
        into store: some FileStore,
        at path: FilePath,
        expecting statuses: HTTPStatuses = .success,
        maxBytes: Int? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws(DownloadError) -> StoredDownload {
        let staging = temporaryDirectory.appendingPathComponent("download-" + UUID().uuidString)
        let result: HTTPDownload
        do {
            result = try await download(request, to: staging, expecting: statuses, maxBytes: maxBytes)
        } catch {
            throw .http(error)
        }
        guard result.file != nil else {
            return StoredDownload(response: result.response, path: nil, bytes: 0)
        }

        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try await store.importFile(at: staging, to: path)
        } catch {
            throw .file(error)
        }
        return StoredDownload(response: result.response, path: path, bytes: result.bytes)
    }
}
