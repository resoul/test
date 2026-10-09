import PermissionCore

// The Speech framework is in the tvOS SDK, but its authorization calls are marked unavailable
// there. The package sets this condition for the platforms that have them.
#if PERMISSION_SPEECH && canImport(Speech)
    import Speech

    /// Speech recognition.
    struct SpeechBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            Self.map(SFSpeechRecognizer.authorizationStatus())
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            let answer = await withCheckedContinuation {
                (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>)
                in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return Self.map(answer)
        }

        static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
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
        static func speechBackend() -> (any PermissionBackend)? { SpeechBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func speechBackend() -> (any PermissionBackend)? { nil }
    }
#endif
