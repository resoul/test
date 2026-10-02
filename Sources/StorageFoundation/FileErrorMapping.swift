import Foundation
import StorageCore

extension FileError {
    /// Sorts a failure of Foundation or the system into the cases a caller can act on.
    ///
    /// Foundation often wraps a POSIX error inside a Cocoa one, so the wrapped error is looked at
    /// first. A case that names a path needs one; without it the failure stays a general one.
    init(_ error: any Error, path: FilePath?) {
        if let known = error as? FileError {
            self = known
            return
        }
        if error is CancellationError {
            self = .cancelled
            return
        }

        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain,
            let mapped = Self.posix(Int32(underlying.code), path: path)
        {
            self = mapped
        } else if nsError.domain == NSPOSIXErrorDomain,
            let mapped = Self.posix(Int32(nsError.code), path: path)
        {
            self = mapped
        } else if nsError.domain == NSCocoaErrorDomain,
            let mapped = Self.cocoa(nsError.code, path: path)
        {
            self = mapped
        } else {
            self = .failed(path: path, reason: nsError.localizedDescription)
        }
    }

    private static func posix(_ code: Int32, path: FilePath?) -> FileError? {
        switch code {
        case ENOSPC, EDQUOT: return .noSpace
        case ENOENT: return path.map { .notFound($0) }
        case EACCES, EPERM, EROFS: return path.map { .accessDenied($0) }
        case EEXIST, ENOTEMPTY: return path.map { .alreadyExists($0) }
        case EISDIR, ENOTDIR: return path.map { .wrongKind($0) }
        default: return nil
        }
    }

    private static func cocoa(_ code: Int, path: FilePath?) -> FileError? {
        switch code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return path.map { .notFound($0) }
        case NSFileWriteOutOfSpaceError:
            return .noSpace
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return path.map { .accessDenied($0) }
        case NSFileWriteFileExistsError:
            return path.map { .alreadyExists($0) }
        default:
            return nil
        }
    }
}
