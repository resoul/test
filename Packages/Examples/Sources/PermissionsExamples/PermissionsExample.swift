import PermissionCore
import PermissionSystem

#if canImport(UIKit)
    import PermissionUIKit
#elseif canImport(AppKit)
    import PermissionAppKit
#endif

/// What a camera button does with the app's permissions: asks only when asking can still
/// change something, and otherwise tells the person where the answer is.
public enum CameraAccess: Equatable, Sendable {
    /// The camera may be used.
    case ready
    /// The person said no; only Settings can change it.
    case sendToSettings
    /// The device has no camera, or a policy forbids it.
    case unavailable
}

/// Asks for the camera through `permissions`. One `Permissions` serves the whole app: two
/// screens asking at once share one system window and one answer.
///
/// - Throws: `PermissionError` — the Info.plist lacks the usage description, or the app is not
///   in front. An error is not remembered: asking again asks again.
public func prepareCamera(with permissions: Permissions) async throws(PermissionError)
    -> CameraAccess
{
    let current = await permissions.status(of: .camera)
    let status =
        PermissionKind.camera.canBeAsked(whenStatusIs: current)
        ? try await permissions.request(.camera) : current
    switch status {
    case .granted: return .ready
    case .denied: return .sendToSettings
    case .notDetermined, .restricted, .unavailable: return .unavailable
    }
}

/// The app's permissions over the system's frameworks. The provider checks the Info.plist key
/// before it asks, so a missing usage description is an error instead of a crash.
public func systemPermissions() -> Permissions {
    #if canImport(UIKit)
        Permissions(provider: UIKitPermissions.makeProvider())
    #elseif canImport(AppKit)
        Permissions(provider: AppKitPermissions.makeProvider())
    #endif
}

/// Permissions for tests and previews: statuses set by hand, answers scripted.
public func testPermissions(answer: PermissionStatus) async -> Permissions {
    let provider = InMemoryPermissionProvider()
    await provider.willAnswer(answer, for: .camera)
    return Permissions(provider: provider)
}
