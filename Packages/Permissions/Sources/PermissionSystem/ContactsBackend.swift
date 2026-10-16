import PermissionCore

#if canImport(Contacts)
    import Contacts

    /// The address book. On iOS 18 the person may share only some of the contacts, which is
    /// `limited`; that case does not exist on macOS, so it is read by its number.
    struct ContactsBackend: PermissionBackend {
        func status() async -> PermissionStatus {
            Self.map(CNContactStore.authorizationStatus(for: .contacts))
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                throw .system(description: "\(error)")
            }
            return await status()
        }

        static func map(_ status: CNAuthorizationStatus) -> PermissionStatus {
            switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .granted(.full)
            default: status.rawValue == 4 ? .granted(.limited) : .notDetermined
            }
        }
    }

    extension SystemPermissionProvider {
        static func contactsBackend() -> (any PermissionBackend)? { ContactsBackend() }
    }
#else
    extension SystemPermissionProvider {
        static func contactsBackend() -> (any PermissionBackend)? { nil }
    }
#endif
