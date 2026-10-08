import Foundation

/// A vertically scrolling, virtualized list of arbitrary item nodes with variable heights
/// (R12a, ADR 0030–0032) — a `CollectionNode` with one item per row.
///
/// Ownership: see `CollectionNode`. Isolation: MainActor. Errors: none. Cancellation: see
/// `CollectionNode`.
@MainActor
public final class ListNode<Provider: ItemProvider>: CollectionNode<Provider, Provider.Item> {
    /// Creates a list over `source`.
    ///
    /// Ownership: retains `source` and `provider`; creates its scroll node and window.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init(
        source: StateSubject<CollectionSnapshot<ItemID, Item>>,
        provider: Provider,
        estimatedLength: Double = 44,
        spacing: Double = 0,
        pagination: PaginationPolicy = PaginationPolicy(),
        ranges: PreparationRanges = PreparationRanges(),
        maximumMaterializedCount: Int = 64,
        style: LayoutStyle = LayoutStyle()
    ) {
        super.init(
            source: source,
            provider: provider,
            transform: { $0 },
            grid: nil,
            estimatedLength: estimatedLength,
            spacing: spacing,
            pagination: pagination,
            ranges: ranges,
            maximumMaterializedCount: maximumMaterializedCount,
            style: style
        )
    }
}
