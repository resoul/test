/// Why a file operation failed.
///
/// Failures of the operating system are sorted into the ones a caller can act on — missing
/// file, no space, no permission — and everything else, which keeps the system's description.
public enum FileError: Error, Sendable, Equatable {
    /// The text is not an acceptable ``FilePath``; the string says why.
    case invalidPath(String)
    /// A name under the root is a symbolic link, so following it could leave the root.
    case outsideRoot(FilePath)
    case notFound(FilePath)
    case alreadyExists(FilePath)
    /// The operation needs a file but the location is a directory, or the other way around; also a
    /// path that would have to go through a file. The path is the one the caller passed.
    case wrongKind(FilePath)
    /// The file is bigger than the store's limit, or the content would make it so.
    case tooLarge(FilePath, limit: Int64)
    /// The volume has no room for the write.
    case noSpace
    case accessDenied(FilePath)
    /// The task was cancelled. Whatever the operation had not finished is undone; an operation
    /// that had already replaced its destination stays done.
    case cancelled
    /// Any other failure. `reason` is the system's description; `path` is nil for the root.
    case failed(path: FilePath?, reason: String)
}
