import PermissionCore

#if canImport(CoreLocation)
    import CoreLocation

    /// Location. The system answers to a delegate, later, so a request waits for the delegate to hear a
    /// status other than "not determined". The manager must live on the main thread, where the
    /// delegate's calls come.
    struct LocationBackend: PermissionBackend {
        let access: PermissionKind.LocationAccess
        let isInForeground: @Sendable () async -> Bool

        func status() async -> PermissionStatus {
            await MainActor.run { Self.map(CLLocationManager().authorizationStatus) }
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            switch access {
            case .whenInUse:
                return await Self.askWhenInUse()
            case .always:
                // Location "always" is not asked on tvOS, where the call does not exist.
                #if PERMISSION_LOCATION_ALWAYS
                    return await Self.askAlways(isInForeground: isInForeground)
                #else
                    throw .unsupported(.platform)
                #endif
            }
        }

        #if PERMISSION_LOCATION_ALWAYS
            /// From "not determined" the system shows its first window — on iOS the one for "when in
            /// use", which is what it offers first — and the answer is returned as it is: the offer
            /// to raise it to "always" is a second window, which is not shown behind the first one's
            /// back, and the next request is the one that asks for it. From "when in use" the offer
            /// is made and waited out. From any other status the system is not asked.
            @MainActor
            private static func askAlways(isInForeground: @escaping @Sendable () async -> Bool)
                async -> PermissionStatus
            {
                let asker = LocationAsker()
                let current = map(asker.currentStatus)
                guard current == .notDetermined || current == .granted(.whenInUse) else {
                    return current
                }

                if current == .notDetermined { return await asker.ask(always: true) }

                asker.requestAlways()
                let wait = AlwaysUpgradeWait(
                    status: { await MainActor.run { map(CLLocationManager().authorizationStatus) } },
                    isInForeground: isInForeground
                )
                // The request belongs to the manager: it must live until the window is gone.
                let answer = await wait.run()
                withExtendedLifetime(asker) {}
                return answer
            }
        #endif

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

        var currentStatus: CLAuthorizationStatus { manager.authorizationStatus }

        func ask(always: Bool = false) async -> PermissionStatus {
            manager.delegate = self
            return await withCheckedContinuation { continuation in
                waiting = continuation
                #if PERMISSION_LOCATION_ALWAYS
                    if always {
                        manager.requestAlwaysAuthorization()
                        return
                    }
                #endif
                manager.requestWhenInUseAuthorization()
            }
        }

        #if PERMISSION_LOCATION_ALWAYS
            func requestAlways() {
                manager.requestAlwaysAuthorization()
            }
        #endif

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
        static func locationBackend(
            _ access: PermissionKind.LocationAccess,
            isInForeground: @escaping @Sendable () async -> Bool
        ) -> (any PermissionBackend)? {
            LocationBackend(access: access, isInForeground: isInForeground)
        }
    }
#else
    extension SystemPermissionProvider {
        static func locationBackend(
            _ access: PermissionKind.LocationAccess,
            isInForeground: @escaping @Sendable () async -> Bool
        ) -> (any PermissionBackend)? {
            nil
        }
    }
#endif
