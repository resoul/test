/// Local identity of one shared element inside a composite card→page transition (D70, M11).
///
/// Deliberately `String`-backed and open, not a closed Swift `enum`: D74's second scenario
/// (M14, a profile-card transition) needs a different set of shared elements than `.expand`'s
/// `hero`/`title` — an open value type lets that composition live entirely in the data a
/// consumer passes to `NodeHostBridge.presentTransition(_:)`, with no change to
/// `TrellisCore`/`TrellisRender` (see `docs/validation/m10-transition-contract.md` §1.1 and
/// `docs/validation/m11-transition-session.md` §1). A role is local to one
/// `TransitionSession` — it carries no meaning outside the request that named it.
///
/// Ownership: a plain value. Isolation: none — `Sendable`. Errors: none. Cancellation: not
/// applicable.
public struct Role: Sendable, Hashable, RawRepresentable {
    /// The role's own name, unique within one transition request.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: String

    /// Creates a role from its name.
    ///
    /// Ownership: the string is copied. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a role from its name — the same value `init(rawValue:)` produces, offered as a
    /// shorter spelling at call sites (`Role("hero")`).
    ///
    /// Ownership: the string is copied. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(_ name: String) {
        self.rawValue = name
    }
}

extension Role: ExpressibleByStringLiteral {
    /// Ownership: the literal is copied. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension Role: CustomStringConvertible {
    /// Ownership: returns a new string. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var description: String { rawValue }
}

extension Role {
    /// The geometry-following shared container `.expand` (D74) moves from the source card's
    /// rectangle to the destination page's rectangle — position/bounds/cornerRadius, no text
    /// of its own. A convenience constant, not a case: any consumer can still construct
    /// `Role("anything")` for its own composition (M14).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let hero = Role("hero")

    /// The title text shared element `.expand` (D74) crossfades between its two endpoint
    /// rasters (D71).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let title = Role("title")
}
