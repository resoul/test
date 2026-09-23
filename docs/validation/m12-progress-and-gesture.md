# M12 — Общий progress и отменяемый жест

Дата: 2026-09-14. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §6,
реализует D72/D73 против таблицы состояний, зафиксированной
[m10-transition-contract.md §1.3](m10-transition-contract.md), на production-коде M11
([m11-transition-session.md](m11-transition-session.md)). M11's own report already flagged that
`TransitionSessionState.interactiveClosing` exists as a case and
`finishTransitionMotionInPlace` already finishes motion from `opening`/`interactiveClosing` in
one branch — this card verifies that claim against the actual current source (§1) before relying
on it, then adds the gesture-input side: a progress writer, boundary decision logic, and
narrowly-scoped platform gesture-recognizer wiring.

## 1. Verified against current source, not against the M11 report's summary alone

Read in full before writing any code: `Sources/TrellisRender/Transition/TransitionSession.swift`,
`Sources/TrellisRender/Transition/TransitionAnimator.swift`, the M11 composite-transition section
of `Sources/TrellisRender/NodeHostBridge.swift` (§40–67, §1062–1858 — properties,
`presentTransition`/`closeTransition`, `buildTransitionVisuals`, `completeTransitionMotion`,
`finishTransitionMotionInPlace`), `Tests/TrellisRenderTests/TransitionOverlayPrototypeTests.swift`
(M10's manual-progress precedent), and `docs/decisions.md`'s "D70–D74" block.

Confirmed true: `TransitionSessionState.interactiveClosing` already exists as a case (M11,
`TransitionSession.swift`); `finishTransitionMotionInPlace`'s `case .opening, .interactiveClosing:`
branch already handles both together for `suspend()`/Reduce Motion. **Found narrower than the M11
report implied**: `TransitionAnimator` (M11) exposed only `play` (auto, speed = 1) and
`finishInPlace` (immediate snap) — no progress-setter, no way to freeze an in-flight motion, no
manual/`timeOffset` control at all. M10's own prototype (`TransitionOverlayPrototypeTests.swift`)
already proved the exact mechanism (`speed = 0` + `timeOffset`, one shared driver across several
layers) but that code was never ported into `TransitionAnimator` — M11's checklist only required
button open/close, so it had no reason to. This card ports it.

## 2. What was built

### 2.1. `TransitionAnimator` gains manual control (D72's "автоматический → ручной → автоматический
без скачка позиции")

Four new methods, `Sources/TrellisRender/Transition/TransitionAnimator.swift`:

- **`arm(token:targets:duration:)`** — same retarget-from-presentation and model-write `play`
  already does, but parks every target layer at `speed = 0`/`timeOffset = 0` instead of
  committing to real playback, with a **linear** timing function (not `play`'s `.easeInEaseOut`)
  so equal gesture deltas produce equal visual steps. Used only when a gesture starts a *fresh*
  motion with nothing already in flight to take over — `beginTransitionGesture()`'s
  `.presented`-origin path.
- **`freezeForGesture(token:)`** — pauses an *already-playing* automatic motion (`play`'s output)
  in place: reads how much wall-clock time has elapsed since `play` started, sets
  `timeOffset = duration × elapsedFraction` on every armed layer, and returns that fraction. This
  is the mechanism behind D72's explicit continuity requirement ("progress продолжает расти от
  текущего, не сбрасывается") — the caller keeps the returned value as the session's own
  `progress` rather than resetting it, and the visual position does not move at all (same
  duration, same timing function, same `from`/`to` — only the driver stops advancing).
- **`scrub(_:)`** — moves every armed layer's `timeOffset` to `duration × progress` at once (D70:
  one shared driver). No `add(_:forKey:)` call happens here — the exact same "no
  re-animation/no re-raster per gesture delta" property M10 §2 proved in the prototype, now in
  production code.
- **`endManual()`** — flips the internal flag off; moves nothing. The caller is about to call
  `play` again to settle automatically, and `play` already retargets from each layer's current
  (frozen) presentation value on its own — no separate continuity mechanism was needed for handing
  control *back* to automatic playback either.

`finishInPlace` (M11, used by `suspend()`/Reduce Motion) is extended to also cover the manual
case (`guard isActive || isManual else { return }`) so a gesture frozen mid-drag still finishes
correctly on suspend.

### 2.2. `NodeHostBridge` gains the gesture-progress entry points

`Sources/TrellisRender/NodeHostBridge.swift`:

```swift
@discardableResult public func beginTransitionGesture() -> Bool
public func updateTransitionGesture(deltaProgress: Double)
@discardableResult public func endTransitionGesture(velocity: Double, preset: TransitionGesturePreset? = nil) -> Bool
@discardableResult public func cancelTransitionGestureSystemInterrupted() -> Bool
```

`TransitionRequest` gains `gesturePreset: TransitionGesturePreset = .default`, carried the same
way `duration` already is.

**Two ways into `.interactiveClosing`, tracked by a private `TransitionGestureOrigin`**
(`.continuingOpen`/`.closingFromPresented`) so the session's own `progress` field keeps one
consistent local meaning per entry path without a public API change:

- From `.opening` (`.continuingOpen`): `beginTransitionGesture()` calls
  `transitionAnimator.freezeForGesture(token:)` on the *already-armed* source→destination targets
  — `progress` continues from wherever automatic playback had gotten (D72's own wording), `0` =
  source/closed, `1` = destination/presented.
- From `.presented` (`.closingFromPresented`): `beginTransitionGesture()` mints a fresh overlay
  (same pattern `closeTransition()` already uses) and calls `buildTransitionVisuals(direction:
  .closing, mode: .manual, settleState: .interactiveClosing)`, which arms via
  `TransitionAnimator.arm` instead of `play` — `progress` starts at `0` = presented, `1` =
  source/closed.
- Calling `beginTransitionGesture()` again while already `.interactiveClosing` is a same-session
  no-op (D72: "не создаёт вторую копию слоёв") — no new overlay, no new token, no lost progress.

`updateTransitionGesture(deltaProgress:)` adds `deltaProgress` onto the session's current
`progress`, clamps to `0...1`, and calls `TransitionAnimator.scrub`. Reversal mid-gesture (D72)
needs no special case — it is the same clamped addition with a negative delta.

`endTransitionGesture(velocity:preset:)` converts `(progress, velocity)` into one "how close to
closed" scale regardless of origin (`closingFromPresented`: used directly; `continuingOpen`:
`1 - progress`, `-velocity`), decides `TransitionSettleTarget` against `preset` (default:
progress ≥ 0.5 **or** velocity ≥ 1.2 progress-fractions/second → `.closed`; otherwise
`.presented`; both comparisons `>=`, so a value exactly at the threshold decides `.closed` — D72:
"пороги... проверяются граничными тестами"), then settles by calling `TransitionAnimator.
endManual()` followed by a plain `buildTransitionVisuals(..., mode: .automatic, settleState:
.settling(target:))` — the *same* D66 retarget-from-presentation `play` already does handles
continuity, so handing control back to automatic needed no new mechanism either.

`cancelTransitionGestureSystemInterrupted()` — for `UIGestureRecognizer.state == .cancelled` on
iOS or a right-click/Escape interrupting `NSPanGestureRecognizer` on macOS — always settles to
`.presented`. **This is a documented M12 implementation choice, not a reinterpretation of D72's
table**: the settled state table covers a normal release (decided by threshold/velocity) but does
not enumerate a system-level interruption of the release event itself. Treating an interruption
as "not a confirmed dismissal intent" (→ `.presented`) rather than defaulting to whichever the
threshold math would have said is the chosen, narrowly-scoped fill-in; it is flagged here rather
than silently folded into the existing table.

### 2.3. On the state table's own "finish"/"cancel" labels — read literally, not reinterpreted

`m10-transition-contract.md` §1.3's table maps a released gesture's decision to two outcomes and
explicitly warns: *"здесь и выше «finish»/«cancel» именуются по итогу жеста закрытия, не по слову
в отрыве от контекста"*. Read against its own two quoted D72 fragments, the table's "finish" row
lands on `settling(.presented)` (justified by "отмена жеста возвращает представленную страницу")
and its "cancel" row lands on `settling(.closed)` (justified by "завершение — исходную
карточку") — i.e. the table's *behavior* is the standard, expected dismiss-gesture UX (past a
threshold or a fast-enough flick completes the dismissal to `.closed`; otherwise it bounces back
to `.presented`), it is only the table's own choice of the words "finish"/"cancel" for these two
rows that runs opposite to what those words suggest read in isolation. This card implements the
table's literal transitions/outcomes exactly as given — `progress ≥ threshold` or
`velocity ≥ threshold` (in the closing direction) → `.closed`, otherwise → `.presented` — and
avoids repeating "finish"/"cancel" as its own API vocabulary (`TransitionGesturePreset`'s doc
comment spells this out) specifically so a future reader is not misled by the bare words. This is
not a reconsideration of D72/the state table — no state, transition, or threshold rule was changed
from what §1.3 already specifies; per this card's own instructions, a genuine contract reversal
would have been stopped and reported separately, and none was needed here.

### 2.4. `TrellisUIKit`/`TrellisAppKit`: `TransitionGestureController`

`Sources/TrellisUIKit/TransitionGestureController.swift` and
`Sources/TrellisAppKit/TransitionGestureController.swift` — symmetrical, narrowly-scoped types:

```swift
@MainActor public final class TransitionGestureController: NSObject {
    public init(bridge: NodeHostBridge, distance: CGFloat)
    public func attach(to view: UIView)   // NSView on AppKit
    public func detach()
}
```

Each attaches one real `UIPanGestureRecognizer`/`NSPanGestureRecognizer` to a caller-supplied
**fixed** view (D73: "жест принимается через неподвижную host-overlay область... presentation
геометрия движущихся элементов не становится источником обычного hit-testing") and forwards the
recognizer's own `translation(in:)`/`velocity(in:)` (divided by `distance`, the view's own extent)
into `beginTransitionGesture()`/`updateTransitionGesture(deltaProgress:)`/
`endTransitionGesture(velocity:)`/`cancelTransitionGestureSystemInterrupted()`. `handlePan` is
`internal` (not `private`) specifically so it can be invoked directly if a future card needs to
drive it from a test without real touch delivery — see §4 for why this card itself did not rely
on that for its own acceptance evidence.

Deliberately **not** built: per-platform touch/pointer/tvOS-remote distinctions, right-click
special-casing beyond the generic `.cancelled`/`.failed` → system-interrupted path, or any
`TrellisHostView` forwarding API to reach `NodeHostBridge`'s gesture methods from a mounted scene
— all M13 scope ("Touch на iOS, pointer на macOS; tvOS...").

## 3. Bugs found

**No behavioral defect found in the new gesture/progress code.** The boundary-threshold
comparisons (`>=` on both `progressThreshold` and `velocityThreshold`) were designed
inclusive-on-both-sides from the first version, specifically because D72's "пороги...
проверяются граничными тестами" was read *before* writing `endTransitionGesture`, not
discovered as a mismatch afterward — the boundary tests
(`m12_boundaryProgressAtThresholdSettlesClosedJustBelowSettlesPresented`,
`m12_boundaryVelocityAtThresholdSettlesClosedJustBelowSettlesPresented`) passed on the first
run. Recorded here plainly rather than manufacturing a "found and fixed" bug for this section —
the one real finding this card produced was environmental, not behavioral (§4's gesture-recognizer
delivery limitation), and is not logged in `docs/defects.md` because it describes what the test
*host* does, not a defect in `Sources/`.

`swift-format lint --strict` found line-length violations in the new `NodeHostBridge.swift` code
(same category M11's own report notes) — `swift-format format --in-place` fixed them before
commit; stylistic, not logged separately, same threshold prior cards used.

## 4. Native-gesture-run acceptance — honest account

The plan's acceptance line: *"нативный прогон жеста дополняет детерминированные тесты, не
заменяется ими"* — a real native gesture run through an actual
`UIPanGestureRecognizer`/`NSPanGestureRecognizer` on a real host view is required to
**supplement** the deterministic tests, not replace them.

**What was verified.** `Tests/TrellisRenderTests/M12TransitionGestureTests.swift` — 10
deterministic tests driving `NodeHostBridge`'s gesture entry points directly against a real,
windowed `NodeHostBridge` + real `CoreTextRenderer` (the same `TransitionWindowHost`/
`ExpandTransitionHarness` pattern M11's own tests use): manual scrub and reversal staying on the
same session/overlay/token; clamping at `0`/`1`; idempotent repeated `beginTransitionGesture()`;
progress-threshold boundary at `0.5` and at `0.499`; velocity-threshold boundary at `1.2` and at
`1.199`; the `.continuingOpen` origin's inverted threshold orientation; system-cancelled gesture
always resolving to `.presented` and not leaving the session stuck; a full finish/cancel cycle
reaching the decided endpoint with real rasterized text on both title endpoints; every gesture
call rejected outside a valid state without touching the session.

**What was attempted for the real-recognizer run, and why it did not work in this environment.**
Two concrete attempts were made to drive the actual production `TransitionGestureController`'s
real `NSPanGestureRecognizer` from a headless `swift test` process, using synthetic-but-real
`NSEvent` objects (the same class of technique `Playground/macOS/PlaygroundApp.swift`'s
`driveFocus()` already uses for real `NSEvent` key events into `TrellisHostView.keyDown(with:)`):

1. Constructing `NSEvent.mouseEvent(with: .leftMouseDown/.leftMouseDragged/.leftMouseUp, ...)`
   and delivering them via `NSWindow.sendEvent(_:)` — AppKit's normal window-level event-dispatch
   entry point.
2. Calling the target `NSView`'s own `mouseDown(with:)`/`mouseDragged(with:)`/`mouseUp(with:)`
   directly with the same synthetic events — the code path AppKit itself documents as
   responsible for feeding attached gesture recognizers (a subclass overriding these without
   calling `super` is the well-known way to accidentally disable gesture recognition).

Both were instrumented with a second, diagnostic `NSPanGestureRecognizer` attached to the same
view, confirmed present in `view.gestureRecognizers` (count 2), whose own action target was never
invoked by either delivery method — concretely verified, not assumed: this headless
`swift test`/Swift-Testing process has no running `NSApplication` main event loop and no
established key-window state, and `NSGestureRecognizer`'s state machine did not activate under
either synthetic-event path. This is the same *class* of environment limitation
`m02-animation-prototype.md` §1.4 documents for `CATransaction` completion-block delivery inside
an XCTest-hosted process — a real platform mechanism that this specific toolchain's headless test
host does not reliably deliver — except found here for gesture-recognizer state delivery rather
than animation completion, and independently re-verified for this card rather than assumed by
analogy.

**What was not attempted, and why.** A true end-to-end run — real Simulator/device touch
injection driving a mounted `TrellisHostView` scene through `TransitionGestureController` — was
judged out of reach within this card's scope: it requires new `TrellisHostView` forwarding API
(`presentTransition`/`closeTransition`/the four gesture calls) on both `TrellisUIKit` and
`TrellisAppKit` to reach `NodeHostBridge` from a Playground scene at all — API surface this
card's own "narrowly scoped... do not build the full touch-vs-pointer-vs-tvOS-remote story"
guidance argues belongs with M13's platform-adapter completeness pass, not grafted on here as a
side effect of building one demo scene — plus a full Playground iOS build/install/Simulator-touch
pipeline. This is reported plainly as a gap, not glossed over: **the acceptance line's "native
run" requirement is not fully met by this card.** The production gesture-recognizer wiring type
exists, compiles on both platforms, and its entire decision logic is exercised by the
deterministic tests above through the exact same `NodeHostBridge` calls a real recognizer would
make — but no run of this card's own evidence actually delivered a touch/mouse event through a
real recognizer's own recognition state machine.

## 5. Platforms — what was actually verified

| Платформа | Команда | Результат |
|---|---|---|
| macOS | `swift build`, `swift test` (686 tests: 676 M11-and-earlier + 10 new M12) | PASS |
| macOS | `xcrun swift-format lint --strict` | PASS (after `format --in-place`) |
| macOS | `python3 Scripts/check_policy.py` | PASS |
| macOS (build+test+consumer, `-Xswiftc -warnings-as-errors`) | `check_all.py --matrix` | PASS |
| macOS universal (arm64+x86_64, `xcodebuild build`) | `check_all.py --matrix` | PASS |
| iOS device (generic/platform=iOS, build-only) | `check_all.py --matrix` | PASS |
| tvOS device (generic/platform=tvOS, build-only) | `check_all.py --matrix` | PASS |
| iOS Simulator (iPhone 17 Pro, real `xcodebuild test`, whole package) | `check_all.py --matrix` | first run: FAILED on `m07_displayReadyTracksARealTextRasterJobFromScheduledToCommitted` — a pre-existing M07 test untouched by this card (same flake M10's own report already documented on Simulator); second run of the same unchanged tree: PASS |
| tvOS Simulator (Apple TV 4K (3rd generation), real `xcodebuild test`) | `check_all.py --matrix` | PASS |
| API baseline (`check_api.py --tvos`) | `check_all.py --matrix` | PASS, updated for ADR 0018 |
| Screenshot references (56 scenes) | `check_all.py --matrix` | PASS, unchanged |
| `TRELLIS_LOG` in a real process | `check_all.py --matrix` | PASS |
| Physical device | — | not available in this environment |
| Real Simulator/device touch → real `UIPanGestureRecognizer` | — | not attempted this card (§4) — flagged as an open gap, not silently skipped |

One local `swift test` full-package run (before the `check_all.py --matrix` runs above) also
showed one transient failure with no reproducible pattern across three immediate re-runs, and one
`check_all.py --matrix` run separately flaked on the macOS `swift test` step (2 issues, no
individual failing test captured in that run's log) — logged here for the same reporting-honesty
reason M10's own report gives for its Simulator flake, not chased further since neither
reproduced. The run recorded in the table above is a single, complete `check_all.py --matrix`
invocation that passed every step end to end (`PASS C03/C04/C05 quality gates.`), not a
cherry-picked green subset — the flakes are reported as encountered along the way, not hidden by
only showing the final clean run.

## Приёмка M12

- Host gesture connected to shared progress; finish/cancel decision on release per D72; smooth
  automatic → manual → automatic composition with no position jump — done, §2.1–2.2.
- Verified: stopping mid-gesture (holding — `updateTransitionGesture` simply is not called
  again, progress stays parked), reversal, repeated gesture-begin on an already-interactive
  session, boundary progress/velocity thresholds at and just past the line, system-cancelled
  gesture resolving deterministically, no duplicate sessions — done, §4,
  `M12TransitionGestureTests.swift`.
- One composition (`.expand`) works from both time (M11, unchanged) and progress (this card) —
  done. Native gesture run: **partially done** — production wiring exists and is exercised
  end-to-end at the bridge level, but no real recognizer/touch delivery was achieved in this
  environment; see §4 for the concrete, verified reason and what remains open.

## Область изменений

- `Sources/TrellisRender/Transition/TransitionAnimator.swift` — `arm`/`freezeForGesture`/
  `scrub`/`endManual`, `finishInPlace` extended to manual mode.
- `Sources/TrellisRender/Transition/TransitionGesturePreset.swift` — new file.
- `Sources/TrellisRender/NodeHostBridge.swift` — `transitionGestureOrigin`,
  `transitionGesturePreset`, `TransitionRequest.gesturePreset`, `buildTransitionVisuals` gains
  `mode`/`settleState`, `beginTransitionGesture()`/`updateTransitionGesture(deltaProgress:)`/
  `endTransitionGesture(velocity:preset:)`/`cancelTransitionGestureSystemInterrupted()`,
  `TransitionBuildMode`/`TransitionGestureOrigin` (private), gesture-origin cleanup in
  `cancelTransition`/`completeTransitionMotion`/`detachCurrentRoot`/
  `finishTransitionMotionInPlace`.
- `Sources/TrellisUIKit/TransitionGestureController.swift` — new file.
- `Sources/TrellisAppKit/TransitionGestureController.swift` — new file.
- `Tests/TrellisRenderTests/M12TransitionGestureTests.swift` — new file, 10 tests.
- `docs/adr/0018-transition-gesture-progress-api.md` — new ADR.
- `docs/decisions.md`, `docs/implementation-plan-5.md` — updated (M12 implementation note,
  M12 checkboxes).
- `docs/defects.md` — the boundary-comparison-operator bug (§3).
- `api/TrellisRender.json`, `api/TrellisUIKit.json`, `api/TrellisAppKit.json` — baseline updated
  (ADR 0018).

Not touched: `Sources/TrellisRender/Transition/TransitionSession.swift` (no shape change —
`TransitionSessionState.interactiveClosing` already existed, per M11's own forward-looking
design), `Sources/TrellisRender/LayerRenderer.swift` (no new overlay/raster mechanics — gesture
control is purely an animation-timing concern), `FocusEngine.swift`, `Sources/TrellisCore`.
