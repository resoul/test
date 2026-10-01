import Foundation

/// The name, type, default and conversion of one preference.
///
/// A key is a value and can be declared as a static constant. Reading a key whose value was never
/// written gives ``defaultValue``; a stored value that does not fit the type is an error, not the
/// default.
public struct PreferenceKey<Value: Sendable>: Sendable {
    /// The name the value is stored under, inside the store's namespace.
    public let name: String

    /// What reading gives while nothing is stored under the name.
    public let defaultValue: Value

    let encode: @Sendable (Value) throws -> PreferenceValue
    let decode: @Sendable (PreferenceValue) throws -> Value

    /// Creates a key with its own conversion.
    ///
    /// - Parameters:
    ///   - name: The stored name.
    ///   - defaultValue: The value to read while nothing is stored.
    ///   - encode: Turns a value into its stored form. It must not return
    ///     ``PreferenceValue/unsupported(_:)``.
    ///   - decode: Turns a stored value back. It throws for a stored value that does not fit; the
    ///     error is reported as ``PreferenceError/undecodable(key:reason:)``.
    public init(
        _ name: String,
        default defaultValue: Value,
        encode: @escaping @Sendable (Value) throws -> PreferenceValue,
        decode: @escaping @Sendable (PreferenceValue) throws -> Value
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.encode = encode
        self.decode = decode
    }

    /// Turns what a store holds into a result: the default while nothing is stored.
    func read(_ stored: PreferenceValue?) -> Result<Value, PreferenceError> {
        guard let stored else { return .success(defaultValue) }

        if case .unsupported(let type) = stored {
            return .failure(.undecodable(key: name, reason: "stored value has type \(type)"))
        }
        do {
            return .success(try decode(stored))
        } catch {
            return .failure(.undecodable(key: name, reason: String(describing: error)))
        }
    }

    /// Turns a value into its stored form.
    func write(_ value: Value) throws(PreferenceError) -> PreferenceValue {
        let stored: PreferenceValue
        do {
            stored = try encode(value)
        } catch {
            throw .unencodable(key: name, reason: String(describing: error))
        }
        if case .unsupported = stored {
            throw .unencodable(key: name, reason: "the conversion produced an unsupported value")
        }
        return stored
    }
}

/// A stored value of a type other than the key's.
private struct TypeMismatch: Error, CustomStringConvertible {
    let expected: String
    let found: PreferenceValue

    var description: String { "expected \(expected), found \(found)" }
}

extension PreferenceKey where Value == Bool {
    /// A key for a Boolean.
    public init(_ name: String, default defaultValue: Bool) {
        self.init(
            name,
            default: defaultValue,
            encode: { .bool($0) },
            decode: {
                guard case .bool(let value) = $0 else {
                    throw TypeMismatch(expected: "a Boolean", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value == Int {
    /// A key for an integer.
    public init(_ name: String, default defaultValue: Int) {
        self.init(
            name,
            default: defaultValue,
            encode: { .int($0) },
            decode: {
                guard case .int(let value) = $0 else {
                    throw TypeMismatch(expected: "an integer", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value == Double {
    /// A key for a floating-point number. An integer stored under the name reads as a number
    /// too, since a property list does not keep the difference for whole values.
    public init(_ name: String, default defaultValue: Double) {
        self.init(
            name,
            default: defaultValue,
            encode: { .double($0) },
            decode: {
                switch $0 {
                case .double(let value): return value
                case .int(let value): return Double(value)
                default: throw TypeMismatch(expected: "a number", found: $0)
                }
            }
        )
    }
}

extension PreferenceKey where Value == String {
    /// A key for a string.
    public init(_ name: String, default defaultValue: String) {
        self.init(
            name,
            default: defaultValue,
            encode: { .string($0) },
            decode: {
                guard case .string(let value) = $0 else {
                    throw TypeMismatch(expected: "a string", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value == Data {
    /// A key for bytes.
    public init(_ name: String, default defaultValue: Data) {
        self.init(
            name,
            default: defaultValue,
            encode: { .data($0) },
            decode: {
                guard case .data(let value) = $0 else {
                    throw TypeMismatch(expected: "data", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value == Date {
    /// A key for a date.
    public init(_ name: String, default defaultValue: Date) {
        self.init(
            name,
            default: defaultValue,
            encode: { .date($0) },
            decode: {
                guard case .date(let value) = $0 else {
                    throw TypeMismatch(expected: "a date", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value: RawRepresentable, Value.RawValue == String {
    /// A key for an enumeration stored by its raw string. A stored string that is not one of the
    /// cases is an error, not the default.
    public init(_ name: String, default defaultValue: Value) {
        self.init(
            name,
            default: defaultValue,
            encode: { .string($0.rawValue) },
            decode: {
                guard case .string(let raw) = $0 else {
                    throw TypeMismatch(expected: "a string", found: $0)
                }
                guard let value = Value(rawValue: raw) else {
                    throw TypeMismatch(expected: "a known case", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value: RawRepresentable, Value.RawValue == Int {
    /// A key for an enumeration stored by its raw integer. A stored number that is not one of the
    /// cases is an error, not the default.
    public init(_ name: String, default defaultValue: Value) {
        self.init(
            name,
            default: defaultValue,
            encode: { .int($0.rawValue) },
            decode: {
                guard case .int(let raw) = $0 else {
                    throw TypeMismatch(expected: "an integer", found: $0)
                }
                guard let value = Value(rawValue: raw) else {
                    throw TypeMismatch(expected: "a known case", found: $0)
                }
                return value
            }
        )
    }
}

extension PreferenceKey where Value: Codable {
    /// A key for a small structure, stored as JSON bytes.
    ///
    /// Defaults are for settings, not for data that grows: keep the structure small. Changing its
    /// fields later makes older stored values undecodable unless the new fields are optional, so
    /// give the type a version field when its format is expected to change.
    public static func json(_ name: String, default defaultValue: Value) -> PreferenceKey {
        PreferenceKey(
            name,
            default: defaultValue,
            encode: { .data(try JSONEncoder().encode($0)) },
            decode: {
                guard case .data(let bytes) = $0 else {
                    throw TypeMismatch(expected: "data", found: $0)
                }
                return try JSONDecoder().decode(Value.self, from: bytes)
            }
        )
    }
}
