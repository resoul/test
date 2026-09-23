# ADR 0021 — `TrellisFlux` target and the pinned Flux dependency

Дата: 2026-09-14. Карточка R02 (`docs/implementation-plan-6.md`, P6.1). Зависимость: R01
(`docs/validation/r01-flux-foundation.md`) и внешнее исправление Flux
[`e99f664`](https://github.com/resoul/flux/commit/e99f664) (release
[1.2.1](https://github.com/resoul/flux/releases/tag/1.2.1)), закрывающее дефекты #56–#59.

## Изменение

`Package.swift` — один новый external dependency и один новый target/product,
не меняющие существующие четыре:

```
dependencies: [
+   .package(url: "https://github.com/resoul/flux.git", exact: "1.2.1"),
],
products: [
    TrellisCore, TrellisRender, TrellisUIKit, TrellisAppKit,
+   TrellisFlux,
],
targets: [
    TrellisCore, TrellisRender, TrellisUIKit, TrellisAppKit (unchanged, no new deps),
+   TrellisFlux depends on TrellisCore, TrellisRender, and the Flux product,
    TrellisCoreTests, TrellisRenderTests,
+   TrellisFluxTests,
],
```

`Sources/TrellisFlux/TrellisFlux.swift` — new module. `api/TrellisFlux.json` gains two
`added` symbols: `TrellisFlux` (the enum namespace) and
`TrellisFlux.fluxVersion` (`public static let`). No existing baseline (Core/Render/
UIKit/AppKit) changes; `TrellisCore`/`TrellisRender`/`TrellisUIKit`/`TrellisAppKit`
target dependencies are unchanged and gain no `Flux` product dependency
(`Scripts/verify_bootstrap.py`'s `manifest_issues` now asserts this explicitly).

## Почему this was needed

Plan 6 (§1) needs Flux as a real SPM dependency to build ScrollNode/collections'
reactive data plumbing (P6.2–P6.11) on. R01 found Flux 1.2.0 unsafe to depend on as-is
(#56–#59: lost `CurrentValue` updates, a replay race, buffered delivery surviving
cancellation, and a stale `flatMapLatest` yield after switch) and required a fixed,
reviewed pin before R02 could proceed. That fix is now released as Flux 1.2.1, with
regression tests directly targeting each of the four scenarios
(`Tests/FluxTests/FoundationRegressionTests.swift` in the Flux repository).

## Почему a separate target, not adding Flux to an existing one

P6.1 requires TrellisCore to stay Foundation-only and TrellisRender's solver/raster
paths to gain no reactive runtime — Trellis's live-tree-on-MainActor architecture
(`docs/implementation-plan-6.md` §2) is unrelated to whether a reactive dependency
exists in the graph, and conflating the two would make that boundary unreviewable.
`TrellisFlux` is the only target with `import Flux`; a consumer opts in explicitly by
linking it alongside a platform host module, exactly as P6.1 describes. This ADR adds
only the module graph and a version marker — state delivery onto `StateSubject` (D14),
effect/action ownership (P6.2/P6.7) and animation intent are R03/R04's scope, not this
card's.

## Почему an exact pin, not a range

R01's evidence explicitly rejects `from: "1.2.0"` compatibility as an acceptance
criterion: a range can silently resolve to an unreviewed patch release with different
behavior. `exact: "1.2.1"` pins to the one commit this ADR's evidence and Trellis's own
test suite were actually run against. `Scripts/verify_bootstrap.py`'s
`manifest_issues` fails the build if the dependency becomes a range, a different URL,
or more than one external dependency — a regression here would otherwise pass CI
silently. Local development against an unreleased Flux checkout uses `swift package
edit Flux --path ../old/flux` (documented in README.md) rather than editing this
pinned manifest.

## Решение

Baseline обновлён через `check_api.py --module TrellisFlux --update --review-note
docs/adr/0021-trellis-flux-target.md`. `TVOS_PROBE` (`check_api.py`) is unchanged and
still refers to `TrellisUIKit`; `TrellisFlux` imports no platform UI framework, so it
gets a single macOS baseline like `TrellisCore`/`TrellisRender`, not a separate
per-SDK probe. `Scripts/verify_bootstrap.py --matrix` still builds/tests the whole
`Trellis-Package` scheme (`TrellisFlux` included) on iOS/tvOS destinations to confirm
the dependency itself resolves and compiles there, without a second baseline file.
