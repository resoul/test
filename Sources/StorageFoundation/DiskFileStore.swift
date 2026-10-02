import Foundation
import StorageCore
import os

/// A ``FileStore`` over a directory on disk.
///
/// The store owns its root: it creates it when the first file is written, and every path stays
/// below it. Paths cannot climb out (see ``FilePath``), and a name under the root that is a
/// symbolic link is refused with ``FileError/outsideRoot(_:)`` instead of being followed. The
/// check is made when an operation starts; it does not defend against another process that
/// swaps a directory for a link while the operation runs, so keep the root private to the app.
///
/// All disk work runs on one serial utility queue per store, never on the caller's thread, so
/// calls on one store happen one after another; a long copy delays the calls queued behind it.
/// Use separate stores — documents, caches — for work that should not wait for each other.
///
/// A file is written to a temporary file next to its destination and then moved into place, so a
/// failed or cancelled write leaves the previous content. The move is atomic on the volume;
/// that does not promise the content survives a power loss. A crash can leave temporary files
/// behind; ``removeLeftoverTemporaryFiles()`` clears them.
///
/// A store keeps no state besides its root, so values with the same root work on the same
/// files, but they do not share a queue: two of them can write the same path at once, and the
/// last move wins.
public struct DiskFileStore: FileStore {
    /// Where a store's root usually lives. The app picks one when it assembles its stores.
    public enum Location: Sendable {
        /// Data the app needs and the user did not create; backed up, hidden from the user.
        case applicationSupport
        /// Files the user may see and share. Not available for lasting storage on tvOS.
        case documents
        /// Data that can be rebuilt; the system may delete it when space is short.
        case caches
        /// Short-lived files; the system may delete them at any time.
        case temporary
    }

    private let root: URL
    private let maxFileSize: Int64?
    private let worker = FileWorker()
    let chunkSize: Int

    /// Creates a store over `root`. The directory does not have to exist yet.
    ///
    /// - Parameters:
    ///   - root: The directory the store owns. Nothing outside it is touched.
    ///   - maxFileSize: The largest file the store reads or writes, in bytes; `nil` for no limit.
    public init(root: URL, maxFileSize: Int64? = nil) {
        self.init(root: root, maxFileSize: maxFileSize, chunkSize: 1 << 20)
    }

    init(root: URL, maxFileSize: Int64?, chunkSize: Int) {
        self.root = root
        self.maxFileSize = maxFileSize
        self.chunkSize = chunkSize
    }

    /// Creates a store in the system directory for `location`, inside `subdirectory`.
    ///
    /// - Throws: ``FileError/invalidPath(_:)`` for an unacceptable `subdirectory`, or
    ///   ``FileError/failed(path:reason:)`` when the system cannot give the directory.
    public init(location: Location, subdirectory: String, maxFileSize: Int64? = nil)
        throws(FileError)
    {
        let base: URL
        do {
            switch location {
            case .applicationSupport:
                base = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
            case .documents:
                base = try FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
            case .caches:
                base = try FileManager.default.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
            case .temporary:
                base = FileManager.default.temporaryDirectory
            }
        } catch {
            throw FileError(error, path: nil)
        }
        let path = try FilePath(subdirectory)
        self.init(
            root: base.appendingPathComponent(path.description, isDirectory: true),
            maxFileSize: maxFileSize
        )
    }

    public func read(_ path: FilePath) async throws(FileError) -> Data {
        let (root, limit) = (root, maxFileSize)
        return try await worker.run { cancellation throws(FileError) in
            let url = try Disk.resolve(path, in: root)
            guard let attributes = try Disk.attributes(of: url, path: path) else {
                throw .notFound(path)
            }
            if Disk.isDirectory(attributes) { throw .wrongKind(path) }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let limit, size > limit { throw .tooLarge(path, limit: limit) }
            try cancellation.check()
            return try Disk.attempt(path) { try Data(contentsOf: url) }
        }
    }

    public func write(_ data: Data, to path: FilePath) async throws(FileError) {
        let (root, limit) = (root, maxFileSize)
        try await worker.run { cancellation throws(FileError) in
            if let limit, Int64(data.count) > limit { throw .tooLarge(path, limit: limit) }
            try Disk.stage(path, in: root, cancellation: cancellation) {
                temporary throws(FileError) in
                try Disk.attempt(path) {
                    try data.write(to: temporary, options: .withoutOverwriting)
                }
            }
        }
    }

    /// Copies a file of the store to another path, a chunk at a time, so the file is never held
    /// in memory whole. An existing file at `destination` is replaced when the copy is done.
    ///
    /// - Throws: ``FileError/notFound(_:)`` when `source` is missing, ``FileError/wrongKind(_:)``
    ///   for a directory, ``FileError/tooLarge(_:limit:)``, and the errors of ``write(_:to:)``.
    ///   Cancelling stops between chunks and removes the partial copy.
    public func copy(_ source: FilePath, to destination: FilePath) async throws(FileError) {
        let (root, limit, chunk) = (root, maxFileSize, chunkSize)
        try await worker.run { cancellation throws(FileError) in
            let sourceURL = try Disk.resolve(source, in: root)
            guard let attributes = try Disk.attributes(of: sourceURL, path: source) else {
                throw .notFound(source)
            }
            if Disk.isDirectory(attributes) { throw .wrongKind(source) }
            try Disk.stage(destination, in: root, cancellation: cancellation) {
                temporary throws(FileError) in
                try Disk.copyChunks(
                    from: sourceURL,
                    to: temporary,
                    path: destination,
                    limit: limit,
                    chunkSize: chunk,
                    cancellation: cancellation
                )
            }
        }
    }

    /// Copies a file from outside the store into it, a chunk at a time. Use it to take in a file
    /// the user picked or a finished download; the original is left where it is.
    ///
    /// - Parameters:
    ///   - url: The file to copy. It is read only, and a symbolic link is followed.
    ///   - path: Where the copy goes; an existing file there is replaced when the copy is done.
    /// - Throws: The errors of ``copy(_:to:)``; a missing `url` is ``FileError/failed(path:reason:)``.
    public func importFile(at url: URL, to path: FilePath) async throws(FileError) {
        let (root, limit, chunk) = (root, maxFileSize, chunkSize)
        try await worker.run { cancellation throws(FileError) in
            try Disk.stage(path, in: root, cancellation: cancellation) {
                temporary throws(FileError) in
                try Disk.copyChunks(
                    from: url,
                    to: temporary,
                    path: path,
                    limit: limit,
                    chunkSize: chunk,
                    cancellation: cancellation
                )
            }
        }
    }

    public func metadata(of path: FilePath) async throws(FileError) -> FileMetadata? {
        let root = root
        return try await worker.run { _ throws(FileError) in
            let url = try Disk.resolve(path, in: root)
            return try Disk.attributes(of: url, path: path).map(Disk.metadata)
        }
    }

    public func list(_ directory: FilePath?) async throws(FileError) -> [FileEntry] {
        let root = root
        return try await worker.run { cancellation throws(FileError) in
            let url: URL
            if let directory { url = try Disk.resolve(directory, in: root) } else { url = root }
            guard let attributes = try Disk.attributes(of: url, path: directory) else {
                return []
            }
            if !Disk.isDirectory(attributes) {
                if let directory { throw .wrongKind(directory) }
                throw .failed(path: nil, reason: "the store's root is not a directory")
            }

            let names = try Disk.attempt(directory) {
                try FileManager.default.contentsOfDirectory(atPath: url.path)
            }
            var entries: [FileEntry] = []
            for name in names where !name.hasPrefix(".") {
                try cancellation.check()
                guard let path = try? directory?.appending(name) ?? FilePath(name),
                    let childAttributes = try Disk.attributes(
                        of: url.appendingPathComponent(name),
                        path: path
                    ),
                    // A link is not addressable, so it is not listed.
                    childAttributes[.type] as? FileAttributeType != .typeSymbolicLink
                else { continue }

                entries.append(FileEntry(path: path, metadata: Disk.metadata(childAttributes)))
            }
            return entries.sorted { $0.path < $1.path }
        }
    }

    @discardableResult
    public func remove(_ path: FilePath) async throws(FileError) -> Bool {
        let root = root
        return try await worker.run { _ throws(FileError) in
            let url = try Disk.resolve(path, in: root)
            guard try Disk.attributes(of: url, path: path) != nil else { return false }

            try Disk.attempt(path) { try FileManager.default.removeItem(at: url) }
            return true
        }
    }

    public func move(_ source: FilePath, to destination: FilePath, replacing: Bool)
        async throws(FileError)
    {
        let root = root
        try await worker.run { _ throws(FileError) in
            let sourceURL = try Disk.resolve(source, in: root)
            let destinationURL = try Disk.resolve(destination, in: root)
            guard let sourceAttributes = try Disk.attributes(of: sourceURL, path: source) else {
                throw .notFound(source)
            }
            if destination == source || destination.components.starts(with: source.components) {
                throw .invalidPath("\(source) cannot be moved into itself")
            }
            let destinationAttributes = try Disk.attributes(of: destinationURL, path: destination)
            if let destinationAttributes {
                guard replacing else { throw .alreadyExists(destination) }
                // Replacing one kind by the other would delete a whole directory or hide a file.
                guard
                    Disk.isDirectory(destinationAttributes) == Disk.isDirectory(sourceAttributes)
                else { throw .wrongKind(destination) }
            }
            try Disk.prepareParent(of: destinationURL, path: destination)
            try Disk.attempt(destination) {
                if destinationAttributes != nil {
                    _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: sourceURL)
                } else {
                    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                }
            }
        }
    }

    /// The location of a file on disk, for handing to a system API that needs a URL, such as a
    /// player or an image loader. Read from it; do not write to it or keep it as the file's
    /// identity: the file can be replaced or removed at any time, and the path is the identity.
    ///
    /// - Throws: ``FileError/outsideRoot(_:)`` when a name on the way is a symbolic link. A
    ///   missing file is not an error: the URL is where the file would be.
    public func url(for path: FilePath) throws(FileError) -> URL {
        try Disk.resolve(path, in: root)
    }

    /// Removes temporary files that a write left behind when it was cut short by a crash.
    ///
    /// Call it once when the app starts, before the store is used: a temporary file of a write
    /// that is still running, in this store or another with the same root, would be removed too.
    ///
    /// - Returns: How many files were removed.
    @discardableResult
    public func removeLeftoverTemporaryFiles() async throws(FileError) -> Int {
        let root = root
        return try await worker.run { cancellation throws(FileError) in
            guard
                let walker = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil
                )
            else { return 0 }

            var removed = 0
            for case let url as URL in walker where Disk.isTemporary(url) {
                try cancellation.check()
                if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
            }
            return removed
        }
    }
}

/// Runs blocking file work on a serial queue and gives the awaiting task back its result.
private struct FileWorker: Sendable {
    private let queue = DispatchQueue(label: "DiskFileStore", qos: .utility)

    /// Runs `work` on the queue. Cancelling the task raises the flag that `work` checks between
    /// steps; work that has not started yet does not start. The flag is read by the queue's
    /// thread and written by the cancelling one, hence the lock.
    func run<Result: Sendable>(
        _ work: @escaping @Sendable (Cancellation) throws(FileError) -> Result
    ) async throws(FileError) -> Result {
        let cancellation = Cancellation()
        let outcome: Swift.Result<Result, FileError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(
                        returning: Swift.Result(catching: { () throws(FileError) in
                            try cancellation.check()
                            return try work(cancellation)
                        })
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try outcome.get()
    }
}

/// The cancellation flag of one operation, shared between the awaiting task and the queue.
struct Cancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    func cancel() { flag.withLock { $0 = true } }

    var isCancelled: Bool { flag.withLock { $0 } }

    func check() throws(FileError) {
        if isCancelled { throw .cancelled }
    }
}

/// The blocking work of a store, as functions of a root so that they run on the queue without
/// holding the store.
private enum Disk {
    static func attempt<Value>(_ path: FilePath?, _ body: () throws -> Value) throws(FileError)
        -> Value
    {
        do {
            return try body()
        } catch {
            throw FileError(error, path: path)
        }
    }

    /// The file's attributes without following a link, or `nil` when nothing is there.
    static func attributes(of url: URL, path: FilePath?) throws(FileError)
        -> [FileAttributeKey: Any]?
    {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        {
            return nil
        } catch {
            throw FileError(error, path: path)
        }
    }

    static func isDirectory(_ attributes: [FileAttributeKey: Any]) -> Bool {
        attributes[.type] as? FileAttributeType == .typeDirectory
    }

    static func metadata(_ attributes: [FileAttributeKey: Any]) -> FileMetadata {
        let isDirectory = isDirectory(attributes)
        return FileMetadata(
            isDirectory: isDirectory,
            size: isDirectory ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    /// The URL of `path` under `root`, after checking that no existing name on the way is a
    /// symbolic link. The root itself may be one: the app chose it.
    static func resolve(_ path: FilePath, in root: URL) throws(FileError) -> URL {
        var url = root
        var exists = true
        for name in path.components {
            url = url.appendingPathComponent(name)
            // Past the first missing name nothing below it can be a link.
            guard exists, let attributes = try attributes(of: url, path: path) else {
                exists = false
                continue
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw .outsideRoot(path)
            }
        }
        return url
    }

    static func prepareParent(of url: URL, path: FilePath) throws(FileError) {
        try attempt(path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    /// A name that cannot be a ``FilePath``, so a temporary file never collides with a real one.
    static func temporaryURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
    }

    static func isTemporary(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".tmp")
    }

    /// Fills a temporary file next to `path` with `fill`, then moves it over the destination.
    /// Whatever goes wrong, the temporary file is removed and the destination is as it was.
    static func stage(
        _ path: FilePath,
        in root: URL,
        cancellation: Cancellation,
        fill: (URL) throws(FileError) -> Void
    ) throws(FileError) {
        let destination = try resolve(path, in: root)
        let existing = try attributes(of: destination, path: path)
        if let existing, isDirectory(existing) { throw .wrongKind(path) }
        try prepareParent(of: destination, path: path)

        let temporary = temporaryURL(beside: destination)
        do throws(FileError) {
            try fill(temporary)
            // The last chance to stop: after the move the new content is in place.
            try cancellation.check()
            try attempt(path) {
                if existing != nil {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Copies `source` to `destination` a chunk at a time, stopping at the size limit or when
    /// the operation is cancelled.
    static func copyChunks(
        from source: URL,
        to destination: URL,
        path: FilePath,
        limit: Int64?,
        chunkSize: Int,
        cancellation: Cancellation
    ) throws(FileError) {
        // A failure of the source is not about the destination path, so it carries none.
        let input = try attempt(nil) { try FileHandle(forReadingFrom: source) }
        defer { try? input.close() }
        try attempt(path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let output = try attempt(path) { try FileHandle(forWritingTo: destination) }
        defer { try? output.close() }

        var total: Int64 = 0
        while true {
            try cancellation.check()
            let chunk = try attempt(nil) { try input.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { return }

            total += Int64(chunk.count)
            if let limit, total > limit { throw .tooLarge(path, limit: limit) }
            try attempt(path) { try output.write(contentsOf: chunk) }
        }
    }
}
