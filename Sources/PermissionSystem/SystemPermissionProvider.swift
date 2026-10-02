import Foundation
import PermissionCore

/// What the system says and does for one kind of permission: the one place that calls the
/// framework that owns it.
protocol PermissionBackend: Sendable {
    /// What the system says now. Never shows a window and has no effect.
    func status() async -> PermissionStatus

    /// Asks the system, which shows its window, and returns what it says after.
    func request() async throws(PermissionError) -> PermissionStatus
}

/// A ``PermissionProvider`` that asks the system's own frameworks.
///
/// Before a request reaches the system it checks what the system would otherwise punish: the
/// `Info.plist` strings that explain the request must be present and not empty — without one the
/// system ends the app, or quietly refuses, depending on the kind — and the app must be in front,
/// because the system shows its window only to the app in front. A request that fails either check
/// throws and the system is not asked. Reading a status makes none of these checks and shows no
/// window.
///
/// Kinds this platform has no framework for answer ``PermissionStatus/unavailable(_:)``.
///
/// The provider holds no state: copies are interchangeable, and asking about different kinds at
/// once is allowed, though ``Permissions`` asks one at a time because the system shows one window at
/// a time.
public struct SystemPermissionProvider: PermissionProvider {
    private let isInForeground: @Sendable () async -> Bool
    private let usageDescription: @Sendable (String) -> String?
    private let backendFor: @Sendable (PermissionKind) -> (any PermissionBackend)?

    /// - Parameters:
    ///   - isInForeground: Whether the app is in front. The platform module knows
    ///     (`PermissionUIKit`, `PermissionAppKit`); this module does not import the UI frameworks.
    ///   - usageDescription: The string for an `Info.plist` key, or `nil`. The app's own bundle by
    ///     default.
    public init(
        isInForeground: @escaping @Sendable () async -> Bool,
        usageDescription: @escaping @Sendable (String) -> String? = { key in
            Bundle.main.object(forInfoDictionaryKey: key) as? String
        }
    ) {
        self.init(
            isInForeground: isInForeground,
            usageDescription: usageDescription,
            backends: Self.systemBackend(for:)
        )
    }

    /// The same with the backends given, for tests, which cannot show the system's windows.
    init(
        isInForeground: @escaping @Sendable () async -> Bool,
        usageDescription: @escaping @Sendable (String) -> String?,
        backends: @escaping @Sendable (PermissionKind) -> (any PermissionBackend)?
    ) {
        self.isInForeground = isInForeground
        self.usageDescription = usageDescription
        self.backendFor = backends
    }

    public func status(of kind: PermissionKind) async -> PermissionStatus {
        guard let backend = backendFor(kind) else { return .unavailable(.platform) }

        return await backend.status()
    }

    public func request(_ kind: PermissionKind) async throws(PermissionError) -> PermissionStatus {
        guard let backend = backendFor(kind) else { throw .unsupported(.platform) }

        // A missing string is a mistake of the app, and shows the same in front or behind.
        for key in kind.usageDescriptionKeys {
            let text = usageDescription(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { throw .missingUsageDescription(key: key) }
        }
        guard await isInForeground() else { throw .notInForeground }

        return try await backend.request()
    }

    /// The backend for `kind` on this platform, or `nil` when no framework here has it.
    static func systemBackend(for kind: PermissionKind) -> (any PermissionBackend)? {
        switch kind {
        case .camera: captureBackend(isVideo: true)
        case .microphone: captureBackend(isVideo: false)
        case .photos(let access): photosBackend(access)
        case .notifications: notificationsBackend()
        case .location(let access): locationBackend(access)
        }
    }
}
