import PermissionCore

// The media library calls are marked unavailable on macOS and tvOS. The package sets this
// condition for iOS and Mac Catalyst.
#if PERMISSION_MEDIA_LIBRARY && canImport(MediaPlayer)
    import MediaPlayer

    /// The person's music library.
    struct MediaLibraryBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            Self.map(MPMediaLibrary.authorizationStatus())
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            Self.map(await MPMediaLibrary.requestAuthorization())
        }

        static func map(_ status: MPMediaLibraryAuthorizationStatus) -> PermissionStatus {
            switch status {
            case .notDetermined: .notDetermined
            case .denied: .denied
            case .restricted: .restricted
            case .authorized: .granted(.full)
            @unknown default: .notDetermined
            }
        }
    }

    extension SystemPermissionProvider {
        static func mediaLibraryBackend() -> (any PermissionBackend)? { MediaLibraryBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func mediaLibraryBackend() -> (any PermissionBackend)? { nil }
    }
#endif
