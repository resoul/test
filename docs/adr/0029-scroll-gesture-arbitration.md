# ADR 0029 — scroll gesture ownership and transition close

Date: 2026-09-23. Card: R09, plan 6. Amended by [ADR 0037](0037-tabbed-scroll-coordination.md)
§5: one coordinator-driven momentum handoff from `TabbedScrollNode`'s outer scroll to the
selected page at the pin line; every other rule below is unchanged.

## Context

R07/R08 provide native nested scroll backings and publish their current geometry, but that
alone does not define which scroll view or transition owns a gesture at an axis conflict or
content boundary. A late offset callback cannot safely select an owner because native movement
has already begun.

## Decision

- Resolve candidates from the hit node toward its nearest scroll ancestor, then outward. Ignore
  disabled nodes and nodes whose configured axis does not match the dominant movement.
- Lock the dominant axis on the first meaningful drag delta for the whole gesture. Offer that
  axis component to one scroll owner. Report the perpendicular component and movement past the
  owner's boundary as unconsumed; never split one delta across two scroll nodes.
- Before capture, a scroll at its boundary is not eligible, so the nearest ancestor able to move
  may own the gesture. After capture, ownership remains fixed through the boundary. Native
  bounce may consume the visual remainder; it is not handed to another scroll view.
- Momentum belongs to the captured scroll owner. It cannot select a new owner or move a second
  scroll view. If no scroll captured the gesture, a momentum-only event is ignored.
- A presented transition may close from a downward, vertically dominant drag only when no
  eligible scroll ancestor can consume the matching content delta. Scroll wins ties and remains
  the sole owner for the whole gesture. Existing transition API calls without coordinates remain
  available for explicit programmatic gesture drivers; native controllers use the coordinate-aware
  entry point.

## Consequences

The pure arbiter returns the selected owner and the offered, consumed and unconsumed delta, so
platform adapters can preserve the same one-owner rule. The coordinate-aware transition entry
point makes scroll-versus-close arbitration before arming the transition driver. Platform input
still needs integration evidence for boundary handoff and momentum; the policy tests do not claim
to replace that native evidence.
