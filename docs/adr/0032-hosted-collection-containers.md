# ADR 0032 — hosted collection containers

Date: 2026-09-23. Card: R12a, plan 6. Status: accepted. Builds on ADR 0026, 0030, 0031.

## Context

`ListNode` lives in TrellisCore, but everything it needs from a mounted host — the mounted
session's state delivery (D14), commit notifications for measurements, the host's preparation
budget and a way to shift the native offset — lives in TrellisRender. P6.10/P6.14 require that a
consumer does not wire subscriptions, native offsets or commit callbacks by hand. Scroll commands
(`ScrollCommandIssuing`) are refused while the user drives a scroll view (R07 §8), so they cannot
carry anchor corrections during a drag or deceleration.

## Decision

- **Protocols in Core.** `HostedContainer` (a node the host serves: `hostDidAttach`,
  `hostDidCommit`, `hostDidDetach`), `ContainerHost` (host services: `hostID`,
  `materializationBudget`, `bindContainerState`, `adjustScrollOffset`) and `ContainerBinding`.
  `NodeHostBridge` implements `ContainerHost`; `StateBinding` is a `ContainerBinding`.
- **Discovery.** After every geometry commit (`onPostCommit`) the bridge walks the committed tree
  — the same discipline as its display scan — and diffs the containers it finds against the
  weakly held set: new ones get `hostDidAttach`, all present ones `hostDidCommit(generation)`,
  missing ones `hostDidDetach`. Host `detach()` detaches every container. Then it starts one
  budget pass.
- **State.** A container binds its `StateSubject` through `bindContainerState`, which is the
  bridge's `bindState` (D14: the mounted session owns the subscription). The container cancels
  the handle on `hostDidDetach` and binds again on the next attach.
- **Offset shifts.** `adjustScrollOffset(of:by:applied:)` queues a delta. The bridge applies all
  queued deltas right after the renderer committed geometry and content sizes, in the same
  synchronous commit, relative to the native offset at that moment, clamped to the new content,
  before hit-test and scroll-state publication. This keeps a running drag or deceleration's own
  movement and shows the content change and the shift in one frame. Because
  `RenderCoordinator` rejects commits whose live tree changed after the snapshot, the next
  accepted geometry commit always contains the mutation the delta compensates. `applied` runs
  before the native offset changes, so a synchronous scroll-state publish does not count the
  delta twice. Unlike a scroll command, a shift is not refused during user input.
- **ListNode.** A `Node` owning a `.column` vertical `ScrollNode` (ADR 0026: the scrollable axis
  is the flex main axis), the window, loader, update queue and dispatcher. The first snapshot of
  a data key is committed synchronously (first useful frame); later snapshots go through the
  worker queue. Scroll-state ticks feed the window (plus pending, not yet applied deltas), mark
  user scrolling for pagination, report phase and visible IDs and evaluate demand.

## Consequences

Consumers create a `ListNode(source:provider:)`, set loader hooks and put it in the tree; nothing
else. The tree walk per geometry commit is O(live tree), which windows keep bounded. UIKit and
AppKit apply a shift by setting the native content offset during the gesture; AppKit is covered
by a real `NSScrollView` test, UIKit by a Simulator XCUITest holding a real drag. A default
`ScrollNode` keeps `flexDirection = .row` while its axis is vertical (defect #84) — `ListNode`
sets `.column` explicitly; changing `ScrollNode`'s defaults is left for a decision.
