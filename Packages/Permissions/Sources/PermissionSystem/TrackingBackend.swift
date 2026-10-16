import PermissionCore

#if canImport(AppTrackingTransparency)
    import AppTrackingTransparency

    /// App Tracking Transparency: whether the app may follow the person across other companies'
    /// apps and sites. The system shows this window only to an app that is active.
    struct TrackingBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            Self.map(ATTrackingManager.trackingAuthorizationStatus)
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            Self.map(await ATTrackingManager.requestTrackingAuthorization())
        }

        static func map(_ status: ATTrackingManager.AuthorizationStatus) -> PermissionStatus {
            switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .granted(.full)
            @unknown default: .notDetermined
            }
        }
    }

    extension SystemPermissionProvider {
        static func trackingBackend() -> (any PermissionBackend)? { TrackingBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func trackingBackend() -> (any PermissionBackend)? { nil }
    }
#endif
