import Foundation
import StorageCore

/// A ``PreferenceBackend`` over a `UserDefaults` domain.
///
/// Booleans, integers, doubles, strings, data and dates are stored natively, so the values
/// stay readable by other code and by `defaults read`. A stored value of another kind, such
/// as an array, reads as ``PreferenceRepresentation/unsupported(_:)``.
public final class UserDefaultsPreferenceBackend: PreferenceBackend {
    private let defaults: UserDefaults
    private var observer: (any NSObjectProtocol)?

    /// - Parameter defaults: The domain to use. Tests pass a throwaway suite so that they never
    ///   touch the app's real settings.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func read(_ name: String) -> PreferenceRepresentation? {
        guard let object = defaults.object(forKey: name) else { return nil }

        switch object {
        case let value as Data: return .data(value)
        case let value as Date: return .date(value)
        case let value as String: return .string(value)
        case let value as NSNumber:
            // A boolean and a number are both NSNumber; the CoreFoundation type tells them
            // apart, and the float flag keeps `2.0` a double.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            if CFNumberIsFloatType(value) { return .double(value.doubleValue) }
            return .int(value.intValue)
        default:
            return .unsupported(String(describing: type(of: object)))
        }
    }

    public func write(_ value: PreferenceRepresentation, for name: String) {
        switch value {
        case .bool(let value): defaults.set(value, forKey: name)
        case .int(let value): defaults.set(value, forKey: name)
        case .double(let value): defaults.set(value, forKey: name)
        case .string(let value): defaults.set(value, forKey: name)
        case .data(let value): defaults.set(value, forKey: name)
        case .date(let value): defaults.set(value, forKey: name)
        // Only a read produces it; nothing a codec returns should be stored as such.
        case .unsupported: break
        }
    }

    public func remove(_ name: String) {
        defaults.removeObject(forKey: name)
    }

    // The notification fires for our own writes too; the owner compares values, so the echo
    // is harmless.
    public func observeExternalChanges(_ onChange: @escaping @Sendable () -> Void) {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in onChange() }
    }
}

extension Preferences {
    /// Preferences over a `UserDefaults` domain that the actor opens and owns.
    ///
    /// - Parameters:
    ///   - suiteName: The domain, such as an App Group identifier or, in tests, a throwaway
    ///     name; `nil` is the app's standard domain. A name that `UserDefaults` refuses — the
    ///     app's own bundle identifier or the global domain — is a programmer error and stops
    ///     the program instead of quietly using the standard domain.
    ///   - namespace: A prefix for stored names, see ``Preferences/init(backend:namespace:)``.
    public static func userDefaults(suiteName: String? = nil, namespace: String = "")
        -> Preferences
    {
        let defaults: UserDefaults
        if let suiteName {
            guard let suite = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("UserDefaults refuses the suite name \(suiteName)")
            }
            defaults = suite
        } else {
            defaults = .standard
        }
        return Preferences(
            backend: UserDefaultsPreferenceBackend(defaults: defaults),
            namespace: namespace
        )
    }
}
