# ADR 0035 — Reveal by item ID and focusable table rows

Date: 2026-09-23. Card: R12, plan 6 (closing result C). Status: accepted. Builds on ADR
0030–0034, P6.9 and R07's scroll commands.

## Context

P6.9 requires `scrollTo(itemID:)` for known items, including items without a node, with an
explicit completed/cancelled/notFound result; a new command replaces the previous one and a
late result of an old reveal must not move the viewport. The containers had no such API. The
R12 standalone check on tvOS also showed that table rows could not take focus: the remote could
neither select a row nor move focus into rows below the screen.

## Decision

- **Reveal.** `CollectionNode.scrollTo(_:alignment:animated:completion:)` resolves the ID in
  the committed snapshot (`.notFound` otherwise, viewport untouched), then issues a
  `ScrollCommand.reveal` for the item's row frame from `ItemExtentIndex` through the new
  `ContainerHost.scrollContainer(_:_:completion:)`, which the bridge implements with its R07
  command path. Estimated lengths are corrected by repeating the reveal after the host commit
  that measured the item, until the reveal is a no-op and the item's committed frame matches
  its window position (at most 8 attempts; `reveal-unsettled` is logged past that). The
  result is `CollectionScrollResult`: `.completed`, `.cancelled` (a later reveal, another
  command on the scroll node, or user scrolling), `.notFound` (unknown, or removed before the
  reveal finished), `.notAttached` (not mounted, or detached meanwhile). Only the latest
  reveal's generation can resolve; the bridge's own supersede rule covers the native command.
  Loading a missing range stays the model's operation; the consumer reveals again after the
  snapshot is published.
- **Row focus.** A table row's content wrapper is a `ControlNode`: focusable by default, one
  activation for a tap, the remote's select, Return/Space and the accessibility activate
  action — all select the row. Directional focus reaches rows outside the viewport through
  the existing reveal-before-focus path (ADR 0028), because the window keeps a display margin
  of materialized rows beyond the viewport. The control's tap stays on the content, so a tap
  on a revealed action button is still not a row tap (ADR 0034).
- **Transient state after eviction.** A table's open swipe row closes when its row leaves the
  materialized window; selection is table/model state and is shown again when the row returns
  (P6.9).

## Consequences

`ContainerHost` gains a requirement (only the bridge implements it). Items in ListNode and
GridNode stay focusable only when the provider makes them so (for example a `ControlNode`);
the container does not impose focus on user content. Reveal of an ID the model has not loaded
is `.notFound` by design.
