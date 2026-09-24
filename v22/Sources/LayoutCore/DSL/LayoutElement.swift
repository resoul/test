import Foundation

/// An object a `LayoutSpec` places: a view, or anything else with a frame. The spec asks it
/// how its content measures and hands it its final frame.
///
/// Ownership: elements are owned by whoever created them (for views: their superview); a
/// spec only borrows them for one layout pass. Isolation: MainActor — elements are UI objects.
/// Errors: none. Cancellation: not applicable.
@MainActor
public protocol LayoutElement: AnyObject, LayoutSpecConvertible {
    /// How the element's content measures, or `nil` when it has none (its size then comes
    /// only from the spec's modifiers and from flex layout).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    var layoutContent: LeafContent? { get }

    /// Receives the element's frame, in the coordinate space of the rectangle the spec was
    /// applied in.
    ///
    /// Ownership: the element stores what it needs. Isolation: MainActor. Errors: none.
    /// Cancellation: none.
    func applyLayoutFrame(_ frame: CGRect)

    /// Shows or hides the element — called only for elements of specs that manage visibility
    /// (`hidden`, `invisible`, `Breakpoint`). The default does nothing.
    ///
    /// Ownership: the element stores what it needs. Isolation: MainActor. Errors: none.
    /// Cancellation: none.
    func applyLayoutVisibility(_ isVisible: Bool)
}

extension LayoutElement {
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    public func applyLayoutVisibility(_ isVisible: Bool) {}

    /// A spec that places this element as a single item.
    ///
    /// Ownership: the spec borrows the element. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var asLayoutSpec: LayoutSpec { LayoutSpec(element: self) }
}
