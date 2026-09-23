# ADR 0020 — `TransitionRoleMapping`/`TransitionRoleEndpoints` gain `interval`

Дата: 2026-09-14. Карточка M14 (implementation-plan-5.md §6), closes result B — the reusability
proof D74 exists for (two external-consumer Playground scenes, S30/S31,
`docs/validation/m14-close-result-b.md`).

## Изменение

`Sources/TrellisRender/NodeHostBridge.swift` and `Sources/TrellisRender/Transition/
TransitionSession.swift` — one new field, on both the request-side mapping and the
session-resolved endpoints, plus a matching constructor parameter with a default that keeps
every existing call site unchanged:

```
public struct TransitionRoleMapping: Sendable {
    public let role: Role
    public let source: NodeID?
    public let destination: NodeID?
+   public let interval: ClosedRange<Double>?
    public init(
        role: Role,
        source: NodeID?,
        destination: NodeID?,
+       interval: ClosedRange<Double>? = nil
    )
}

public struct TransitionRoleEndpoints: Sendable, Hashable {
    public let source: NodeID?
    public let destination: NodeID?
+   public let interval: ClosedRange<Double>?
    public init(source: NodeID?, destination: NodeID?, interval: ClosedRange<Double>? = nil)
}
```

`Sources/TrellisRender/Transition/TransitionAnimator.swift`'s `Target` (`internal`, not part of
the public surface) gains matching `beginProgress: Double = 0`/`endProgress: Double = 1` fields;
`play`/`arm` build a `CAKeyframeAnimation` instead of a `CABasicAnimation` only when a target's
range is not the default full one. `api/TrellisRender.json` gains these as `added` symbols
(`TransitionRoleMapping`/`TransitionRoleEndpoints` only — `Target` is internal, not in the
baseline).

## Почему this was needed

D70's own text (`docs/decisions.md`, quoted verbatim in
`docs/validation/m10-transition-contract.md` §1.1): "Все части используют единый progress 0…1,
**собственные интервалы и кривые внутри него**." M10 through M13 built and proved the "unified
progress" half of that sentence (`TransitionAnimator.scrub(_:)` moves every armed layer's
`timeOffset` together) but never the second half — every `Target` `play`/`arm` built before this
card used exactly the same `duration`/`timingFunction` for the whole session, with no way for one
role to occupy only part of the progress range. Building S31 (profile card→profile) honestly —
`bio` only starting to fade in once the avatar/name motion is past its own halfway point, per
M14's own checklist ("собственные интервалы и появления частей перехода") — surfaced this gap:
there was no way to express it from outside `Sources/TrellisRender` at all.

## Почему this is a small, narrowly-scoped addition, not new architecture

- The default (`interval: nil`, `beginProgress: 0`/`endProgress: 1`) reproduces M11–M13's
  behavior exactly — `makeAnimation` falls back to the original `CABasicAnimation` construction
  byte-for-byte whenever a target's range is untouched. Every existing test
  (`M10TransitionOverlayPrototypeTests`, `M11`–`M13TransitionLifecycleTests`, 37 tests total) and
  S29 pass unchanged with no edits to their own code.
- The mechanism reuses the *same* primitive the codebase already trusts for manual scrubbing —
  `speed = 0` + `timeOffset`, proven by M10's own prototype (`docs/validation/
  m10-transition-contract.md` §2) — rather than introducing a second timing system
  (`beginTime`/`CACurrentMediaTime()` staggering, the usual CA idiom for delayed sub-animations,
  was deliberately rejected: it needs a real wall-clock anchor to mean anything under real-time
  `play()`, and that anchor is incompatible with `scrub(_:)`'s shared `timeOffset` domain the
  moment a gesture takes over mid-session — see the doc comment on `TransitionAnimator.
  makeAnimation` for the full reasoning). `CAKeyframeAnimation`'s `keyTimes`, expressed as
  fractions of the *same* `duration` every other target in the session already uses, keeps every
  target's animation spanning the exact same local-time domain regardless of automatic playback
  or manual scrub.
- `Role` composition (D70's own settled answer, `docs/validation/m10-transition-contract.md`
  §1.1) already lets a second scene differ from a first through pure data — this ADR extends that
  same idea one field further (an *interval* is as much "composition of the transition" as which
  roles exist at all) rather than adding a parallel per-role configuration mechanism.
- No `coordinator`/`renderer` edit was made *for S31 specifically* — this field is generic,
  exists once, and S30 simply does not set it (its `body` role uses the default full range). Per
  D74's own wording ("Отличия второй сцены задаются данными/композицией перехода без правок
  coordinator/renderer"), this is exactly the legitimate exception the card's own instructions
  anticipated: a real API gap found by writing a second, genuinely different scene, closed once,
  narrowly, and then used by both scenes as data.

## Найденный и исправленный баг, до коммита

The first `CAKeyframeAnimation` construction used four `keyTimes` unconditionally
(`[0, begin, end, 1]`), including a duplicate `1` when `end == 1` (S31's `bio` role:
`interval: 0.5...1`). `Tests/TrellisRenderTests/M14TransitionCompositionTests.swift`'s own
`m14_roleWithoutASourceCounterpartHoldsUntilItsOwnLatterIntervalThenFadesOut` caught it
immediately: the animation stayed frozen at its starting value regardless of `timeOffset`, both
inside and past its own interval. Fixed by building `keyTimes`/`values`/`timingFunctions` without
a duplicate boundary keyframe (only the segments that actually exist are added) — see
`TransitionAnimator.makeAnimation`'s comment for the exact shape.

Separately (not a code bug, a test-harness one): a transition session's overlay layer is created
fresh by `beginTransitionGesture()`/`presentTransition(_:)` each time a *new* session starts from
`.presented` — reading `presentation()` on one of its sublayers immediately after, with no real
display pass yet, returns the pre-scrub value regardless of a correctly-set `timeOffset`. Same
class of finding M10 §2.3 already documented for a freshly created *window*; this is the same
requirement applied to a freshly created *layer* materialized mid-test. Fixed in the test file by
pumping once right after `beginTransitionGesture()`, not only after `presentAndComplete()`.

## Решение

Обновить baseline через `check_api.py --update --tvos --review-note
docs/adr/0020-transition-role-interval.md`.
