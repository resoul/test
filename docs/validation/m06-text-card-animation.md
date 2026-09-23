# M06 — Реальная карточка с текстом

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §5, D65
поверх T07 ([t07-text-raster-layer.md](t07-text-raster-layer.md)); зависимости M04
([m04-layer-animator.md](m04-layer-animator.md)) и T07/T09 закрыты.

## 1. Что проверялось и почему нет изменений в `Sources/`

D65 (внешний слой анимирует геометрию/появление, внутренний raster layer никогда не получает
CA-анимацию и обновляется только через `applyDisplayArtifact`/`clearDisplayContent`) уже
реализован T07 и был перекрёстно согласован с ним в момент принятия D61–D69 (см. хвост блока
D49–D60 в decisions.md). M04/M05 добавили сам explicit animator и его lifecycle, не трогая
`update(node:...)`'s текстовую ветку. Чтение `LayerRenderer.update(node:...)` (§`if node is
TextNode`, строки materializeRasterLayer/raster.bounds/raster.position) подтвердило: raster layer
получает свои bounds/position внутри той же `CATransaction.setDisableActions(true)` транзакции,
что и остальная геометрия, и никогда не передаётся в `animator.reconcile`/`animator.snapAll` —
только внешний слой узла попадает в M04's таблицу. Раздельные пути D65 (T07) и D61–D69 (M04)
структурно не пересекаются: ни один не читает и не меняет состояние другого.

Три пункта карточки поэтому не про исправление кода, а про то, чтобы это доказать
детерминированными тестами, а не только чтением исходников — ровно то, что и просит план
(«доказано отсутствие покадрового CoreText; переход к финальной ширине и задержка готовности
текста видны в evidence»). Ни одного нового дефекта не найдено при этой проверке.

## 2. Новые тесты

`Tests/TrellisRenderTests/M06TextDisclosureAnimationTests.swift` — 4 теста, каждый через
настоящий `Node.animate` → `RenderCoordinator` (M03) → `LayerRenderer` (M04) на слое,
смонтированном под реальным окном (M02 §2's warm-up), плюс контролируемый `TextRasterizer`
(`ControllableRasterizer`, техника DisplaySchedulerTests.swift) там, где нужен управляемый
"задержанный worker":

- **`m06_resizeInsideAnAnimateScopeAnimatesTheOuterLayerButSnapsTheRasterAndKeepsItsOldBitmap`**
  — D65 поверх T07 с реальной анимацией: `label.animate(.easeOut) { label.style.height = 48 }`
  даёт настоящий `CABasicAnimation` на внешнем слое (`bounds.size.height`), а внутренний raster
  layer снапается к новому размеру без единой animation-записи (`raster.animation(forKey:) ==
  nil`) и сохраняет старый bitmap как есть (clipped, не растянут) — то же, что
  `TextRasterLayerTests.swift` уже проверяет без анимации в полёте, но теперь при активном
  переходе контейнера.
- **`m06_contentChangeInFlightClearsTheStaleBitmapWithoutDisturbingTheRunningGeometryAnimation`**
  — задержанный worker: пока внешний слой анимирует высоту (300 ms), меняется текст; старый
  bitmap убирается немедленно (`clearDisplayContent`, как в
  `TextContentChangeClearsRasterTests.swift`), геометрическая анимация при этом не трогается;
  когда контролируемый rasterizer (искусственная задержка 50 ms) наконец коммитит новый
  артефакт, анимация всё ещё активна и не была перезапущена или отменена поздним коммитом —
  доказывает независимость D64's animation token и D53/D58's display job lifecycle друг от
  друга.
- **`m06_rapidRepeatedPressesRetargetTheGeometryFromThePresentationValueNotFromAStaleModel`** —
  быстрые повторные нажатия: второй `animate` вызывается до завершения первого (оба — 30-секундная
  длительность, чтобы тест не мог случайно застать первую анимацию уже завершившейся и
  автоматически снятой, тот же приём, что `AnimationCommitLayerTests.swift`'s D63-тест); новая
  цель стартует от текущего видимого значения (D66), а не от исходных 24pt, и raster остаётся
  нетронутым (тот же bitmap, снап к финальному размеру) оба раза.
- **`m06_cardSiblingOrderAndClippingSurviveAnActiveTextGeometryAnimation`** — фон/текст/overlay
  как три сиблинга внутри карточки с `overflow: .hidden`: после и во время активной анимации
  текстового узла `cardLayer.sublayers == [backgroundLayer, outer, overlayLayer]` (raster никогда
  не входит в этот список — он вложен внутрь `outer`, что уже проверяет
  `test_siblingReorderNeverMovesTheRasterLayerOutOfItsOwnNode` в T07, здесь — при активной
  анимации), `cardLayer.masksToBounds == true`.

Гонка с реальным `CoreTextRenderer` не нужна для этих тестов: они проверяют геометрию/токены/
raster-layer contract, не корректность самого растра (это T05/T06/T07's область), поэтому
используется `PortableFallbackMeasurer`-путь по умолчанию (без установленного `textRenderer`,
T09) и лёгкий `ControllableRasterizer` вместо `CoreTextRenderer`.

## 3. Проверки

```text
TRELLIS_LOG=off swift test --filter M06
4 tests passed
```

```text
TRELLIS_LOG=off swift test
651 tests passed (was 647 before this card), no flakes
```

- `python3 Scripts/check_all.py` — PASS: policy/verifier unit tests, strict format,
  `-warnings-as-errors` library build + package test + external consumer, API baselines
  (macOS/iOS/tvOS, без изменений — эта карточка не меняет публичный API), 52 macOS screenshot
  сценариев, `TRELLIS_LOG` поведение.

Нет изменений в API baseline: карточка не добавляет и не меняет публичных символов.

## Приёмка M06

- D65 поверх T07 (move переиспользует bitmap, resize не растягивает glyphs, смена текста не
  принимает artifact со старым key) — done, подтверждено при активном M04-переходе, §2 первый
  тест.
- Disclosure длинного абзаца, быстрые повторные нажатия, задержанный worker — done, §2 второй и
  третий тесты.
- Фон и clipping внешнего слоя, внутренний растр и overlay имеют верный порядок — done, §2
  четвёртый тест.

Playground-сцена для этого сценария (S27, по плану) — часть M08, которая также сравнивает
bench-бюджет 1000 слоёв с текстом; в этой карточке визуальная evidence — только модульные тесты
на реальном windowed `CALayer`, без Simulator/скриншотов (структурный, не визуальный контракт).

Next card — M07 (взаимодействие и детерминированная готовность).
