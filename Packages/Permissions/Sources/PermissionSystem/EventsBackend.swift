import PermissionCore

#if canImport(EventKit)
    import EventKit

    /// Calendar events and reminders. Both go through one `EKEventStore`, which keeps a status for
    /// each kind of item. Since iOS 17 and macOS 14 the request names the level — full access to
    /// events, write-only access to events, full access to reminders — and the system asks for a
    /// different `Info.plist` string for each; before, one call asked and one string explained.
    struct EventsBackend: PermissionBackend {
        enum Subject: Sendable {
            case events(PermissionKind.CalendarAccess)
            case reminders
        }

        let subject: Subject

        private var entity: EKEntityType {
            switch subject {
            case .events: .event
            case .reminders: .reminder
            }
        }

        var usageDescriptionKeys: [String]? {
            if #available(iOS 17, macOS 14, macCatalyst 17, *) { return nil }

            switch subject {
            case .events: return ["NSCalendarsUsageDescription"]
            case .reminders: return ["NSRemindersUsageDescription"]
            }
        }

        func status() async -> PermissionStatus {
            Self.map(EKEventStore.authorizationStatus(for: entity))
        }

        func request() async throws(PermissionError) -> PermissionStatus {
            let store = EKEventStore()
            do {
                if #available(iOS 17, macOS 14, macCatalyst 17, *) {
                    switch subject {
                    case .events(.full): _ = try await store.requestFullAccessToEvents()
                    case .events(.writeOnly): _ = try await store.requestWriteOnlyAccessToEvents()
                    case .reminders: _ = try await store.requestFullAccessToReminders()
                    }
                } else {
                    _ = try await store.requestAccess(to: entity)
                }
            } catch {
                throw .system(description: "\(error)")
            }
            return await status()
        }

        /// `fullAccess` and `writeOnly` are iOS 17 cases; on an older system the one granted state
        /// is `authorized`, which has the number of `fullAccess`. The numbers are the same on every
        /// platform, so they are read as numbers.
        static func map(_ status: EKAuthorizationStatus) -> PermissionStatus {
            switch status.rawValue {
            case 0: .notDetermined
            case 1: .restricted
            case 2: .denied
            case 3: .granted(.full)
            case 4: .granted(.writeOnly)
            default: .notDetermined
            }
        }
    }

    extension SystemPermissionProvider {
        static func calendarBackend(_ access: PermissionKind.CalendarAccess) -> (
            any PermissionBackend
        )? {
            EventsBackend(subject: .events(access))
        }

        static func remindersBackend() -> (any PermissionBackend)? {
            EventsBackend(subject: .reminders)
        }
    }
#else
    extension SystemPermissionProvider {
        static func calendarBackend(_ access: PermissionKind.CalendarAccess) -> (
            any PermissionBackend
        )? {
            nil
        }

        static func remindersBackend() -> (any PermissionBackend)? { nil }
    }
#endif
