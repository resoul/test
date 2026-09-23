# ADR 0033 — GridNode on the shared collection runtime

Date: 2026-09-23. Card: R12b, plan 6. Status: accepted. Builds on ADR 0030–0032.

## Context

Result C requires a grid with configurable columns and cell sizes on the same data, loading
and scroll runtime as the list, without a second copy (plan 6 §1.2, R12b). Masonry and
arbitrary grid solvers are out of scope (§7).

## Decision

- **Rows are the scrolled unit.** `MaterializationWindow` gains `grid: GridLayout?`. Items are
  grouped into rows of `columnCount`; a row is as long as its longest item (measured, or
  estimated until measured). `extents` is a row index (a list has one item per row, so list
  behaviour is unchanged); `itemOffset(at:)` and `itemIndex(at:)` give item-level positions.
  Windows are computed over rows and converted to item ranges, so visible/display ranges are
  whole rows; the materialization cap is divided by the column count.
- **Layout.** `GridLayout`: `.fixed(n)` or `.adaptive(minimumWidth:)` columns (at least one),
  `columnSpacing`, and `.measured` or `.aspectRatio(r)` cell height. Cells get an explicit
  width and a leading offset per column (RTL follows `leading`); aspect cells get an explicit
  height and are never measured. The measurement key's cross extent is the cell width, so a
  column change invalidates exactly the measurements that depend on it.
- **One geometry function.** `CollectionGeometry.resolve` turns cached/estimated item lengths
  into rows; both the synchronous rebuild and the worker preparation use it, and a prepared
  result is committed only under identical `CollectionMetrics` (cross extent, columns, cell
  width, fixed length, estimate, spacing, layout environment).
- **Anchor.** The anchor is the first item of the row at the viewport top; after a reflow
  (width, column rule, prepend) its row's top keeps its viewport position. No anchor is taken
  while the total extent is zero (defect #87).
- **Containers.** `CollectionNode` holds the whole runtime (scroll node, window, loader, update
  queue, dispatcher, hosting). `ListNode` and `GridNode` are thin final subclasses that only
  choose the layout; `GridNode.layout` can be changed at runtime.

## Consequences

Grids reuse loading hooks, pagination (item counts after the last visible row), budget,
transactions and hosting unchanged. Horizontal grids are not supported (`grid` is ignored on a
horizontal axis). `ListNode`'s members moved to `CollectionNode`; source compatibility holds
because `ListNode` inherits them.
