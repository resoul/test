# ADR 0022 — `FluxStateBinding`/`NodeHostBridge.bindFlux`

Дата: 2026-09-14. Карточка R03 (`docs/implementation-plan-6.md`, P6.2). Зависимость: R02.

## Изменение

`Sources/TrellisFlux/FluxStateBinding.swift` — новый файл, один новый public type и
одно новое public API поверх уже существующего `NodeHostBridge` (не меняет ни одной
существующей декларации TrellisRender/TrellisCore):

```swift
@MainActor
public final class FluxStateBinding<Value: Sendable & Equatable> {
    public var isActive: Bool { get }
    public func cancel()
}

extension NodeHostBridge {
    @discardableResult
    public func bindFlux<Value: Sendable & Equatable>(
        _ flux: Flux<Value>,
        initial: Value,
        animation: @escaping @Sendable (Value, Value) -> Animation = { _, _ in .smooth },
        update: @escaping @MainActor (Value, Animation) -> Void
    ) -> FluxStateBinding<Value>
}
```

`api/TrellisFlux.json` gains `FluxStateBinding` (class + `isActive`/`cancel()`) as
`added` symbols. `NodeHostBridge.bindFlux` itself does not appear in any baseline —
see §"Известный пробел extraction" below.

## Почему поверх `StateSubject`/`bindState`, не отдельный delivery path

P6.2 explicitly requires this: "Сохраняем StateSubject как мост D14 в первом срезе."
R03's actual job is narrow — bridge `Flux`'s async, non-replaying values onto the
*existing*, already fully tested session-ownership/bounded-delivery/suspend-resume/
re-attach machinery `StateBindingRecordOf` gives a `StateSubject` (`StateBinding.swift`,
D14) — not re-implement any of that for Flux. `FluxStateBinding` is a thin object that:

1. Creates a private `StateSubject<Value>` seeded with `initial` (`Flux` has no
   synchronous current — P6.2: "новый binding принимает явное initial").
2. Runs one `Task` that reads `flux.stream` and calls `subject.send(value)` for each
   distinct value, checking `Task.isCancelled` right before acting on a value actually
   pulled off the stream (not only at the loop's top).
3. Registers the delivery closure through `bridge.bindState(subject:update:)` — every
   session concern (bounded latest delivery, suspend/resume, re-attach redelivering the
   current value, detach stopping delivery) comes from that call, unmodified.

`TrellisCore`/`TrellisRender` gain no Flux dependency or new API; the whole bridge
lives in `TrellisFlux`, matching R02/ADR 0021's module boundary.

## Найденный дефект в первой реализация: dropped binding stopped delivering silently

The first version returned `FluxStateBinding` without anything retaining it, and
`deinit` proactively cancelled the pump task. Any caller who did not keep the returned
value alive (a completely ordinary pattern — `bindState` itself explicitly documents
that dropping its returned `StateBinding` does **not** stop delivery, since the bridge
retains the real registration) saw the binding stop delivering after its first value,
silently, with no error. Found writing this card's own tests: every test that relied
on a *second* distinct value reaching `update` failed, while tests that only checked
the *initial* value or the *absence* of delivery passed — a false-positive-shaped
symptom that took a dedicated repro to isolate (see evidence report), not a hunch.

Fixed by making the closure `bindState` already retains (for as long as the underlying
registration is active, which is the bridge's job, per D14) also capture `self`
(`FluxStateBinding`) — the same ownership shape `bindState`'s own `StateBindingRecordOf`
already has for its `update` closure. This makes the bridge transitively retain
`FluxStateBinding`, and therefore its pump `Task`, until `cancel()` breaks the
resulting `self` ↔ `record` reference cycle — intentional, not an oversight, and
exactly `StateObservation`'s own already-documented "the holder must cancel explicitly"
contract, just one layer up. `cancel()` still stops both the pump and delivery
immediately; a dropped-without-cancelling binding now behaves like `bindState`'s own
handle, not like a silently-expiring one.

## Почему coalescing a burst is the producer's job, not this binding's

P6.2 says a coalesced burst uses "namerение последнего принятого состояния" and R03's
acceptance says a burst must not produce "commit на каждое значение." `bindState`
already satisfies this for a **synchronous** burst (multiple `StateSubject.send` calls
in one MainActor stretch with no `await` between them collapse to one delivery, D14) —
but a `Flux` producer's values do not usually arrive that way, and this card verified,
empirically, that they cannot be coalesced by the pump the way a synchronous burst is:

- `for await value in flux.stream`'s iteration is a genuine suspension every time —
  confirmed by direct repro (`docs/validation/r03-flux-state-binding.md` §"Burst
  coalescing проверено эмпирически"), not merely assumed from how `AsyncStream` is
  usually described. Even values already sitting in the stream's buffer are each
  redelivered through a full actor-queue round-trip.
- A delivery `Task` this binding's underlying `StateBindingRecordOf` schedules for
  value *N* is enqueued strictly before the pump's own next `next()` resumption for
  value *N+1* — so it reliably runs first, defeating any "check if already scheduled"
  coalescing attempted at the pump layer; the race is inherent to "task A schedules
  task B, then task A awaits again," not fixable by adding another layer of the same
  shape.
- Flux already ships `throttle`/`debounce` operators for exactly this: rate-limiting a
  fast producer is the producer's own composition, upstream of any sink, the same way
  a caller would use them before any other consumer. `bindFlux` does not re-implement
  this — its doc comment says so explicitly, and `test_fluxBinding_
  throttledUpstreamIsHowACallerCoalescesAFastProducer` proves the composed path works.

This is a real, load-bearing scope decision (not a shortcut): claiming `bindFlux`
itself coalesces an arbitrary fast producer would be false, and a test asserting it
would have been testing a coincidence of scheduling, not a guarantee.

## Известный пробел extraction (не эта карточка)

`Scripts/check_api.py`: `swift-symbolgraph-extract -module-name TrellisFlux` does not
report `NodeHostBridge.bindFlux` under any module's graph, with or without
`-emit-extension-block-symbols` — a module's public API added by extending a type
*owned by another module* is invisible to this baselining approach entirely. Verified
directly against both extraction modes on this toolchain (Swift 6.3.3). This is not
new to R03 — it is a property of the tool applied for the first time here, since R03
is the first card to add a cross-module extension. `check_policy.py`'s
`PUBLIC_DOCUMENTATION` rule (source-based, not symbol-graph-based) still requires and
enforces Ownership/Isolation/Errors/Cancellation on `bindFlux` and did catch it; a
future signature change to an extension method like this still needs a human reading
the diff, not just a green `check_api.py`. Documented in `check_api.py`'s own
`MODULES["TrellisFlux"]` comment so this is not rediscovered blind next time.

## Решение

Baseline обновлён через `check_api.py --module TrellisFlux --update --review-note
docs/adr/0022-flux-state-binding.md`.
