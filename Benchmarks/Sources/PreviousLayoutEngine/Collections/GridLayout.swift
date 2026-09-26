import Foundation

/// Column layout of a vertically scrolling grid (R12b, ADR 0033): how many columns fit the
/// width, the gap between them, and how tall a cell is. Rows are the scrolled unit; a row is
/// as tall as its tallest cell. Arbitrary grid solvers and masonry are out of scope (plan 6 §7).
///
/// Ownership: a value. Isolation: none. Errors: none — invalid numbers are clamped.
/// Cancellation: not applicable.
public struct GridLayout: Sendable, Hashable {
    /// How the column count is chosen.
    ///
    /// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Columns: Sendable, Hashable {
        /// Exactly this many columns (at least one).
        case fixed(Int)
        /// As many columns as fit with cells at least this wide (at least one).
        case adaptive(minimumWidth: Double)
    }

    /// How tall a cell is.
    ///
    /// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum CellHeight: Sendable, Hashable {
        /// Measured from the cell's node by layout, like a list row.
        case measured
        /// Cell width times this ratio; no measurement needed.
        case aspectRatio(Double)
    }

    /// Column rule.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var columns: Columns

    /// Gap between columns.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var columnSpacing: Double

    /// Cell height rule.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var cellHeight: CellHeight

    /// Creates a grid layout.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        columns: Columns,
        columnSpacing: Double = 0,
        cellHeight: CellHeight = .measured
    ) {
        self.columns = columns
        self.columnSpacing = columnSpacing
        self.cellHeight = cellHeight
    }

    /// Column count for a content width.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func columnCount(for width: Double) -> Int {
        switch columns {
        case .fixed(let count):
            return max(1, count)
        case .adaptive(let minimum):
            let gap = Self.clean(columnSpacing)
            let cell = max(1, Self.clean(minimum))
            let available = Self.clean(width)
            return max(1, Int(((available + gap) / (cell + gap)).rounded(.down)))
        }
    }

    /// Width of one cell for a content width and column count.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func cellWidth(for width: Double, columns count: Int) -> Double {
        let columns = max(1, count)
        let gaps = Self.clean(columnSpacing) * Double(columns - 1)
        return max(0, (Self.clean(width) - gaps) / Double(columns))
    }

    static func clean(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// The metrics item lengths and rows are resolved under; part of a preparation key.
struct CollectionMetrics: Sendable, Hashable {
    /// Viewport cross extent.
    let crossExtent: Double
    /// Items per row (1 for a list).
    let columns: Int
    /// Cross size of one item; the measurement key.
    let cellWidth: Double
    /// Fixed item length when cells use an aspect ratio.
    let fixedLength: Double?
    let estimatedLength: Double
    let spacing: Double
    let environmentRevision: UInt64

    init(
        crossExtent: Double,
        grid: GridLayout?,
        estimatedLength: Double,
        spacing: Double,
        environmentRevision: UInt64
    ) {
        self.crossExtent = crossExtent
        self.estimatedLength = estimatedLength
        self.spacing = spacing
        self.environmentRevision = environmentRevision
        guard let grid else {
            columns = 1
            cellWidth = crossExtent
            fixedLength = nil
            return
        }

        columns = grid.columnCount(for: crossExtent)
        cellWidth = grid.cellWidth(for: crossExtent, columns: columns)
        if case .aspectRatio(let ratio) = grid.cellHeight {
            fixedLength = cellWidth * GridLayout.clean(ratio)
        } else {
            fixedLength = nil
        }
    }
}

/// Item lengths and row positions for one snapshot under one set of metrics.
struct CollectionGeometry: Sendable, Equatable {
    let itemLengths: [Double]
    let rows: ItemExtentIndex
    let hits: Int
    let misses: [MeasurementInvalidation: Int]

    /// Resolves lengths from measurements (or the fixed/estimated length) and groups them into
    /// rows of `metrics.columns`, each as long as its longest item. Returns `nil` when
    /// `isCancelled` reports cancellation.
    static func resolve<ItemID, Item>(
        items: [CollectionItem<ItemID, Item>],
        cache: ItemMeasurementCache<ItemID, Item>,
        metrics: CollectionMetrics,
        isCancelled: (Int) -> Bool = { _ in false }
    ) -> CollectionGeometry? {
        var hits = 0
        var misses: [MeasurementInvalidation: Int] = [:]
        var lengths: [Double] = []
        lengths.reserveCapacity(items.count)
        for (step, item) in items.enumerated() {
            if isCancelled(step) { return nil }

            if let fixed = metrics.fixedLength {
                lengths.append(fixed)
                continue
            }

            switch cache.length(
                for: item.id,
                item: item.value,
                crossExtent: metrics.cellWidth,
                environmentRevision: metrics.environmentRevision
            ) {
            case .success(let length):
                hits += 1
                lengths.append(length)
            case .failure(let miss):
                misses[miss.reason, default: 0] += 1
                lengths.append(metrics.estimatedLength)
            }
        }
        let columns = max(1, metrics.columns)
        let rowLengths: [Double]
        if columns == 1 {
            rowLengths = lengths
        } else {
            rowLengths = stride(from: 0, to: lengths.count, by: columns).map { start in
                lengths[start..<min(lengths.count, start + columns)].max() ?? 0
            }
        }
        return CollectionGeometry(
            itemLengths: lengths,
            rows: ItemExtentIndex(lengths: rowLengths, spacing: metrics.spacing),
            hits: hits,
            misses: misses
        )
    }
}
