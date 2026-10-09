import PermissionCore

#if canImport(CoreBluetooth)
    import CoreBluetooth

    /// Bluetooth. There is no call that asks: the system shows its window when the app first makes a
    /// central manager, and tells the manager's delegate afterwards. So a request makes a manager,
    /// waits for the delegate to hear that the answer is no longer "not determined", and lets the
    /// manager go. The status is read from the class, without a manager, and without a window.
    struct BluetoothBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            Self.map(CBManager.authorization)
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            await Self.ask()
        }

        @MainActor
        private static func ask() async -> PermissionStatus {
            await BluetoothAsker().ask()
        }

        static func map(_ authorization: CBManagerAuthorization) -> PermissionStatus {
            switch authorization {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .allowedAlways: .granted(.full)
            @unknown default: .notDetermined
            }
        }
    }

    /// Holds the manager and its delegate while one request is open.
    @MainActor
    private final class BluetoothAsker: NSObject, CBCentralManagerDelegate {
        private var manager: CBCentralManager?
        private var waiting: CheckedContinuation<PermissionStatus, Never>?

        func ask() async -> PermissionStatus {
            await withCheckedContinuation { continuation in
                waiting = continuation
                // The power alert is another window, about Bluetooth being off; it is not what
                // was asked for.
                manager = CBCentralManager(
                    delegate: self,
                    queue: nil,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
                )
            }
        }

        nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
            Task { @MainActor in self.heard() }
        }

        private func heard() {
            let status = BluetoothBackend.map(CBManager.authorization)
            // The manager reports its state when it is made; only an answer ends the wait.
            guard status != .notDetermined, let waiting else { return }

            self.waiting = nil
            manager?.delegate = nil
            manager = nil
            waiting.resume(returning: status)
        }
    }

    extension SystemPermissionProvider {
        static func bluetoothBackend() -> (any PermissionBackend)? { BluetoothBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func bluetoothBackend() -> (any PermissionBackend)? { nil }
    }
#endif
