/// A single existing node adopted as one item of an `Arrangement` (C21/C22).
///
/// `Leaf` never creates a node, and never touches `node.style`/`node.appearance` directly — a
/// future resolver (C23) only ever mutates a separate effective copy for the snapshot (D04).
///
/// Ownership: borrows `node`; it does not take over the caller's ownership of it. Isolation:
/// MainActor. Errors: none. Cancellation: not applicable.
public struct Leaf: Arrangement {
    package let node: Node

    /// Adopts `node` as this leaf's item.
    ///
    /// Ownership: borrows `node`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ node: Node) {
        self.node = node
    }
}

/// A container whose items are laid out along the main axis in document order (C21/C22): a
/// future resolver (C23) applies `flexDirection: .row` to the owning node's effective style
/// (D04) and adopts each item as a managed child.
///
/// Ownership: borrows every item's referenced node. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
public struct Row: Arrangement {
    package let container: ArrangementContainer

    /// Creates a row from a builder block — sequence, `if`/`else`, optional `if`, and `for`
    /// are all supported (`ArrangementBuilder`).
    ///
    /// Ownership: borrows every item's referenced node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(
        spacing: Double = 0,
        justify: JustifyContent = .start,
        align: AlignItems = .stretch,
        padding: DirectionalEdgeInsets = DirectionalEdgeInsets(),
        @ArrangementBuilder _ content: () -> [Arrangement]
    ) {
        container = ArrangementContainer(
            spacing: spacing,
            justify: justify,
            align: align,
            padding: padding,
            items: content().map(lower)
        )
    }
}

/// A container whose items are laid out along the cross axis in document order (C21/C22): a
/// future resolver (C23) applies `flexDirection: .column` to the owning node's effective style
/// (D04) and adopts each item as a managed child.
///
/// Ownership: borrows every item's referenced node. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
public struct Column: Arrangement {
    package let container: ArrangementContainer

    /// Creates a column from a builder block — sequence, `if`/`else`, optional `if`, and `for`
    /// are all supported (`ArrangementBuilder`).
    ///
    /// Ownership: borrows every item's referenced node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(
        spacing: Double = 0,
        justify: JustifyContent = .start,
        align: AlignItems = .stretch,
        padding: DirectionalEdgeInsets = DirectionalEdgeInsets(),
        @ArrangementBuilder _ content: () -> [Arrangement]
    ) {
        container = ArrangementContainer(
            spacing: spacing,
            justify: justify,
            align: align,
            padding: padding,
            items: content().map(lower)
        )
    }
}

/// A container whose items stack on top of one another (C21/C22): a future resolver (C23)
/// lowers this directly onto the flexbox engine's existing `positionType == .absolute` support
/// — every item is measured, and defaults to the content-box origin unless `.offset(...)`
/// pins it elsewhere. No item is treated as sizing `self`; `self`'s size comes from the owning
/// node's own style/modifiers, exactly like `Row`/`Column` (D03: no responsive sizing off a
/// measured child in stage 1).
///
/// Ownership: borrows every item's referenced node. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
public struct Overlay: Arrangement {
    package let container: ArrangementContainer

    /// Creates an overlay from a builder block — sequence, `if`/`else`, optional `if`, and
    /// `for` are all supported (`ArrangementBuilder`).
    ///
    /// Ownership: borrows every item's referenced node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(
        padding: DirectionalEdgeInsets = DirectionalEdgeInsets(),
        @ArrangementBuilder _ content: () -> [Arrangement]
    ) {
        container = ArrangementContainer(
            padding: padding,
            items: content().map(lower)
        )
    }
}
