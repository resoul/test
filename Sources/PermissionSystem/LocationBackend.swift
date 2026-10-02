import PermissionCore

#if canImport(CoreLocation)
    import CoreLocation

    /// Location. The system answers to a delegate, later, so a request waits for the delegate to hear a
    /// status other than "not determined". The manager must live on the main thread, where the
    /// delegate's calls come.
    struct LocationBackend: PermissionBackend {
        let access: PermissionKind.LocationAccess

        func status() async -> PermissionStatus {
            await MainActor.run { Self.map(CLLocationManager().authorizationStatus) }
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            switch access {
            case .whenInUse:
                return await Self.askWhenInUse()
            case .always:
                // Asking for "always" comes after "when in use" and has a window of its own; it is not
                // written yet, and does not pretend to be.
                throw .system(description: "Asking for location always is not implemented")
            }
        }

        @MainActor
        private static func askWhenInUse() async -> PermissionStatus {
            let asker = LocationAsker()
            return await asker.ask()
        }

        static func map(_ status: CLAuthorizationStatus) -> PermissionStatus {
            switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorizedAlways: .granted(.always)
            case .authorizedWhenInUse: .granted(.whenInUse)
            @unknown default: .notDetermined
            }
        }
    }

    /// Holds the manager and its delegate while one request is open.
    @MainActor
    private final class LocationAsker: NSObject, CLLocationManagerDelegate {
        private let manager = CLLocationManager()
        private var waiting: CheckedContinuation<PermissionStatus, Never>?

        func ask() async -> PermissionStatus {
            manager.delegate = self
            return await withCheckedContinuation { continuation in
                waiting = continuation
                manager.requestWhenInUseAuthorization()
            }
        }

        nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            Task { @MainActor in self.heard() }
        }

        private func heard() {
            let status = LocationBackend.map(manager.authorizationStatus)
            // The delegate is also told the status when it is set; only an answer ends the wait.
            guard status != .notDetermined, let waiting else { return }

            self.waiting = nil
            waiting.resume(returning: status)
        }
    }

    extension SystemPermissionProvider {
        static func locationBackend(_ access: PermissionKind.LocationAccess) -> (
            any PermissionBackend
        )? {
            LocationBackend(access: access)
        }
    }
#else
    extension SystemPermissionProvider {
        static func locationBackend(_ access: PermissionKind.LocationAccess) -> (
            any PermissionBackend
        )? {
            nil
        }
    }
#endif
