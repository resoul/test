import PermissionCore

#if canImport(Photos)
    import Photos

    /// The photo library, as a whole or for adding only: the system keeps a status for each, and
    /// reading may be granted for some of the photos only.
    struct PhotosBackend: PermissionBackend {
        let level: PHAccessLevel

        func status() async -> PermissionStatus {
            Self.map(PHPhotoLibrary.authorizationStatus(for: level))
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            Self.map(await PHPhotoLibrary.requestAuthorization(for: level))
        }

        static func map(_ status: PHAuthorizationStatus) -> PermissionStatus {
            switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .granted(.full)
            case .limited: .granted(.limited)
            @unknown default: .notDetermined
            }
        }
    }

    extension SystemPermissionProvider {
        static func photosBackend(_ access: PermissionKind.PhotoAccess) -> (any PermissionBackend)?
        {
            PhotosBackend(level: access == .readWrite ? .readWrite : .addOnly)
        }
    }
#else
    extension SystemPermissionProvider {
        static func photosBackend(_ access: PermissionKind.PhotoAccess) -> (any PermissionBackend)?
        {
            nil
        }
    }
#endif
