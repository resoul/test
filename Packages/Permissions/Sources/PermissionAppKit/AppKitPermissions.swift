#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import PermissionCore
    import PermissionSystem

    /// What the system's permissions need from AppKit: whether the app is in front, and the System
    /// Settings that the person can be sent to.
    public enum AppKitPermissions {
        /// Whether the app is active, which is when the system shows its permission windows.
        @MainActor
        public static func isInForeground() -> Bool {
            NSApplication.shared.isActive
        }

        /// A provider over the system's frameworks, that asks only while the app is in front.
        public static func makeProvider() -> SystemPermissionProvider {
            SystemPermissionProvider(isInForeground: { await MainActor.run { isInForeground() } })
        }

        /// Whether the app is in front now, and then each time that changes, until the sequence is
        /// dropped. Pass it to ``Permissions/follow(_:)``.
        public static func foregroundChanges() -> AsyncStream<Bool> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: Bool.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let becameActive = Task {
                for await _ in NotificationCenter.default.notifications(
                    named: NSApplication.didBecomeActiveNotification
                ) {
                    continuation.yield(true)
                }
            }
            let resigned = Task {
                for await _ in NotificationCenter.default.notifications(
                    named: NSApplication.didResignActiveNotification
                ) {
                    continuation.yield(false)
                }
            }
            continuation.onTermination = { _ in
                becameActive.cancel()
                resigned.cancel()
            }
            Task { @MainActor in continuation.yield(isInForeground()) }
            return stream
        }

        /// Opens the Privacy & Security pane of System Settings, where each permission can be
        /// changed. The address is the pane's, not the app's own page: the Mac has none.
        ///
        /// - Returns: Whether the system opened it. It does not say whether the person changed
        ///   anything.
        @MainActor
        @discardableResult
        public static func openSettings() -> Bool {
            guard
                let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
                )
            else { return false }

            return NSWorkspace.shared.open(url)
        }
    }
#endif
