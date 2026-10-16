/// Where the answers come from: the system, or a stand-in.
///
/// A provider speaks to one system and knows nothing of the order of asking; ``Permissions`` puts the
/// order on top. So a provider may be plain: read the status, ask once.
public protocol PermissionProvider: Sendable {
    /// What the system says about `kind`. Reading never shows a window and has no effect.
    func status(of kind: PermissionKind) async -> PermissionStatus

    /// Asks the system for `kind`, which shows its window, and returns the status that follows.
    ///
    /// ``Permissions`` calls this only for a kind whose status is ``PermissionStatus/notDetermined``.
    /// The provider checks what it can before asking and throws instead of letting the system fail:
    /// ``PermissionError/missingUsageDescription(key:)`` for a key that is absent,
    /// ``PermissionError/notInForeground``, ``PermissionError/unsupported(_:)``.
    ///
    /// Cancelling the task does not close the window; the call returns when the person answers.
    func request(_ kind: PermissionKind) async throws(PermissionError) -> PermissionStatus
}
