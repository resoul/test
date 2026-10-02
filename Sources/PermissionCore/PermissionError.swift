/// Why asking for a permission failed. A person's "no" is not a failure: it is
/// ``PermissionStatus/denied``.
public enum PermissionError: Error, Sendable, Equatable {
    /// An `Info.plist` key that explains the request is missing or empty, so the system was not asked.
    case missingUsageDescription(key: String)
    /// The system shows its window only to the app in front; the app was not.
    case notInForeground
    /// The permission does not exist here; the reason says why.
    case unsupported(PermissionStatus.Reason)
    /// The system failed. `description` is its own wording, for the log and not for the person.
    case system(description: String)
    /// The calling task was cancelled. The request itself is not: see ``Permissions/request(_:)``.
    case cancelled
}
