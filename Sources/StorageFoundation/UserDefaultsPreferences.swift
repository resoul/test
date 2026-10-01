import Foundation
import StorageCore

/// A preference store over a `UserDefaults` domain.
///
/// Values are kept in the defaults as property-list types, so other code reading the same
/// domain sees ordinary booleans, numbers, strings, data and dates. All access goes through this
/// actor. Writes are visible to later reads at once; `UserDefaults` writes them to disk on its
/// own schedule, so a call returning does not mean the value has reached the disk.
///
/// The store holds the `UserDefaults` object and, while any stream is watching, an observer of
/// its change notification. It sees changes made by other code, in this process or by other
/// processes sharing the domain, by rereading the watched names after a notification. It does
/// not keep a log of changes.
public actor UserDefaultsPreferences: PreferenceStore {
    private let defaults: UserDefaults
    private let prefix: String
    private var observers: [Int: Observer] = [:]
    private var nextObserver = 0
    private var notificationToken: (any NSObjectProtocol)?

    private struct Observer {
        let name: String
        let continuation: AsyncStream<PreferenceValue?>.Continuation
    }

    /// Creates a store over `defaults`.
    ///
    /// - Parameters:
    ///   - defaults: The domain to use; the standard defaults unless told otherwise.
    ///   - namespace: Text put before every name, with a dot, so one domain can hold several
    ///     stores without clashing. Empty uses the names as they are.
    public init(defaults: UserDefaults = .standard, namespace: String = "") {
        self.defaults = defaults
        self.prefix = namespace.isEmpty ? "" : namespace + "."
    }

    /// Creates a store over the named suite, or returns nil when the system does not allow that
    /// name, for example the app's own bundle identifier.
    public init?(suiteName: String, namespace: String = "") {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }

        self.init(defaults: defaults, namespace: namespace)
    }

    public func rawValue(forName name: String) -> PreferenceValue? {
        read(name)
    }

    public func setRawValue(_ value: PreferenceValue?, forName name: String) {
        let key = prefix + name
        switch value {
        case nil: defaults.removeObject(forKey: key)
        case .bool(let value): defaults.set(value, forKey: key)
        case .int(let value): defaults.set(value, forKey: key)
        case .double(let value): defaults.set(value, forKey: key)
        case .string(let value): defaults.set(value, forKey: key)
        case .data(let value): defaults.set(value, forKey: key)
        case .date(let value): defaults.set(value, forKey: key)
        case .unsupported: return
        }
        notifyObservers(of: name)
    }

    public func observeRawValue(forName name: String) -> AsyncStream<PreferenceValue?> {
        let (stream, continuation) = AsyncStream<PreferenceValue?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = nextObserver
        nextObserver += 1
        observers[id] = Observer(name: name, continuation: continuation)
        continuation.yield(read(name))
        startListeningIfNeeded()
        // The closure keeps the store alive while the stream does, so the notification observer
        // is always removed by the last stream and never outlives the store.
        continuation.onTermination = { _ in
            Task { await self.removeObserver(id) }
        }
        return stream
    }

    private func read(_ name: String) -> PreferenceValue? {
        guard let object = defaults.object(forKey: prefix + name) else { return nil }

        switch object {
        case let number as NSNumber:
            // A property list keeps a Boolean and a number apart only by their type; Swift's
            // `as Bool` would take 0 and 1 for Booleans.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let string as String: return .string(string)
        case let data as Data: return .data(data)
        case let date as Date: return .date(date)
        default: return .unsupported(String(describing: type(of: object)))
        }
    }

    private func notifyObservers(of name: String) {
        for observer in observers.values where observer.name == name {
            observer.continuation.yield(read(name))
        }
    }

    /// Rereads every watched name after something changed in the domain. Repeated values are
    /// removed by the typed layer, so a notification about another key costs only a read.
    private func domainDidChange() {
        for observer in observers.values {
            observer.continuation.yield(read(observer.name))
        }
    }

    private func startListeningIfNeeded() {
        guard notificationToken == nil else { return }

        // Any object, not only ours: the notification names the `UserDefaults` instance that was
        // written through, and other code may hold another instance of the same domain.
        notificationToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [self] _ in
            Task { await self.domainDidChange() }
        }
    }

    private func removeObserver(_ id: Int) {
        observers[id] = nil
        if observers.isEmpty, let token = notificationToken {
            NotificationCenter.default.removeObserver(token)
            notificationToken = nil
        }
    }

    /// The number of streams currently watching the store.
    var observerCount: Int { observers.count }
}
