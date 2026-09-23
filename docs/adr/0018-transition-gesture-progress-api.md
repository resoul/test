# ADR 0018 — `NodeHostBridge` получает жестовый progress-control API

Дата: 2026-09-14. Карточка M12 (implementation-plan-5.md §6), реализует D72/D73
против таблицы состояний, зафиксированной `docs/validation/
m10-transition-contract.md` §1.3, на основании production-кода M11
(`docs/validation/m11-transition-session.md`).

## Изменение

`TrellisRender` — один новый публичный value-тип и четыре новых метода на
`NodeHostBridge`:

```
+public struct TransitionGesturePreset: Sendable, Hashable {
+    public let progressThreshold: Double
+    public let velocityThreshold: Double
+    public static let `default`: TransitionGesturePreset
+    public init(progressThreshold: Double, velocityThreshold: Double)
+}

extension NodeHostBridge.TransitionRequest {
+    public let gesturePreset: TransitionGesturePreset
+    // init(...) gains `gesturePreset: TransitionGesturePreset = .default`
}

extension NodeHostBridge {
+    @discardableResult public func beginTransitionGesture() -> Bool
+    public func updateTransitionGesture(deltaProgress: Double)
+    @discardableResult public func endTransitionGesture(
+        velocity: Double,
+        preset: TransitionGesturePreset? = nil
+    ) -> Bool
+    @discardableResult public func cancelTransitionGestureSystemInterrupted() -> Bool
+}
```

`TrellisUIKit`/`TrellisAppKit` — один new public type each, symmetrical:

```
@MainActor public final class TransitionGestureController: NSObject {
    public init(bridge: NodeHostBridge, distance: CGFloat)
    public func attach(to view: UIView)   // NSView on AppKit
    public func detach()
}
```

`api/TrellisRender.json`/`api/TrellisUIKit.json`/`api/TrellisAppKit.json` gain
these as `added` symbols; `TransitionSessionState`/`TransitionSession` (M11,
ADR 0017) are unchanged in shape — `.interactiveClosing` already existed as a
case.

## Почему progress/finish/cancel живут на `NodeHostBridge`, не на
`TransitionGestureController`

D73: "жест принимается через неподвижную host-overlay область... presentation
геометрия движущихся элементов не становится источником обычного
hit-testing" — the *decision* logic (D72: progress+velocity against a preset)
is platform-neutral render-layer logic, exactly where `presentTransition`/
`closeTransition` (M11) already live. `TransitionGestureController` is
intentionally thin: it reads a real gesture recognizer's own
`translation(in:)`/`velocity(in:)` against a **fixed** view and forwards
numbers into the same four `NodeHostBridge` calls a synthetic test driver
already uses — nothing about D72's decision is duplicated per platform, and
`TrellisCore`/`TrellisRender` stay UIKit/AppKit-free (AGENTS.md's own
"рендерер — один и платформо-нейтральный").

## Почему `arm`/`freezeForGesture`/`scrub`/`endManual` on `TransitionAnimator`
stay module-internal

Same reasoning ADR 0017 already gives for `TransitionAnimator` itself: it is
M11/M12's own explicit-animation mechanism, never exposed outside
`TrellisRender`. Manual (gesture) control is additive to the same class, not
a second animator — a session's overlay layers still have exactly one
explicit-animation owner regardless of whether they are currently playing
automatically or parked for a gesture.

## Почему `endTransitionGesture`/`cancelTransitionGestureSystemInterrupted` —
два метода, не один с параметром

D72's state table treats a normal release (decided by threshold/velocity) and
a system-level interruption (`UIGestureRecognizer.state == .cancelled`, a
right-click/Escape interrupting `NSPanGestureRecognizer`) as different events
with different resolution rules — the former runs D72's finish/cancel
decision, the latter always resolves to `.presented` regardless of progress
(a documented M12 implementation choice for an event D72's own table does not
enumerate — see `TransitionGesturePreset`'s doc comment and
`docs/validation/m12-progress-and-gesture.md`). Collapsing them into one call
with a flag would hide that the two are answering genuinely different
questions.

## Почему `TransitionGesturePreset` avoids the state table's own
"finish"/"cancel" words

`docs/validation/m10-transition-contract.md` §1.3 explicitly warns its
"finish"/"cancel" event labels are "по итогу жеста закрытия, не по слову в
отрыве от контекста" — read plainly, the table's "cancel" outcome is the one
that *completes* the dismissal (`settling(.closed)`) and its "finish" outcome
is the one that does not (`settling(.presented)`), the reverse of what the
bare words suggest out of context. `TransitionGesturePreset`'s API and doc
comments describe outcomes as `TransitionSettleTarget.presented`/`.closed`
instead of repeating "finish"/"cancel" as vocabulary, so a reader of this
public API is not left to independently rediscover the table's own caveat.

## Почему `distance` is a plain `CGFloat`, not a unit type

`TransitionGestureController` is deliberately the narrow, single-axis (one
recognizer, one distance, one delta computation) wiring this card's checklist
calls for — not `.expand`'s full consumer-facing gesture story (M13's "Touch
на iOS, pointer на macOS; tvOS..." item). A caller supplies the fixed
overlay region's own extent directly; there is exactly one call site
(`attach(to:)`) and no cross-platform unit ambiguity to abstract over yet.

## Решение

Обновить baseline через `check_api.py --update --tvos --review-note
docs/adr/0018-transition-gesture-progress-api.md`.
