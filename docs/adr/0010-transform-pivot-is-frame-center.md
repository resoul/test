# ADR 0010 — Pivot трансформа — центр frame

Дата: 2026-09-11. Закрывает дефект #30. Принято при согласовании
[implementation-plan-2.md](../implementation-plan-2.md) D17 (H01).

## Контекст

`LayoutTransform` был документирован как «affine transform used around a node
frame origin», и `inverseApplying(_:around:)` принимал pivot под именем
`origin`. `LayerRenderer.materializeLayer` при этом создаёт `CALayer()` с
`anchorPoint` по умолчанию `(0.5, 0.5)`, и `setAffineTransform` в
`applyPresentation` вращает и масштабирует слой вокруг **центра** frame.
`position` считается через `layer.anchorPoint`, поэтому сама геометрия слоя
была верна — расходились только контракт core и то, что рисуется.

Пока transform только рисовался, расхождение было невидимо: ни один вызов
`inverseApplying` в проекте не существовал, а тест
`test_layoutTransform_inverseApplyingReversesTranslationAndScale` передавал
pivot `(0, 0)` явно. Hit-testing по committed-снимку (H02b) будет считать
локальную точку core-математикой — и с origin-pivot попадал бы не туда, где
нарисовано, при любом rotation/scale.

## Решение

1. **Pivot — центр frame.** Документация `LayoutTransform` фиксирует: scale,
   затем rotation, затем translation, вокруг центра frame — того же pivot, что
   у `CALayer` с `anchorPoint (0.5, 0.5)`. Renderer не меняется; в
   `applyPresentation` добавлен комментарий, связывающий `anchorPoint` с
   контрактом, чтобы его не «оптимизировали» в `(0, 0)`.
2. **`around:` переименован семантически.** Внутреннее имя параметра
   `origin` → `pivot` в `inverseApplying(_:around:)`; внешняя метка `around:`
   и сигнатура не меняются — source-compatible, baseline фиксирует изменение
   текста декларации.
3. **Новые методы**, чтобы вызывающий не мог передать неверный pivot:
   `applying(_:around:)` (прямое преобразование, нужно для transformed AABB и
   тестов), `applying(_:in: LayoutFrame)` и `inverseApplying(_:in: LayoutFrame)`
   — pivot выводится из frame. Hit-testing использует `in:`-варианты.

Отвергнутая альтернатива: `anchorPoint = (0, 0)` в `materializeLayer` — одна
строка и ноль изменений в core, но вращение вокруг верхнего левого угла — не
то, чего ждут от UI-transform; `DebugOverlayRenderer` ставит `anchorPoint (0,
0)` только для служебных слоёв без transform.

## Последствия

- Визуальный контракт не изменился — то, что рисовалось, рисуется так же.
- `Tests/TrellisCoreTests/Layout/LayoutTransformTests.swift`: rotation 90°
  вокруг центра (угол `(10, 20)` → `(85, −5)`), non-uniform scale вокруг центра,
  round-trip scale+rotation+translation.
- `Tests/TrellisRenderTests/LayerRendererTests.swift`
  `test_layerRenderer_transformPivotMatchesLayoutTransformCenterContract`:
  `CALayer.convert(_:to:)` для углов и внутренних точек повёрнутого и
  неравномерно масштабированного слоя совпадает с
  `LayoutTransform.applying(_:in:)` с точностью 1e-6 — это и есть «визуальный
  + математический тест» из #30: геометрия CA сверяется с core, а не
  скриншот.
- API baseline `api/TrellisCore.json`: +3 символа, 1 изменённая декларация
  (имя параметра). Обновлён этой ADR как review note.
