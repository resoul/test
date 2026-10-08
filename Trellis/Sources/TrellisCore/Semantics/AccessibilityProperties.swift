import Foundation

/// The semantic role an element reports to assistive technology (A03, D42 / A01 §3.1).
/// Deliberately small: every case has a mapping on both UIKit and AppKit, recorded with its
/// fallback in `docs/validation/a01-focus-accessibility-contract.md`. Text-editing roles are
/// not promised in this stage (no text input, N01). Ported from Weave's `AccessibilityRole`
/// minus `checkbox`/`slider`/`searchField` (no control types behind them here).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityRole: Sendable, Hashable, CaseIterable {
    case button
    case text
    case image
    case header
    case link
    case group
    case adjustable
}

/// How a node's descendants take part in the semantic tree (D42). Defined on examples with
/// visible children, unlike the source (defect #35 — Weave treated `.combine` like `.contain`
/// and let `.ignoreSelf` keep its own endpoint):
///
/// - `.contain` — this node is a container of its element descendants; with `isElement` and
///   no element descendants it is a leaf; with both it is a labelled group (A01 §3.2);
/// - `.combine` — one leaf, no separate children: the node's own label, or the descendants'
///   labels joined in reading order; descendants' states and actions are not merged;
/// - `.ignoreSelf` — the container relationship stays, this node itself is never an
///   endpoint, whatever `isElement` says;
/// - `.hide` — this node and its whole subtree are absent from the semantic tree. Keyboard
///   focus is unaffected (D37).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityChildrenPolicy: Sendable, Hashable, CaseIterable {
    case contain
    case combine
    case ignoreSelf
    case hide
}

/// A custom accessibility action: a stable `id` the node's handler switches on, and a
/// localized `name` assistive technology reads (D43). Two actions with the same `id` on one
/// node are one action.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityCustomAction: Sendable, Hashable {
    /// Stable identifier, independent of localization.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: String

    /// The name shown/read by assistive technology.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let name: String

    /// Creates a custom action.
    ///
    /// Ownership: strings are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// An action assistive technology can ask a node to perform (D43). `.activate` is the
/// default action of a `ControlNode`; `.increment`/`.decrement` belong to `.adjustable`
/// elements; `.custom` carries the `AccessibilityCustomAction.id`.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityAction: Sendable, Hashable {
    case activate
    case increment
    case decrement
    case custom(String)
}

/// Declarative semantics of one node for assistive technology (A03, D41/D42), independent
/// of focus and hit-testing. Stored on `Node.accessibility`; assigning an equal value is a
/// no-op. There is one source per fact (W07): enabled comes from `ControlNode.isEnabled`,
/// not from here; `isSelected` and `value` live here only. Ported from Weave's
/// `AccessibilityProperties` without `traits`/`state` duplication.
///
/// Ownership: a plain value. Isolation: none. Errors: a non-finite `sortPriority` is stored
/// as 0. Cancellation: not applicable.
public struct AccessibilityProperties: Sendable, Hashable {
    /// Whether this node is itself an element assistive technology can land on. A node that
    /// is not an element can still be a container of element descendants.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isElement: Bool

    /// The spoken name. A plain metadata string — no dependency on any text renderer.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var label: String?

    /// The spoken current value (a counter, a slider position).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var value: String?

    /// The spoken usage hint.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var hint: String?

    /// Automation identifier, never spoken.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var identifier: String?

    /// The role, or `nil` for the platform default: a control reads as a button, anything
    /// else as plain text or a group (A01 §3.1).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var role: AccessibilityRole?

    /// Selected state.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isSelected: Bool

    /// Reading-order rank among siblings — higher first; ties keep committed order (D42).
    /// Ownership: returns a value. Isolation: none. Errors: non-finite is stored as 0.
    /// Cancellation: not applicable.
    public var sortPriority: Double {
        didSet {
            if !sortPriority.isFinite { sortPriority = 0 }
        }
    }

    /// How descendants take part in the semantic tree.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var childrenPolicy: AccessibilityChildrenPolicy

    /// Standard actions this node handles besides a control's implicit `.activate`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var actions: [AccessibilityAction]

    /// Custom actions, in the order assistive technology lists them.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var customActions: [AccessibilityCustomAction]

    /// Creates accessibility properties.
    ///
    /// Ownership: strings and arrays are copied. Isolation: none. Errors: a non-finite
    /// `sortPriority` becomes 0. Cancellation: not applicable.
    public init(
        isElement: Bool = false,
        label: String? = nil,
        value: String? = nil,
        hint: String? = nil,
        identifier: String? = nil,
        role: AccessibilityRole? = nil,
        isSelected: Bool = false,
        sortPriority: Double = 0,
        childrenPolicy: AccessibilityChildrenPolicy = .contain,
        actions: [AccessibilityAction] = [],
        customActions: [AccessibilityCustomAction] = []
    ) {
        self.isElement = isElement
        self.label = label
        self.value = value
        self.hint = hint
        self.identifier = identifier
        self.role = role
        self.isSelected = isSelected
        self.sortPriority = sortPriority.isFinite ? sortPriority : 0
        self.childrenPolicy = childrenPolicy
        self.actions = actions
        self.customActions = customActions
    }
}
