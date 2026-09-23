# ADR 0031 — collection transactions and anchor preservation

Date: 2026-09-23. Card: R11, plan 6. Status: accepted. Builds on ADR 0030.

## Context

ADR 0030 fixed the transaction contract (full snapshot replaces a pending one, deltas only on a
matching base revision, anchor = item ID plus viewport position, neighbour fallback, opt-in
follow-bottom). R11 implements it so that updates arriving during drag or deceleration neither
move the row being read nor apply old indices to new data.

## Decision

- **Anchor.** The anchor is the item at the top edge of the viewport; its top keeps its
  position relative to the viewport (possibly negative, when the item starts above). If it was
  removed, the nearest surviving item of the old order keeps its position (by growing
  distance, the following item before the preceding one). Then the offset is clamped to the content. A new data key starts at offset 0.
  Follow-bottom, when enabled, wins only if the viewport was within `bottomTolerance` of the
  end. The same rule runs for commits, measurement corrections, estimate/spacing changes and
  cross-extent or layout-environment changes.
- **Adjustment.** Every such change returns a `CollectionAdjustment` (outcome, physical
  offset, clamped, changed) and calls `onOffsetAdjustment` when the offset moved. The
  container applies it to its `ScrollNode` without animation; right-to-left horizontal
  offsets are converted like ADR 0030's viewport mapping.
- **Preparation.** `PreparedCollection.prepare` runs on a worker over Sendable values: prunes
  measurements, resolves lengths, builds prefix sums and an ID diff (inserted, removed,
  updated, moved via longest increasing run), with cooperative cancellation every 512 items.
- **Commit.** `MaterializationWindow.commit` is atomic and rejects a result whose commit
  generation, cross extent, layout environment revision, estimate or spacing changed since
  preparation (`staleBase` / `staleMetrics`). Measurements recorded while the worker ran are
  kept (the current cache is pruned instead of replaced); a later correction repositions with
  the anchor. The anchor is captured at commit time, so viewport movement during preparation
  counts.
- **Queue.** `CollectionUpdateQueue` runs one preparation and keeps one waiting snapshot; a
  newer snapshot replaces the waiting one. A prepared result is committed even if a newer
  snapshot waits (progress under continuous updates), then the newer one is prepared. A
  rejected result is prepared again from the latest state. `detach()` cancels the worker and
  keeps its snapshot for `attach()`.
- **Deltas.** `CollectionDelta` is an ID-based helper for models that keep their own
  snapshot: `apply(to:)` throws `staleBase` unless the base revision matches, so a model
  recomputes from its last committed snapshot. The container itself only receives snapshots
  (D14 latest-value); it never applies index-based changes.

## Consequences

Order, identity, "no partial commit" and anchor stability within 0.5 pt are checked by a seeded
property test against a reference model (five seeds, 120 random prepend/append/delete/move/
height steps each); disabling anchor restoration makes it fail. Setting the native offset while
UIKit/AppKit decelerate is container work (R12a) and needs device evidence there.
`CollectionDelta.apply` locates IDs linearly per change; it is a model-side helper, not a hot
path.
