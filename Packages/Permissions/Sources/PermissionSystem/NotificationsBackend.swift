import PermissionCore

#if canImport(UserNotifications)
    import UserNotifications

    /// Notifications. The center belongs to an app bundle: `UNUserNotificationCenter.current()` stops a
    /// process that is not an app, such as a test runner of a package, so this backend is for
    /// apps, and is exercised in the demo's UI tests.
    struct NotificationsBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return Self.map(settings.authorizationStatus)
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            do {
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                throw .system(description: "\(error)")
            }
            return await status()
        }

        static func map(_ status: UNAuthorizationStatus) -> PermissionStatus {
            switch status {
            case .notDetermined: .notDetermined
            case .denied: .denied
            case .authorized: .granted(.full)
            case .provisional: .granted(.provisional)
            default:
                // `.ephemeral` exists on iOS only, and its raw value is the only way to name it here.
                status.rawValue == 4 ? .granted(.ephemeral) : .notDetermined
            }
        }
    }

    extension SystemPermissionProvider {
        static func notificationsBackend() -> (any PermissionBackend)? { NotificationsBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func notificationsBackend() -> (any PermissionBackend)? { nil }
    }
#endif
