import Foundation

/// What is known about a file or directory without reading it.
public struct FileMetadata: Sendable, Equatable {
    public var isDirectory: Bool
    /// The size in bytes; zero for a directory.
    public var size: Int64
    public var modificationDate: Date?

    public init(isDirectory: Bool, size: Int64, modificationDate: Date?) {
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// One item found by ``FileStore/list(_:)``.
public struct FileEntry: Sendable, Equatable {
    public var path: FilePath
    public var metadata: FileMetadata

    public init(path: FilePath, metadata: FileMetadata) {
        self.path = path
        self.metadata = metadata
    }
}

/// A set of files under one root, addressed by ``FilePath``.
///
/// A store is `Sendable` and serialises its own work, so calls may come from any isolation and
/// never block the caller's thread. Writing a file replaces it as a whole: a reader sees the old
/// content or the new, never a mixture. Whether the new content has reached the disk when the
/// call returns is not promised.
///
/// Every operation throws ``FileError``. Cancelling the calling task stops the operation at its
/// next check and throws ``FileError/cancelled``; see the error for what stays done.
public protocol FileStore: Sendable {
    /// The whole content of a file.
    ///
    /// - Throws: ``FileError/notFound(_:)``, ``FileError/wrongKind(_:)`` for a directory, or
    ///   ``FileError/tooLarge(_:limit:)`` when the file is over the store's size limit.
    func read(_ path: FilePath) async throws(FileError) -> Data

    /// Writes `data` as the whole content of `path`, creating missing directories above it.
    /// An existing file is replaced; if the write fails, the previous content is still there.
    func write(_ data: Data, to path: FilePath) async throws(FileError)

    /// What is known about `path`, or `nil` when nothing is there.
    func metadata(of path: FilePath) async throws(FileError) -> FileMetadata?

    /// The items directly inside `directory` (the root when `nil`), sorted by path. A directory
    /// that does not exist has no items.
    func list(_ directory: FilePath?) async throws(FileError) -> [FileEntry]

    /// Copies the file at `url`, which lies outside the store, to `path`, creating missing
    /// directories above it. The source is only read, and a file too big for memory is fine: a
    /// store that keeps its files on disk copies in pieces.
    ///
    /// An existing file at `path` is replaced when the copy is complete; if the copy fails or is
    /// cancelled, the previous content is still there.
    ///
    /// - Throws: ``FileError/failed(path:reason:)`` when `url` cannot be read, and the errors of
    ///   ``write(_:to:)``.
    func importFile(at url: URL, to path: FilePath) async throws(FileError)

    /// Removes a file, or a directory with everything in it.
    ///
    /// - Returns: Whether something was there to remove; removing nothing is not an error.
    @discardableResult
    func remove(_ path: FilePath) async throws(FileError) -> Bool

    /// Moves a file or directory, creating missing directories above `destination`.
    ///
    /// - Parameter replacing: Whether an existing item at `destination` is replaced. Without it
    ///   an existing item makes the call throw ``FileError/alreadyExists(_:)``.
    func move(_ source: FilePath, to destination: FilePath, replacing: Bool)
        async throws(FileError)
}
