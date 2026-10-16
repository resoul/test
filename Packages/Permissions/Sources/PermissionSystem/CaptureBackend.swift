import PermissionCore

#if canImport(AVFoundation)
    import AVFoundation

    /// Camera and microphone: `AVCaptureDevice` keeps one status per media type. The capture
    /// device exists on tvOS only from 17; below that the permission does not exist.
    struct CaptureBackend: PermissionBackend {
        let mediaType: AVMediaType

        func status() async -> PermissionStatus {
            guard #available(tvOS 17, *) else { return .unavailable(.systemVersion) }

            return Self.map(AVCaptureDevice.authorizationStatus(for: mediaType))
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            guard #available(tvOS 17, *) else { throw .unsupported(.systemVersion) }

            _ = await AVCaptureDevice.requestAccess(for: mediaType)
            return await status()
        }

        @available(tvOS 17, *)
        static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
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
        static func captureBackend(isVideo: Bool) -> (any PermissionBackend)? {
            CaptureBackend(mediaType: isVideo ? .video : .audio)
        }
    }
#else
    extension SystemPermissionProvider {
        static func captureBackend(isVideo: Bool) -> (any PermissionBackend)? { nil }
    }
#endif
