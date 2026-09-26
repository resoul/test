import LayoutCore

/// What an accessibility element is, for assistive technologies.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityTraits: OptionSet, Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: UInt

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let button = AccessibilityTraits(rawValue: 1 << 0)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let header = AccessibilityTraits(rawValue: 1 << 1)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let image = AccessibilityTraits(rawValue: 1 << 2)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let staticText = AccessibilityTraits(rawValue: 1 << 3)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let selected = AccessibilityTraits(rawValue: 1 << 4)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let notEnabled = AccessibilityTraits(rawValue: 1 << 5)
}

/// How a node presents itself to assistive technologies. Every field left `nil` keeps what
/// the node says by itself: text reads its text, a node with a tap action is a button named
/// by the text inside it, and a node with neither is not an element — its subnodes are.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Accessibility: Sendable, Hashable {
    /// `true` makes the node one element, whose subnodes are not read on their own; `false`
    /// leaves it out, reading its subnodes instead.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isElement: Bool?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var label: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var value: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var hint: String?
    /// Added to the traits the node has by itself.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var traits: AccessibilityTraits = []

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}
}

/// One element as assistive technologies see it, taken from the tree at its last layout.
/// Platform adapters turn these into `UIAccessibilityElement`s or `NSAccessibilityElement`s.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityItem: Sendable, Hashable {
    /// The node it stands for.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let node: NodeID
    /// In the root's coordinates.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let label: String
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let value: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let hint: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let traits: AccessibilityTraits
}
