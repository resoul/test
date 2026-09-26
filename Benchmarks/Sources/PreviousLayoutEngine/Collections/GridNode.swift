import Foundation

/// A vertically scrolling, virtualized grid of arbitrary cell nodes (R12b, ADR 0033) — a
/// `CollectionNode` whose window lays items out in rows of `layout`'s columns. Loading hooks,
/// pagination, anchor preservation, budget and events are the same as `ListNode`'s. Changing
/// `layout` or the width reflows rows and keeps the anchor item in place.
///
/// Ownership: see `CollectionNode`. Isolation: MainActor. Errors: none. Cancellation: see
/// `CollectionNode`.
@MainActor
public final class GridNode<Provider: ItemProvider>: CollectionNode<Provider, Provider.Item> {
    /// Creates a grid over `source`. `rowSpacing` separates rows; `layout.columnSpacing`
    /// separates columns. `estimatedRowHeight` is used for unmeasured cells.
    ///
    /// Ownership: retains `source` and `provider`; creates its scroll node and window.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init(
        source: StateSubject<CollectionSnapshot<ItemID, Item>>,
        provider: Provider,
        layout: GridLayout,
        rowSpacing: Double = 0,
        estimatedRowHeight: Double = 120,
        pagination: PaginationPolicy = PaginationPolicy(),
        ranges: PreparationRanges = PreparationRanges(),
        maximumMaterializedCount: Int = 96,
        style: LayoutStyle = LayoutStyle()
    ) {
        super.init(
            source: source,
            provider: provider,
            transform: { $0 },
            grid: layout,
            estimatedLength: estimatedRowHeight,
            spacing: rowSpacing,
            pagination: pagination,
            ranges: ranges,
            maximumMaterializedCount: maximumMaterializedCount,
            style: style
        )
    }

    /// The column layout. Assigning reflows the rows and keeps the anchor item in place.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var layout: GridLayout {
        get { window.grid ?? GridLayout(columns: .fixed(1)) }
        set { window.grid = newValue }
    }
}
