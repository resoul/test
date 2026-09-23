# T03 — Измерение содержимого в solver

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует решение D49 ([decisions.md](../decisions.md)), принятое в T01 и подтверждённое
платформенно в T02 ([t01-text-contract.md](t01-text-contract.md),
[t02-raster-prototype.md](t02-raster-prototype.md)). Source-breaking часть — [ADR
0014](../adr/0014-content-measurer-and-display-dirty-reason.md), дополненная этой карточкой
разделом про `FlexMeasureResult.firstBaseline`. `TextNode`/CoreText — не эта карточка (T04/T05);
здесь измеритель — только `ContentMeasurer` протокол и детерминированный тестовый
`PortableFallbackMeasurer` (D51, дефект #40).

## 1. Что добавлено

- `ContentMeasurer` (`Sources/TrellisCore/Layout/ContentMeasurer.swift`) — Sendable-протокол
  с `identity: ObjectIdentifier`, `revision: UInt64`, `func measure(_:context:) throws ->
  LayoutContentMetrics`.
- `LayoutContentMetrics.measurer: (any ContentMeasurer)?` — новое поле, default `nil`.
  `Hashable`/`Equatable` теперь ручные (не auto-synthesized): равенство и хэш — по
  `(intrinsic, firstBaseline, measurer?.identity, measurer?.revision)`, не по структурному
  сравнению измерителя (ADR 0014).
- `FlexMeasureResult.firstBaseline: Double?` — новое поле, default `nil`; несёт РЕЗУЛЬТАТ
  измерения на конкретном constraint, не статическое значение снимка (дополнение ADR 0014).
- `FlexboxMeasure.measure()`: для листа (`input.children.isEmpty`) с `content.measurer != nil`
  измеритель вызывается с `constraint`, суженным на padding этого узла тем же способом, что
  `availableSpace` уже сужает для детей (`narrowed(_:by:)`); без измерителя —
  `measuredContent = input.content`, побитово прежнее поведение.
- `resolveLines`: `BasisItem.baseline`/`FlexLineItem.baseline` читают `firstBaseline` из
  СВЕЖЕГО результата измерения ребёнка (`nested`/`measured`), не из статического
  `child.content.firstBaseline` — актуально только для листьев с измерителем, для остальных
  значение то же самое (снимок не меняется без измерителя).

## 2. Как «три точки» §3.1 оказались одним местом в коде

План называл три точки вызова измерителя: базовый размер (`.unspecified` по main), финальная
ширина после grow/shrink (`.exact` по main), cross-size при `alignItems: .stretch`. Все три —
это не три отдельных места кода, а три РАЗНЫХ ЗНАЧЕНИЯ `constraint`, с которыми существующая
рекурсивная `measure()` уже вызывается из трёх существующих мест:

1. `measure()` самого родителя — `childConstraint` для basis-прохода.
2. `resolveLines` — `.exact(main)` после grow/shrink.
3. `FlexboxPlacement.placeContainer`'s `measureContainer(..., .exact(frame.width),
   .exact(frame.height))` — fallback, когда `reusableMeasure` не может переиспользовать
   growth-несовпадающий natural (`naturalMain != main`).

Поскольку измеритель вызывается ВНУТРИ `measure()` (после cache-проверки, до которой все три
вызова уже проходят), одно изменение в `measure()`'s leaf-ветке автоматически покрывает все
три точки — дополнительных call sites не потребовалось. Тест
`test_contentMeasurer_growingBeyondNaturalSizeRemeasuresAtTheExactGrownConstraint` форсирует
`flexGrow` именно чтобы дойти до третьей точки (`reusableMeasure` не совпадает) и подтверждает
`callCount >= 2` (basis + growth-exact), а не 1 при обычном stretch-без-роста случае.

## 3. `PortableFallbackMeasurer` — детерминированная тестовая модель (не типографика)

`Tests/TrellisCoreTests/Layout/PortableFallbackMeasurer.swift`. Модель: `charWidth = pointSize
× 0.6`, `lineHeight = pointSize × 1.2`, `baseline = lineHeight × 0.8` — произвольные
фиксированные коэффициенты, только для детерминизма (тот же текст и `pointSize` всегда дают тот
же результат), явно не заявка на реальную геометрию (снимает класс дефекта W03/#40: этот
измеритель никогда не сравнивается с CoreText). `callCount` — единственное мутируемое
состояние, за `OSAllocatedUnfairLock` (реальная синхронизация, не `@unchecked Sendable`/
`nonisolated(unsafe)` — запрет AGENTS соблюдён и в тестовом коде, не только там, где это
проверяет линтер).

## 4. Тесты и результаты

`Tests/TrellisCoreTests/Layout/ContentMeasurerTests.swift`, 7 тестов, зелёные на macOS
(`swift test`), iOS Simulator и tvOS Simulator (`xcodebuild test -only-testing:TrellisCoreTests`)
— 506/391/… тестов пакета в целом остаются зелёными на всех трёх платформах.

| Тест | Доказывает |
|---|---|
| `columnWidthDrivesWrappedHeight` | Тот же текст в колонке 120pt даёт БОЛЬШУЮ высоту, чем в 800pt — высота идёт от реально выделенной ширины (§3.3/W04), не от фиксированного значения снимка |
| `calledOnceForSoleChildOfDefaultStretchColumn` | Обычный случай (default `alignItems: .stretch`, одна дочерняя нода) — измеритель вызван **ровно один раз** за весь `layoutContainer` (measure + placement) |
| `baselineAlignmentUsesFreshMeasurerValueNotStaticSnapshot` | `alignItems: .baseline` выравнивает по СВЕЖЕМУ baseline из измерения (38.4 против 9.6 → смещение 28.8pt), не по статическому значению снимка |
| `alreadyCancelledContextThrowsBeforeCompletingAndDoesNotCount` | Лист с измерителем и уже отменённым `LayoutContext` — `throws`, `callCount == 0`; контраст с существующим `test_measureContainer_leafWithNoFlexLinesNeverChecksCancellation` (лист без измерителя вообще не имеет чекпоинта) — T03 добавляет НОВЫЙ чекпоинт, не меняя старый |
| `cancellationMidParagraphThrowsWithoutPartialResult` | Длинный абзац, отмена на второй проверке (после входа, до завершения построчного обхода) — `throws`, без частичного результата, `callCount == 0` |
| `growingBeyondNaturalSizeRemeasuresAtTheExactGrownConstraint` | `flexGrow` заставляет узел вырасти сверх natural-высоты — доходит до третьей точки (`.exact`/`.exact` fallback в placement), `callCount >= 2` |
| `sameConstraintIsServedFromCacheNotFromASecondCall` | Тот же `constraint`, тот же `FlexMeasureCache` дважды — второй вызов из кэша, `callCount == 1`, `cache.statistics.hits == 1` |

Полный пакет: 506 тестов (macOS `swift test`), включая существующие C12 (`FlexboxEngineTests`,
`FlexboxCancellationTests`, `FlexboxMeasureCacheTests`, …) — **без единого изменения** и без
единого падения: узлы без измерителя проходят через `measuredContent = input.content`
(byte-for-byte прежний путь), доказывая «узлы без измерителя — прежние результаты».

## 5. API baseline

`check_api.py --tvos` изначально показал `removed`/`added` для двух инициализаторов
(`LayoutContentMetrics.init`, `FlexMeasureResult.init` — mangled name меняется из-за нового
параметра со значением по умолчанию, как и предвидел ADR 0014/D59) плюс `added` для
`ContentMeasurer` и ручных `==`/`hash`. Обновлено командой `check_api.py --tvos --update
--review-note docs/adr/0014-content-measurer-and-display-dirty-reason.md` (ADR дополнен
разделом про `FlexMeasureResult.firstBaseline` перед обновлением). Повторный прогон —
`PASS TrellisCore (902 symbols)`, остальные модули не тронуты.

## Приёмка T03

- Узел с измерителем в узкой колонке получает высоту по выделенной ширине — done
  (`columnWidthDrivesWrappedHeight`).
- Количество вызовов измерителя на уникальный constraint == 1 за solve — done
  (`sameConstraintIsServedFromCacheNotFromASecondCall`, и `calledOnceForSoleChildOf...`
  для обычного случая без роста).
- Отмена посреди измерения не коммитит — done (`cancellationMidParagraphThrows...`,
  `alreadyCancelledContext...`) — ни частичного результата, ни засчитанного вызова.
- Узлы без измерителя — прежние результаты — done: весь набор C12
  (`FlexboxEngineTests`/`FlexboxPlacementTests`/`FlexboxCancellationTests`/
  `FlexboxMeasureCacheTests`/`FlexboxAlgorithmTests`/`FlexboxBasisTests`/
  `FlexboxBaselineTests`/`FlexboxFlexFeaturesTests`) зелёный без изменений на трёх платформах.
- Baseline через измеритель — done (`baselineAlignmentUsesFreshMeasurerValueNotStaticSnapshot`).
- Portable fallback-измеритель для тестов Core — done (`PortableFallbackMeasurer`), явно
  помечен как не-типографика, не используется и не сравнивается с CoreText.

Следующая карточка — T04 (`TextNode` в `TrellisCore`: `TextStyle`, атрибутированный документ,
раздельные `contentRevision`/`displayRevision`, измеритель из environment).
