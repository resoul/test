/// Why a preference could not be read or written.
public enum PreferenceError: Error, Sendable, Equatable {
    /// A value is stored under the key, but it cannot be read as the key's type: it has another
    /// type, or its content is not valid for this key. The key's default is not used in its
    /// place, so a damaged value stays visible; remove the key to return to the default.
    case undecodable(key: String, reason: String)

    /// The value could not be turned into something a store can keep. Nothing was written.
    case unencodable(key: String, reason: String)
}
