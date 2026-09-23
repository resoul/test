# ADR 0019 — `TrellisHostView` gains thin transition/gesture forwarding

Дата: 2026-09-14. Карточка M13 (implementation-plan-5.md §6), closes the concrete gap M12 left
open (`docs/validation/m12-progress-and-gesture.md` §4: "it requires new `TrellisHostView`
forwarding API... to reach `NodeHostBridge` from a Playground scene at all").

## Изменение

`TrellisUIKit`/`TrellisAppKit` — seven new public members on `TrellisHostView`, symmetrical on
both platforms, following the exact thin-passthrough shape M08 already established for
`sceneReadiness`/`waitUntilSceneReady`/`updateReduceMotion`:

```
extension TrellisHostView {
+   public var transitionSession: TransitionSession? { bridge?.transitionSession }
+   @discardableResult
+   public func presentTransition(_ request: NodeHostBridge.TransitionRequest) -> Bool
+   @discardableResult
+   public func closeTransition() -> Bool
+   @discardableResult
+   public func beginTransitionGesture() -> Bool
+   public func updateTransitionGesture(deltaProgress: Double)
+   @discardableResult
+   public func endTransitionGesture(
+       velocity: Double,
+       preset: TransitionGesturePreset? = nil
+   ) -> Bool
+   @discardableResult
+   public func cancelTransitionGestureSystemInterrupted() -> Bool
+}
```

`api/TrellisUIKit.json`/`api/TrellisAppKit.json` gain these as `added` symbols.
`NodeHostBridge`/`TransitionAnimator`/`TransitionSession` (ADR 0017/0018) are unchanged in shape.

## Почему this is a passthrough, not new decision logic

Every one of these seven members does exactly one thing: forward to the already-existing
`NodeHostBridge` method or property of the same name (`bridge?.foo(...)`), returning a safe
default (`false`/`nil`/no-op) when no bridge exists yet — the same shape `focus(_:)`/
`moveFocus(_:)`/`setFocusScope(_:)`/`sceneReadiness`/`waitUntilSceneReady(timeout:)` already use
on both host views. D72's decision logic (thresholds, state table, settle target) stays exactly
where M11/M12 already put it — `NodeHostBridge`, platform-neutral — this ADR adds no new
behavior, only a reachable entry point for it from a mounted `TrellisHostView`.

## Почему this was needed at all

M11/M12 built `presentTransition(_:)`/`closeTransition()`/the four gesture methods directly on
`NodeHostBridge`, which is `TrellisRender`-only and has no public initializer a consumer (a
Playground scene, or a real app) can reach — `TrellisHostView.ensureBridge()` creates and owns
the one bridge instance privately. Without this ADR's forwarding, nothing outside
`TrellisRender`'s own test target could ever call these methods on a real, mounted scene — M12's
own report names this exact gap as the reason it could not get a real
`UIPanGestureRecognizer`/`NSPanGestureRecognizer` run.

## Почему `TransitionGestureController` (ADR 0018) was not used to close this gap directly

`TransitionGestureController.init(bridge: NodeHostBridge, distance:)` still takes a raw
`NodeHostBridge`, which `TrellisHostView` does not expose (by design — the bridge is private,
consumers reach it only through the host view's own forwarding surface, same as every other
bridge capability). This card's own Playground evidence (S29,
`Playground/Shared/Scenarios/S29_ExpandTransitionPlatforms.swift`) attaches a real
`UIPanGestureRecognizer`/`NSPanGestureRecognizer` directly to the mounted `TrellisHostView` and
calls this ADR's four forwarding methods from its `@objc` handler — proving the exact same
`NodeHostBridge` call sequence `TransitionGestureController` would make, through the new public
surface, without widening `TrellisHostView`'s API to also expose its private bridge. Whether a
future card gives `TrellisHostView` its own `attachTransitionGesture(to:distance:)` convenience
wrapping `TransitionGestureController` is left open — not needed to close M12's gap, and out of
this card's scope (platform-adapter completeness, not new consumer-facing sugar).

## Реальные дефекты, найденные этим прогоном

Building and driving S29 in the iOS Simulator (real `xcodebuild`, real `UIPanGestureRecognizer`)
is what surfaced two real defects fixed in this same card — see `docs/defects.md` #53/#54:
`LayerRenderer`'s transition-hide mechanism was silently undone by the next unrelated commit
(#53), and handing a gesture-frozen layer back to automatic playback left it permanently paused,
so its completion never fired (#54). Neither was reachable from a deterministic test — both
needed a real, running host view and a real gesture recognizer, which this ADR's forwarding API
is what made possible to build at all.

## Решение

Обновить baseline через `check_api.py --update --tvos --review-note
docs/adr/0019-trellis-host-view-transition-forwarding.md`.
