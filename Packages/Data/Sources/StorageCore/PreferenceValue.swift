import Foundation

/// A value as a preference store keeps it: one of the plain types a property list can hold.
///
/// `PreferenceKey` converts typed values to and from this form, so a store only has to
/// persist these cases.
public enum PreferenceValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)

    /// Something that a store found under the name but does not model, such as an array
    /// written by other code to the same defaults domain. The text names the stored type.
    ///
    /// A store reports this case when reading and never stores it; reading a key from it
    /// throws ``PreferenceError/undecodable(key:reason:)``.
    case unsupported(String)
}
