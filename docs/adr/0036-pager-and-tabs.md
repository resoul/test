# ADR 0036 — PagerNode, TabsNode and page state

Date: 2026-09-23. Card: R13, plan 6. Status: accepted. Builds on P6.5, P6.6, P6.9, ADR 0027
(native nesting), ADR 0029 (one gesture owner) and ADR 0032 (hosted containers).

## Context

Result D needs horizontal pages with stable IDs and a segmented switcher, usable standalone
(R13) and later inside `TabbedScrollNode` (R14). User decisions (2026-09-23): the pages are
moved by the pager's **own pan** (Telegram-style), not by a native paging scroll view; the
**selected page ± 1** are mounted.

A first implementation moved a page strip with a layer transform. On the iOS Simulator a
page's `ListNode` then kept its `UIScrollView` at the layout position — native views follow
neither a Trellis ancestor's transform nor its clipping (defect #91) — so the feed showed
outside the pager and vertical drags missed it.

## Decision

- **Vehicle.** `PagerNode` owns a horizontal `ScrollNode` with user scrolling off. Pages sit in
  a strip inside it, so page scroll views are native children of the pager's scroll view
  (ADR 0027): clipped by it and moved with its offset. The pager alone moves the offset:
  `.to(_, animated: false)` per drag tick, and a new `ScrollCommand.timed(_:animation:)` after
  release, which adapters run with the same Core Animation timing `LayerAnimator` uses
  (UIKit: a `bounds` animation on the scroll view's layer; AppKit: `NSAnimationContext` with the
  same timing function; spring curves map to their settling duration with ease-out there).
  `NativeScrollBacking` gains `scroll(to:animation:completion:)` and `presentedContentOffset`
  (defaults for other adapters); `ContainerHost.presentedScrollOffset(of:)` exposes the latter.
- **Pan.** `PagerPanRecognizer` begins when the first movement past 10 pt is at least as
  horizontal as vertical and the pager agrees; otherwise it fails and the page's own vertical
  scroll keeps the gesture. The pager refuses to begin while a mounted page's scroll is
  user-driven, and disables the mounted pages' scroll interaction for the pan (one owner,
  ADR 0029). A gesture moves at most one page and stops at the first and last page (no rubber
  band: bridge commands clamp to content). Release: velocity over 0.8 pages/s, else past half a
  page, selects the neighbour; otherwise it returns. Velocity is measured over the last 100 ms.
- **One model.** `progress` (`from`, `to`, `fraction`, `settled`) drives the pages and
  `TabsNode`: during a drag it follows the finger with no animation; on release the selection
  commits at once and progress is published with the settle `Animation`, which the tab
  indicator animates with — same duration and curve. A pan grabbing a settling pager starts
  from `presentedScrollOffset`. Reduce Motion settles without animation.
- **Selection.** `select(_:animated:)` for tabs and code; a page more than one step away slides
  in next to the current one and is moved to its real index after settling (no intermediate
  pages built). Reordering keeps the selection by ID; removing the selected page selects the
  page now at its index (else the last). Duplicate IDs keep the first. Resize keeps the page.
  RTL mirrors drag and placement.
- **Mounting and state (P6.9).** Pages are `Tab`s: a factory (`makeContent`) or an eager node.
  Factories run on mount only and must not start requests; eager nodes are detached, never
  disposed, on eviction. Mounted: selected ± 1 (only the selected page before the width is
  known). Before eviction every `PageStateRestoring` node of the page is asked for its state,
  kept by page ID and handed back in tree order to the rebuilt page. Collection containers keep
  their reading position (`CollectionPagePosition`: anchor item and distance from the top,
  restored by reveal once mounted); `TableNode` also keeps its selection.
- **Context and accessibility.** Pages get `RowSwipeContextKey = false`, so tables leave the
  horizontal gesture to the pager (P6.6; actions stay available through accessibility). Only
  the selected page is exposed to accessibility. `TabsNode` buttons are focusable
  `ControlNode`s (tap, remote select, Return/Space, AX activate) with the selected state.

## Consequences

The pager depends on the host's scroll command path; without a host the model moves and the
native offset follows at the next commit. Horizontal `ScrollNode` in RTL places content at
negative x (defect #90); the pager reverses its scroll row in RTL to keep the strip at the
physical left. macOS trackpad two-finger swipes are scroll-wheel events Trellis does not
route; on macOS pages change by click-drag and tabs. Per-page focus memory is not kept:
focus leaving the selected page falls back through the focus engine. `TabbedScrollNode`,
collapsing header and the vertical coordination are R14.
