# ADR 0017 — `NodeHostBridge` получает `TransitionSession`/`presentTransition`

Дата: 2026-09-13. Карточка M11 (implementation-plan-5.md §6), реализует D70–D74
(`docs/decisions.md` «D70–D74», `docs/validation/m10-transition-contract.md`,
`docs/validation/m11-transition-session.md`).

## Изменение

`TrellisCore` — один новый открытый value-тип:

```
+public struct Role: Sendable, Hashable, RawRepresentable, ExpressibleByStringLiteral,
+    CustomStringConvertible
+extension Role { public static let hero: Role; public static let title: Role }
```

`TrellisRender` — новые публичные типы и один новый collaborator на `NodeHostBridge`:

```
+public struct TransitionRoleEndpoints: Sendable, Hashable { source: NodeID?; destination: NodeID? }
+public enum TransitionSettleTarget: Sendable, Hashable { case presented, closed }
+public enum TransitionSessionState: Sendable, Hashable {
+    case preparing, opening, presented, interactiveClosing
+    case settling(target: TransitionSettleTarget)
+}
+@MainActor public struct TransitionSession {
+    public let sourceNodeID: NodeID
+    public let destinationRootID: NodeID
+    public internal(set) var roles: [Role: TransitionRoleEndpoints]
+    public let overlayLayer: CALayer
+    public internal(set) var state: TransitionSessionState
+    public internal(set) var progress: Double
+    public internal(set) var token: UInt64
+}

extension NodeHostBridge {
+    public var transitionSession: TransitionSession? { get }
+    public struct TransitionRoleMapping: Sendable { role: Role; source: NodeID?; destination: NodeID? }
+    public struct TransitionRequest: Sendable {
+        source: NodeID; destinationRoot: NodeID; roles: [TransitionRoleMapping]; duration: Duration
+    }
+    @discardableResult public func presentTransition(_ request: TransitionRequest) -> Bool
+    @discardableResult public func closeTransition() -> Bool
+}
```

`api/TrellisCore.json`/`api/TrellisRender.json` gain these as `added` symbols;
nothing existing changes shape (`sceneReadiness`'s own type is unchanged — only
its *body* now also reads the new internal `isTransitionSessionInFlight`,
which is not part of the public surface).

## Почему `TransitionSession` — публичный `struct`, а не `class`/протокол

D71 (settled by M10, `m10-transition-contract.md` §1.2) already fixes the
shape: a value type, one optional property on the bridge, fields naming
identities (`NodeID`) rather than strong `Node` references, plus one
`LayerRenderer`-owned `CALayer` the session does not itself allocate outside
the renderer's own `beginTransitionOverlay(on:)`. A `class` would let a
consumer retain a session past the bridge's own lifecycle (detach/suspend
invalidate it); a `struct` read off `transitionSession` is a snapshot exactly
like `HitTestSnapshot`/`SemanticSnapshot` already are.

## Почему `Role` — не закрытый `enum`

Settled by D70/M10 (`m10-transition-contract.md` §1.1): a closed `enum` would
force a `Sources/` change the moment a second scenario (M14's profile-card
transition) needs a different role composition — exactly what D74 requires
*not* happen ("отличия второй сцены задаются данными/композицией перехода без
правок coordinator/renderer"). `Role` is `String`-backed and open, the same
shape convention identifiers elsewhere in this codebase already use for
"a stable name local to one caller's composition" rather than a closed set
`TrellisRender` itself enumerates.

## Почему `presentTransition`/`closeTransition` — два методы, не один toggle

The state table (D72 §1.3, `m10-transition-contract.md`) treats "open" and
"close by button" as reaching different states through different entry
conditions: `presentTransition` is valid from no-session or from any
in-flight state of the *same* `(source, destinationRoot)` pair (retarget);
`closeTransition` is valid only from `.presented`. Collapsing them into one
toggle would hide that asymmetry behind a single call site's own branching,
duplicating exactly the validation each method already does at its own entry.

## Почему `TransitionSession`'s геометрия не идёт через `LayerAnimator`

Settled by M10 (`m10-transition-contract.md` §3): a temporary overlay layer
has no `NodeID`, so it does not fit `LayerAnimator.active`'s
`(mountEpoch, NodeID, property)` addressing. M11 adds a small, internal
`TransitionAnimator` (`Sources/TrellisRender/Transition/TransitionAnimator.swift`,
not part of this ADR's public surface — it is never exposed outside the
module) that reuses the same two safety properties `LayerAnimator` already
proves (retarget from the live presentation value per D66; a stale
completion, from a superseded token, is a no-op) at the granularity D71
specifies: one token per **session**, not per `(layer, property)` — a
retarget invalidates the whole layer set's completion at once.

## Почему `sceneReadiness` не меняет its own type or public shape

Settled by M10 (`m10-transition-contract.md` §3's second open item): D69's
`animationReady` axis needed a second readiness source once session geometry
moved off `LayerAnimator`, or `waitUntilSceneReady` would report `true` mid-
transition. `NodeHostBridge.SceneReadiness` itself is unchanged (still three
booleans); `animationReady`'s *computation* now also consults a private
`isTransitionSessionInFlight` (true whenever a session exists and is not
`.presented`) — a parallel counter, not a change to `LayerAnimator`'s own API
or `SceneReadiness`'s public shape, so this line is `api/*.json`-invisible.

## Решение

Обновить baseline через `check_api.py --update --tvos --review-note
docs/adr/0017-node-host-bridge-gains-transition-session.md`.
