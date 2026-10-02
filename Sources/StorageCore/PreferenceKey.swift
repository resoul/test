import Foundation

/// How a preference is held in a store: one of the plain kinds a property-list store such as
/// UserDefaults keeps natively. Codecs convert between a typed value and this form.
public enum PreferenceRepresentation: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    /// A stored value of a kind the codecs do not read, such as an array written by other
    /// code. It carries the name of the stored type for the error message.
    case unsupported(String)
}

/// Why a preference could not be written or read.
public enum PreferenceError: Error, Sendable {
    /// The value could not be turned into a stored form; nothing was written.
    case encodingFailed(key: String, underlying: any Error)
    /// A value is stored under the key but does not decode as the key's type. The stored
    /// value is left as it is; removing the key restores the default.
    case decodingFailed(key: String, underlying: any Error)
}

/// What a codec reports when the stored value is not the shape it expects.
public enum PreferenceCodecError: Error, Sendable, Equatable {
    /// The stored value has another kind than the codec reads.
    case typeMismatch(expected: String, found: String)
    /// A versioned value was written by another format version.
    case unsupportedVersion(found: Int, expected: Int)
}

/// Converts a preference between its typed value and its stored form.
public struct PreferenceCodec<Value: Sendable>: Sendable {
    public let encode: @Sendable (Value) throws -> PreferenceRepresentation
    public let decode: @Sendable (PreferenceRepresentation) throws -> Value

    public init(
        encode: @escaping @Sendable (Value) throws -> PreferenceRepresentation,
        decode: @escaping @Sendable (PreferenceRepresentation) throws -> Value
    ) {
        self.encode = encode
        self.decode = decode
    }
}

extension PreferenceRepresentation {
    fileprivate var kindName: String {
        switch self {
        case .bool: "bool"
        case .int: "int"
        case .double: "double"
        case .string: "string"
        case .data: "data"
        case .date: "date"
        case .unsupported(let type): type
        }
    }
}

extension PreferenceCodec where Value == Bool {
    public static var bool: Self {
        Self(
            encode: { .bool($0) },
            decode: {
                guard case .bool(let value) = $0 else {
                    throw PreferenceCodecError.typeMismatch(expected: "bool", found: $0.kindName)
                }
                return value
            }
        )
    }
}

extension PreferenceCodec where Value == Int {
    public static var int: Self {
        Self(
            encode: { .int($0) },
            decode: {
                guard case .int(let value) = $0 else {
                    throw PreferenceCodecError.typeMismatch(expected: "int", found: $0.kindName)
                }
                return value
            }
        )
    }
}

extension PreferenceCodec where Value == Double {
    /// Reads a stored integer as a double too, because a property-list store may hand back a
    /// whole number written as `2.0` as an integer.
    public static var double: Self {
        Self(
            encode: { .double($0) },
            decode: {
                switch $0 {
                case .double(let value): return value
                case .int(let value): return Double(value)
                default:
                    throw PreferenceCodecError.typeMismatch(
                        expected: "double",
                        found: $0.kindName
                    )
                }
            }
        )
    }
}

extension PreferenceCodec where Value == String {
    public static var string: Self {
        Self(
            encode: { .string($0) },
            decode: {
                guard case .string(let value) = $0 else {
                    throw PreferenceCodecError.typeMismatch(
                        expected: "string",
                        found: $0.kindName
                    )
                }
                return value
            }
        )
    }
}

extension PreferenceCodec where Value == Data {
    public static var data: Self {
        Self(
            encode: { .data($0) },
            decode: {
                guard case .data(let value) = $0 else {
                    throw PreferenceCodecError.typeMismatch(expected: "data", found: $0.kindName)
                }
                return value
            }
        )
    }
}

extension PreferenceCodec where Value == Date {
    public static var date: Self {
        Self(
            encode: { .date($0) },
            decode: {
                guard case .date(let value) = $0 else {
                    throw PreferenceCodecError.typeMismatch(expected: "date", found: $0.kindName)
                }
                return value
            }
        )
    }
}

extension PreferenceCodec {
    /// A value stored as its raw value, such as an enum with a string or integer raw type.
    /// A stored raw value that no case has fails to decode instead of becoming a default.
    public static func rawValue<Raw: Sendable>(over raw: PreferenceCodec<Raw>) -> Self
    where Value: RawRepresentable<Raw> {
        Self(
            encode: { try raw.encode($0.rawValue) },
            decode: {
                let stored = try raw.decode($0)
                guard let value = Value(rawValue: stored) else {
                    throw PreferenceCodecError.typeMismatch(
                        expected: String(describing: Value.self),
                        found: String(describing: stored)
                    )
                }
                return value
            }
        )
    }

    /// A small `Codable` value stored as JSON inside an envelope that records `version`.
    ///
    /// Bump `version` when the shape changes in an incompatible way: older data then fails
    /// to decode with ``PreferenceCodecError/unsupportedVersion(found:expected:)`` instead of
    /// being read as the new shape. Use it for small structures; large data belongs in a
    /// file or the database.
    public static func json(version: Int = 1) -> Self where Value: Codable {
        Self(
            encode: {
                .data(try JSONEncoder().encode(VersionedEnvelope(version: version, value: $0)))
            },
            decode: {
                guard case .data(let data) = $0 else {
                    throw PreferenceCodecError.typeMismatch(expected: "data", found: $0.kindName)
                }
                let found = try JSONDecoder().decode(EnvelopeVersion.self, from: data).version
                guard found == version else {
                    throw PreferenceCodecError.unsupportedVersion(found: found, expected: version)
                }
                return try JSONDecoder().decode(VersionedEnvelope<Value>.self, from: data).value
            }
        )
    }
}

private struct VersionedEnvelope<Value: Codable>: Codable {
    var version: Int
    var value: Value
}

private struct EnvelopeVersion: Decodable {
    var version: Int
}

/// The name, type, default and stored form of one preference. Declare keys once, as static
/// constants, and pass them to ``Preferences``.
///
/// ```swift
/// extension PreferenceKey where Value == Bool {
///     static let showsCompleted = PreferenceKey("showsCompleted", default: true)
/// }
/// ```
public struct PreferenceKey<Value: Sendable>: Sendable {
    public let name: String
    /// What reading gives while nothing is stored, and after the key is removed. It is never
    /// written to the store by itself.
    public let defaultValue: Value
    public let codec: PreferenceCodec<Value>

    public init(_ name: String, default defaultValue: Value, codec: PreferenceCodec<Value>) {
        self.name = name
        self.defaultValue = defaultValue
        self.codec = codec
    }
}

extension PreferenceKey where Value == Bool {
    public init(_ name: String, default defaultValue: Bool) {
        self.init(name, default: defaultValue, codec: .bool)
    }
}

extension PreferenceKey where Value == Int {
    public init(_ name: String, default defaultValue: Int) {
        self.init(name, default: defaultValue, codec: .int)
    }
}

extension PreferenceKey where Value == Double {
    public init(_ name: String, default defaultValue: Double) {
        self.init(name, default: defaultValue, codec: .double)
    }
}

extension PreferenceKey where Value == String {
    public init(_ name: String, default defaultValue: String) {
        self.init(name, default: defaultValue, codec: .string)
    }
}

extension PreferenceKey where Value == Data {
    public init(_ name: String, default defaultValue: Data) {
        self.init(name, default: defaultValue, codec: .data)
    }
}

extension PreferenceKey where Value == Date {
    public init(_ name: String, default defaultValue: Date) {
        self.init(name, default: defaultValue, codec: .date)
    }
}

extension PreferenceKey where Value: RawRepresentable<String> {
    /// A key for an enum with a string raw value.
    public init(_ name: String, default defaultValue: Value) {
        self.init(name, default: defaultValue, codec: .rawValue(over: .string))
    }
}
