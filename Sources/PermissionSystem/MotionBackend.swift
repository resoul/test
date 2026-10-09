import PermissionCore

// The Core Motion activity calls are marked unavailable on macOS, and the framework is not in the
// tvOS SDK at all. The package sets this condition for iOS and Mac Catalyst.
#if PERMISSION_MOTION && canImport(CoreMotion)
    import CoreMotion

    /// Motion and fitness activity. One status covers the activity, pedometer and altimeter
    /// managers; there is no call that asks, so a request makes a short query, which is what makes
    /// the system show its window, and waits for the query to end.
    struct MotionBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            guard CMMotionActivityManager.isActivityAvailable() else {
                return .unavailable(.hardware)
            }

            return Self.map(CMMotionActivityManager.authorizationStatus())
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            guard CMMotionActivityManager.isActivityAvailable() else {
                throw .unsupported(.hardware)
            }

            let manager = CMMotionActivityManager()
            let now = Date()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                manager.queryActivityStarting(from: now, to: now, to: OperationQueue()) { _, _ in
                    continuation.resume()
                }
            }
            return await status()
        }

        static func map(_ status: CMAuthorizationStatus) -> PermissionStatus {
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
        static func motionBackend() -> (any PermissionBackend)? { MotionBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func motionBackend() -> (any PermissionBackend)? { nil }
    }
#endif
