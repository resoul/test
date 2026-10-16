import AsyncRay
import DataAsyncRay
import PermissionAsyncRay
import PermissionCore
import StateAsyncRay
import StateCore
import StorageCore

/// A screen's state fed by streams: a stored preference and a permission's status. Bindings
/// write on the main actor and hold the states weakly; the bag ends them all at once.
@MainActor
public final class SettingsModel {
    /// Whether rows are compact, as stored.
    public let compactRows = State(false)
    /// The camera permission's status.
    public let camera = State(PermissionStatus.notDetermined)
    private let subscriptions = SubscriptionBag()

    /// A model with nothing bound yet.
    public init() {}

    /// Follows the key in `preferences` and the camera in `permissions` until `stop()`.
    /// A stored value that does not decode leaves the state as it was.
    public func bind(preferences: some PreferenceStore, permissions: Permissions) {
        let key = PreferenceKey("settings.compactRows", default: false)
        preferences.valuesRay(for: key)
            .compactMap { try? $0.get() }
            .bind(to: compactRows)
            .store(in: subscriptions)
        permissions.statusRay(of: .camera)
            .bind(to: camera)
            .store(in: subscriptions)
    }

    /// Ends every binding. Values already written stay.
    public func stop() {
        subscriptions.cancelAll()
    }
}

/// A state seen as a stream: its value now, then after each change, at the flush that
/// follows it. A screen can hand it to code that knows nothing about states.
///
/// - Returns: The first `count` values the stream gave.
@MainActor
public func watchCount(_ count: State<Int>, values: Int) async -> [Int] {
    await count.asyncRay.take(values).collect()
}
