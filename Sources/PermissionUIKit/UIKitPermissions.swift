#if canImport(UIKit)
    import PermissionCore
    import PermissionSystem
    import UIKit

    /// What the system's permissions need from UIKit: whether the app is in front, and the
    /// Settings that the person can be sent to.
    public enum UIKitPermissions {
        /// Whether the app is active, which is when the system shows its permission windows.
        @MainActor
        public static func isInForeground() -> Bool {
            UIApplication.shared.applicationState == .active
        }

        /// A provider over the system's frameworks, that asks only while the app is in front.
        public static func makeProvider() -> SystemPermissionProvider {
            SystemPermissionProvider(isInForeground: { await MainActor.run { isInForeground() } })
        }

        /// Opens the app's own page in Settings, where each permission can be changed.
        ///
        /// - Returns: Whether the system opened it. It does not say whether the person changed
        ///   anything: the status is read again when the app returns to the front.
        @MainActor
        @discardableResult
        public static func openSettings() async -> Bool {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }

            return await UIApplication.shared.open(url)
        }
    }
#endif
