# C12 — Flex measure/place и перенос регрессионных тестов

Дата: 2026-09-10. Самая крупная карточка на сегодня: полный порт flexbox
измерения и размещения из Weave, с переименованием по D11 и внедрением
D09/D10 контракта отмены.

## Что добавлено

- `Sources/TrellisCore/Layout/FlexboxMeasure.swift`: `LayoutMeasureCacheKey`,
  `FlexLineItem`, `FlexLine`, `FlexMeasureResult`, `FlexMeasureCache` (per-request
  LRU, линейный скан, capacity 64 — как у Weave, живёт один request, §3.8),
  `FlexboxEngine.measureContainer` (throws, `LayoutContext`), приватные
  `measure`/`resolveLines`/`intrinsicSize`, `BasisItem`, `FlexDirection.isHorizontal`.
- `Sources/TrellisCore/Layout/FlexboxPlacement.swift`: `FlexboxEngine.layoutContainer`
  (throws, `LayoutContext`), `mainDistribution`/`crossDistribution`,
  `FlexDirection.isReversed`. Округление использует уже существующий
  `LayoutFrame.rounded(to:)` (C06) вместо повторной реализации приватной
  функции Weave.
- `FlexSolver` → `FlexboxEngine` (D11); `resolvedLimit(_:)` не перенесён как
  отдельная функция — заменён существующим `SizeConstraintAxis.knownValue` (C10),
  идентичным по смыслу.
- D09/D10 контракт: `measureContainer`/`layoutContainer` — `throws`, принимают
  `context: LayoutContext = .noCancellation`. Checkpoints ровно там, где
  зафиксировано в decisions.md/§3.13: вход `layoutContainer` на каждом уровне
  рекурсии, граница каждой резолвленной flex-линии внутри `resolveLines`. Ни
  одной проверки на ребёнка — не добавлено намеренно (C31 решает, нужны ли
  более частые точки).
- `LayoutResult` (C11) получил `environmentRevision`/`contentRevision` —
  реальный производитель (`layoutContainer`) появился только сейчас; см.
  [ADR 0003](../adr/0003-c12-flexbox-port-api-changes.md).
- `LayoutInputSnapshot.style` получил дефолт `LayoutStyle()` — недосмотр C10,
  обнаруженный портом тестов Weave (`LayoutInputSnapshot(identity:children:)`
  без style ожидаемо компилируется). См. тот же ADR.
- Трассировка: `Log.on(.measure, CacheOutcome.hit/miss.rawValue, …)` — первое
  реальное использование `CacheOutcome` из C05 (до этой карточки — не имело
  потребителя). `Log.on(.place, "frame"/"ZERO-SIZE", …)` — нулевая ширина или
  высота помечается отдельно, по формулировке §3.10.

## Перенесённые тесты

Одиннадцать проверенных вручную verbatim-чтений источника Weave (не пересказ
агента) — `FlexSolver.swift` (480 строк) и `LayoutResult.swift` (321 строка)
целиком, плюс все шесть тестовых файлов целиком:

| Источник (Weave) | Тестов перенесено | Файл в Trellis |
|---|---|---|
| `FlexSolverTests.swift` (не было в исходной таблице переноса — просмотрен отдельно, как требует чек-лист) | 3 | `FlexboxEngineTests.swift` |
| `FlexSolverAlgorithmTests.swift` | 19 + 1 новый | `FlexboxAlgorithmTests.swift` |
| `FlexSolverFlexFeaturesTests.swift` | 7 | `FlexboxFlexFeaturesTests.swift` |
| `FlexSolverBaselineTests.swift` | 3 из 4 | `FlexboxBaselineTests.swift` |
| `LayoutResultTests.swift` (не упомянут в плане вообще — найден grep'ом, перенесён, т.к. тестирует ровно переносимую математику) | 3 | `FlexboxPlacementTests.swift` |
| `FlexMeasureCacheTests.swift` (тоже не упомянут в плане) | 4 из 5 | `FlexboxMeasureCacheTests.swift` |

Плюс 4 новых теста отмены (`FlexboxCancellationTests.swift`) и 1 новый тест
`maxWidth`-clamping (ни один Weave-тест не проверял max отдельно, хотя
алгоритм его всегда учитывал).

**Не перенесено, с причиной:**
- `test_snapshotBuilder_usesMeasurableNodeIntrinsicAndConstraint` (baseline suite) —
  завязан на `TextNode`/`TextLayoutBackend`, которых нет (N01).
- `test_layoutEngine_createsNewCachePerRequest` (cache suite) — тестирует
  Weave-планировщик `LayoutEngine(solver:)`; Trellis-эквивалент —
  `LayoutScheduler` (D11), появится в C13.

Все перенесённые геометрические ожидания сохранены **дословно** — ни одна
математическая правка не вносилась; единственные различия — identity
(`NodeID` вместо `UInt64`), способ построения `LayoutStyle` (`flexStyle(...)`
вместо отсутствующего в Trellis all-args инициализатора) и `throws`/`context`
на месте вызова.

## Проверки

| Проверка | Результат |
|---|---|
| `swift test` (207 тестов, включая 45 новых) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/adr/0003-c12-flexbox-port-api-changes.md` | UPDATED — см. ADR 0003 |
| `python3 Scripts/check_all.py` | PASS |

## Не засчитывается этим отчётом

`LayoutScheduler`, worker/отмена текущей Task, single-solver-per-host —
C13. `RenderCoordinator`/commit — C14. Реальные измерения задержки отмены на
широкой линии — C31.
