/// An object that describes the layout of its own subelements — a view whose
/// `layoutSubviews` (or `layout()`) applies `layoutSpec()`. Platform adapters give every
/// conforming view `applyLayoutSpec()` and measure it by its spec when it is placed inside
/// another spec.
///
/// Ownership: the provider owns the elements its spec mentions. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public protocol LayoutSpecProviding: AnyObject {
    /// The current layout, or `nil` for none. Called on every layout pass and measurement,
    /// so it builds a new value each time from the object's current state.
    ///
    /// Ownership: returns a value borrowing the provider's elements. Isolation: MainActor.
    /// Errors: none. Cancellation: none.
    func layoutSpec() -> LayoutSpec?

    /// The points of spacing steps (`.s1` … `.s9`) in this object's layout. The default is
    /// `SpacingScale.standard`; a theme returns its own.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    var layoutSpacing: SpacingScale { get }
}

extension LayoutSpecProviding {
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public var layoutSpacing: SpacingScale { .standard }
}
