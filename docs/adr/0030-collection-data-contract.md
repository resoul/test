# ADR 0030 — collection data contract and materialization window

Date: 2026-09-23. Card: R10, plan 6. Status: accepted. Containers that assemble these parts
(ListNode/GridNode/TableNode) are R12a/b/c.

## Context

Result C needs ListNode, GridNode and TableNode over one data and virtualization core
(plan 6 §1.2, P6.4, P6.7–P6.11). Weave's `VirtualizedView` inherited `ScrollNode`, bound
`CollectionDataSource` to Flux in the base type, reused nodes by a fixed reuse ID and
restored anchors by estimated heights (defect #64, `weave-scroll-analysis.md` §3/§7).
R06 showed that one native scroll view per page is the working composition for pager pages
(`r06-scroll-arbitration-comparison.md` §3).

User decisions of 2026-09-23: containers own a ScrollNode by composition; duplicate item IDs
are resolved first-wins with a log line; the default pagination trigger is two viewport
lengths.

## Decision

- **Composition.** A collection container owns a `ScrollNode` and a
  `MaterializationWindow` (TrellisCore). The window owns one `content` node sized to the whole
  run and absolutely positioned item nodes for the display window only. The window never
  subclasses `ScrollNode`; in a pager each page is a container with its own vertical scroll.
- **Data.** `CollectionSnapshot<ItemID, Item>` is the only source of counts and order:
  data key, producer revision, sections, stable IDs, load state. Duplicates are dropped
  first-wins across sections and counted; the container logs `commit dataset-applied …
  droppedDuplicates=N`. A new data key drops live nodes, measurements and pagination state.
  Item equality is the content revision.
- **Data source.** No new protocol: the reactive source is `StateSubject<CollectionSnapshot>`
  delivered by the mounted session's `bindState` (D14); a Flux stream reaches it through the
  existing `bindFlux` (R03). Core types do not import Flux. One subject per container, one
  subscription per mount.
- **Provider.** `ItemProvider` (MainActor) binds one `Content: Node` type: `makeNode`,
  `update`, `canUpdate`. `canUpdate == false` replaces the node; there is no cast and no
  cross-type reuse. Nodes stay with their item ID while the item is in the window and are
  disposed when it leaves. A reuse pool is not part of this slice.
- **Item state.** Durable UI state (expanded, selected) belongs to the model, keyed by
  `(dataKey, itemID)`, and reaches a node through its item model; a node disposed on leaving
  the window loses only transient interaction state. Removing an item from the snapshot is
  what ends its state. Making a node never starts a request.
- **Transactions (implemented in R11).** A full snapshot may replace a pending one; a delta
  applies only on a matching base revision, otherwise it is recomputed from the last
  committed snapshot. The anchor is item ID plus offset in the viewport; a removed anchor
  falls back to the nearest surviving neighbour in the old order, then clamps. Follow-bottom
  is opt-in. Offsets always come from `ItemExtentIndex` measured lengths (not #64's estimate).
- **Events.** `CollectionEventDispatcher` is the single path for closures and a weak
  `CollectionDelegate`: a set closure wins, otherwise the delegate is called, never both.
  Equal visible-ID lists and repeated phases are coalesced.
- **Windows.** `ItemExtentIndex` holds prefix sums over measured or estimated lengths.
  `VirtualizationWindow` derives visible, display (live nodes, capped by
  `maximumMaterializedCount`, visible items kept first) and preload ranges from
  `PreparationRanges` in viewport lengths, leading side by movement direction. Offset-only
  changes recompute the window without rebuilding extents.
- **Measurement.** `ItemMeasurementCache` keys a length by item ID and stores the model,
  cross extent and environment `layoutRevision` it was measured with (see Environment below).
  IDs absent from the snapshot are pruned.
- **Pagination.** `PaginationGate` is a value state machine separate from UI preparation:
  default `.remainingViewportLengths(2)`, optional `.remainingItems(n)` counted after the last
  visible item. One request per snapshot revision; completion without new items stalls until
  user scroll or retry; failure waits for explicit retry; `endReached` stops; at most
  `maximumAutomaticPages` without user scrolling.
- **Loading.** `CollectionLoader` (TrellisCore, Swift concurrency only) owns view-owned
  load tasks: `onLoad`/`onRefresh`/`onLoadMore`/`onRetry` are
  `@MainActor (CollectionLoadContext) async -> CollectionLoadResult`. Data goes through the
  `StateSubject`; the loader reads `source.current` synchronously so completion sees the
  snapshot the model published before returning, even while mounted delivery (D14) is
  deferred. Initial runs on activation while the phase is `.initial`, once per data key;
  refresh cancels an in-flight page; a data key change or deactivation cancels all tasks;
  retry repeats the failed operation (`onRetry` or its own hook). Models check
  `isCurrent(context)` after each `await`. `EffectOwner` stays in TrellisFlux: its keyed
  conflict policy does not express these cross-operation rules.
- **Host budget.** `MaterializationBudget` is shared by one host's windows: creations per
  pass and live item nodes across windows. Visible items are never refused; display margins
  compete by `MaterializationPriority` (active > adjacent > background, equal priorities
  rotate). A window's live allowance is the limit minus what equally or more urgent windows
  hold and minus less urgent windows' visible items; the limit is enforced at `beginPass()`.
  Hosts own separate budgets.
- **Diagnostics.** Windows and loaders log with `CollectionCorrelation` (host, render
  generation; `none` before mount). Data key, data revision, request ID and reason are
  details, never `gen`. Pagination logs decisions, not idle ticks.
- **Environment.** `EnvironmentKey.affectsLayout` (default `true`; `ThemeKey` is `false`,
  D52) feeds `EnvironmentSnapshot.layoutRevision`, which the measurement cache uses. Revisions
  come from one clock for all scopes (defect #81). Live rows that change structure on a theme
  change are re-measured by `recordMeasurements()` after their next layout.
- **Right-to-left.** On a horizontal axis in RTL, item 0 is at the trailing (right) end;
  the window converts the physical scroll offset into a logical one.

## Consequences

Live UI is bounded by the window and the cap, not by the model count (10 000-model tests).
Anchor compensation for corrected measurements, background diff/metrics preparation and
delta application are R11. Node measurement still runs in the host's normal layout pass;
a renderer-independent row measurement API is not introduced before measurements (P6.9).
The host bridge calling `beginPass()` and setting correlation is part of container mounting
in R12a.
