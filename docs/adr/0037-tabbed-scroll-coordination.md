# ADR 0037 — TabbedScrollNode: vertical coordination (Telegram model)

Date: 2026-09-23. Card: R14, plan 6. Status: accepted by the user (2026-09-23);
implementation — R14. Builds on P6.5, ADR 0026 (viewport), ADR 0027 (native nesting),
ADR 0029 (one gesture owner, amended below), ADR 0036 (pager and tabs). Source analysis:
[telegram-peerinfo-analysis.md](../telegram-peerinfo-analysis.md).

## Context

Result D needs the profile composition of plan §1.1: an arbitrary header Node, a segmented
switcher and a pager whose pages scroll independently, perceived as one vertical scroll that
collapses the header and pins the tabs (the Telegram video, §1.1.1). Three models were on the
table:

- **Relay** (TabBarPager, ProfilePage): one transparent scroll view drives the others by
  writing their offsets. Rejected in R06: the page is never the real owner of its gesture.
- **Header over pages** (R06's recommendation): each page is one scroll view with a top inset,
  the header is drawn over them and follows the selected page's offset. It needs Trellis
  layers painted above native scroll views; the renderer does not provide that today — a
  native scroll view sits outside its parent's layer (#92, same cause as #91), and a header
  moved by a transform would not move a scroll view inside it (#91).
- **Nested with a lock** (Telegram PeerInfo): an outer vertical scroll holds the header and
  a pager exactly one viewport tall; pages cannot scroll until the tabs are pinned. R06 showed
  that plain nesting does not collapse the header; the lock is what R06's experiment lacked.

The user chose the nested model (variant A) with two refinements: momentum handoff at the pin
line as a narrow exception to ADR 0029, introduced as a second step; and page positions that
survive header expansion except for the visible page.

## Decision

1. **Structure.** `TabbedScrollNode` is a `HostedContainer` that owns an outer vertical
   `ScrollNode`. Its content, top to bottom: the header (any Node with children, sized by
   layout), then the pager block — `TabsNode` and `PagerNode`. The pager block is exactly as
   tall as the outer viewport below the **pin line** (`pinInset` below the outer viewport's top;
   by default the part of the host's top safe area the viewport covers, see API). Pages are
   never measured by their content. So the outer
   content is `header + viewport − pin inset`, and its largest offset is the **pin offset**:
   the offset at which the pager block's top reaches the pin line. The 0.5H + 1H example of
   §1.1 holds literally.
2. **Tabs placement.** `.pinned`: the tabs are the top of the pager block; they scroll with
   the header and stop at the pin line because the outer cannot scroll past the pin offset.
   `.inline`: the tabs sit above the pager block and scroll away with the header; the pin
   offset is `header + tabs`. A bar pinned from the first frame is out of scope (P6.5).
3. **Lock.** The coordinator derives `isPinned` (outer offset at the pin offset, within one
   pixel) and a collapse progress `0…1` from the outer `ScrollState` on every published
   state, offset-only ticks included. While not pinned, the vertical scroll of every mounted
   page has `userInteractionEnabled == false`, so touches over a page drive the outer scroll.
   When pinned, pages are enabled. The lock only disables user scrolling; programmatic
   commands to a page still run. The lock must reach the native backing before the next touch
   can begin — it is not deferred to a later layout commit; R14 verifies this on UIKit and
   AppKit. The outer does not bounce at its bottom edge.
4. **Page scroll discovery.** A page exposes its vertical scroll explicitly (a
   `PageStateRestoring`-style protocol; collection containers and a vertical `ScrollNode`
   conform). No tree-depth heuristic. A page without one is static content clipped to the
   pager height. Exact names are fixed in R14.
5. **Momentum (step 2 of R14; amends ADR 0029).** Step 1 has no handoff: a fling that pins
   the header stops at the pin line. Step 2 adds one coordinator-driven exception: when the
   outer, decelerating after a user fling, reaches the pin offset with upward content velocity
   left, the outer stops there and the selected page continues with that velocity. Trellis
   computes the velocity itself — end-of-drag velocity and the platform deceleration model;
   no private API (Telegram reads `_verticalVelocity`). At every moment only one scroll view
   moves. The continuation is a programmatic motion: the next user touch cancels it, as any
   command (ADR 0026). There is no handoff from a page back to the outer, and no other ADR 0029
   rule changes. On macOS trackpad momentum is AppKit's own event stream; if the handoff cannot
   be reproduced there, macOS stops at the pin line and the evidence says so. tvOS moves by
   focus and needs no handoff.
6. **Page positions.**
   - While pinned, every page keeps its own offset; switching pages does not change it.
   - When the outer leaves the pin offset (the header starts to expand), the **selected**
     page is scrolled to its top: it stays visible and locked, so a deep offset would leave
     content that cannot be scrolled back until the header pins again. Inactive mounted pages
     keep their offsets; evicted pages keep their `PageState` (ADR 0036).
   - Selecting a page — by a tab or by a swipe settle — whose offset is not at its top while
     not pinned moves the outer to the pin offset with the pager's settle `Animation` (one
     model, ADR 0036).
   - A tab tap on the already selected page: if not pinned, pin; otherwise scroll the page
     to its top (Telegram's behavior).
7. **Reveal and focus.** A reveal or a focus move to a target inside a page while not pinned
   first moves the outer to the pin offset, then reveals inside the page — the ADR 0028 order,
   applied to the outer first.
8. **Refresh and loading.** Refresh belongs to the outer scroll at its top edge — the one
   owner P6.5 asks for. Page loading (`onLoadMore`, prefetch) stays with each collection
   container. Pages keep `RowSwipeContextKey = false` (ADR 0036).

## API (step 1, R14)

New public API, the review note for the `api/*.json` baseline update:

- TrellisCore: `TabbedScrollNode<ID>` (`header`, `pager`, `tabsNode`, `scrollNode`,
  `tabsConfiguration`, `pinInset`, `collapseProgress`, `isPinned`,
  `onCollapseProgressChange`, `pages`, `selection`, `select(_:animated:)`, `pinTabs(animated:)`,
  `expandHeader(animated:)`, `HostedContainer` methods); `TabsPlacement`
  (`.pinned`/`.inline`); `TabsConfiguration` (`placement`, `appearance`, `segmented(...)`);
  `PageScrollProviding` (`pageScrollNode`) with conformances of `CollectionNode` and
  `ScrollNode` (rule 4 — the exact names chosen here).
- TrellisCore: `ContainerHost.applyScrollConfiguration(of:)` with a default no-op in a protocol
  extension, so existing conformers keep compiling. An offset tick does not commit, and
  `ScrollNode.configuration` otherwise reaches the native view only at the next commit (#93);
  rule 3 needs it at once. `PagerNode` uses it for its drag freeze too.
- TrellisRender: `NodeHostBridge.applyScrollConfiguration(of:)` pushes the node's configuration
  to its backing.
- Behavior, no API: an `NSScrollView` backing with `userInteractionEnabled == false` passes the
  wheel up the responder chain instead of swallowing it, so a locked page leaves it to the outer
  scroll (the "wheel events on macOS" consequence below).

The pin line's default is the part of the host's safe area that the outer viewport covers,
computed from committed frames: the environment carries the host's insets unchanged, and a root
that folded them into its padding (the default) already keeps the viewport clear. The pages get
that covered safe area without its top edge.

## Consequences

- The consumer composes ordinary nodes; no native offset, KVO, gesture forwarding or cleanup
  in the scene. The coordinator writes a page offset only outside a user gesture (rule 6), and
  moves a second scroll view only in the step-2 handoff (rule 5).
- Known limitation, as in Telegram: from a pinned page, pulling down at the page's top does not
  re-expand the header in the same gesture; the header expands by dragging the tabs bar or any
  visible part of the outer content. Telegram also sends a new touch that lands on a page still
  bouncing back from its top to the outer; R14 may evaluate that, it is not required.
- Accessibility scroll actions on a locked page, and wheel events on macOS over a locked page,
  must reach the outer; R14 specifies and tests the route.
- Header over pages stays possible later, after the renderer maps ancestor transforms,
  clipping and z-order to native views (#91, #92) — a separate decision.
