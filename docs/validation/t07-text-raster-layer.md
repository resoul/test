# T07 — `LayerRenderer` и текстовый слой (`TrellisRender`)

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует D65 ([implementation-plan-5.md](../implementation-plan-5.md)) поверх
D52/D53 ([decisions.md](../decisions.md)). Зависит от T06
([t06-display-pipeline.md](t06-display-pipeline.md)).

## 1. Что добавлено

`Sources/TrellisRender/LayerRenderer.swift`:

- `rasterLayers: [NodeID: CALayer]` — отдельная таблица от `LayerRegistry`
  (внешний слой остаётся единственным NodeID↔layer lookup для hit-test/focus/
  AX; растровый слой не имеет собственной идентичности там).
- `materializeRasterLayer(for:host:)` — создаёт (или переиспользует) растровый
  `CALayer` как sublayer внешнего слоя ноды: `anchorPoint = (0, 0)`,
  `contentsGravity = .topLeft`, `masksToBounds = true`. Вызывается из
  `update(node:...)` для каждой `TextNode`, синхронизируя `bounds`/`position =
  .zero`/`contentsScale` с внешним слоем на каждом коммите.
- `rasterLayer(for:)` — публичный inspection hook.
- `applyDisplayArtifact(_:for:)` — коммитит bitmap (`contents`/
  `contentsScale`) в растровый слой внутри disabled-actions `CATransaction`;
  no-op для ноды без растрового слоя. Единственный потребитель —
  `DisplayScheduler.onArtifactCommitted`.
- `clearDisplayContent(for:)` — убирает bitmap немедленно (см. §2).
- `removeStaleLayers`/`unmount()` также вычищают запись растрового слоя —
  удаление внешнего слоя (sublayer) уже освобождает CALayer-иерархию;
  вычищается только Swift-словарь.

`Sources/TrellisRender/NodeHostBridge.swift`: `displayScheduler.onArtifactCommitted`
подключён к `renderer.applyDisplayArtifact` — недостающее звено, объявленное,
но не подключённое в T06.

## 2. Найденный и исправленный пробел: D65 требует немедленной очистки при смене контента, не только при resize

Первая версия карточки (до ревью) применяла новый bitmap так же для resize и
для смены текста/стиля/темы: старый bitmap просто оставался на месте, пока не
придёт новый. Для resize это ровно то, что требует D65 («при resize старый
bitmap сохраняется в своём размере и обрезается по content area до
готовности нового»). Но для смены самого контента D65 требует
противоположного: «если изменились текст/стиль/locale, старое содержимое
убирается; временная пустота допустима и замеряется, показывать прежние
данные как актуальные нельзя» — то же самое, что T02's прототип уже
зафиксировал тестом
(`t02_textChangeDropsStaleContentsInsteadOfShowingOldTextAsCurrent`).

Исправлено до коммита: `DisplayKey.hasEqualContent(to:)` сравнивает
`contentRevision`/`displayRevision`/`environmentRevision` (игнорируя
`size`/`scale`) — истинно только для чистого resize/rescale.
`NodeHostBridge.scanForDisplayWork` теперь вызывает
`LayerRenderer.clearDisplayContent(for:)` сразу, синхронно в момент коммита
геометрии, если предыдущий закоммиченный `DisplayKey` для ноды существовал и
`!hasEqualContent(to:)` — то есть контент (не только box) разошёлся. Для
чистого resize эта проверка не срабатывает, и старый bitmap остаётся видимым
(обрезанным/не заполняющим новый box), как и требует D65.

## 3. Тесты и результаты

19 новых тестов, весь пакет зелёный на трёх платформах:

| Платформа | TrellisCoreTests | TrellisRenderTests |
|---|---|---|
| macOS (`swift test`) | — | — (585 тестов пакета целиком) |
| iOS 26.5 Simulator | 419/419 | 163/163 |
| tvOS 26.5 Simulator | 419/419 | 163/163 |

- `Tests/TrellisRenderTests/TextRasterLayerTests.swift` (10), через
  `LayerRenderer` напрямую (`applyCommitted`/`applyLayoutResult` без реального
  solver): растровый слой материализуется, размерен и pinned к своим
  bounds; обычная `Node` растрового слоя не получает; `applyDisplayArtifact`
  трогает только растровый слой, не внешний; `applyAppearance`
  (paint-only reapply) не стирает bitmap; resize обновляет bounds, но не
  трогает старый bitmap (обрезан, не растянут); чистое перемещение не трогает
  растровый слой вообще (только позиция внешнего слоя); удаление ноды удаляет
  и её растровый слой; `skipsLayoutOnlyWrappers` не мешает тексту получить
  свой слой; переупорядочивание соседей не задевает растровый sublayer текста.
- `Tests/TrellisRenderTests/TextThemeRasterTests.swift` (1), через реальный
  `NodeHostBridge`: смена темы без единого изменённого поля `TextNode` всё
  равно даёт новый закоммиченный artifact (`DisplayKey.environmentRevision`,
  T06).
- `Tests/TrellisRenderTests/TextContentChangeClearsRasterTests.swift` (2), тем
  же путём: смена текста убирает bitmap сразу же на коммите геометрии, до
  того как новый растр вообще стартовал (проверено синхронно, без гонки с
  реальным `CoreTextRenderer` — `onPostCommit` вызывает scan/clear в том же
  вызове, что инкрементирует `committedCount`, до того как асинхронный
  `Task.detached`-worker успевает выполниться); чистый resize того же текста
  никогда не очищает bitmap, даже сразу после коммита.

## 4. Ручная/визуальная часть — не выполнена

Как и в предыдущих карточках без физического доступа к устройствам:

- «Пиксельная проверка одной строки на macOS (эталон)» — не выполнена; нужен
  screenshot-baseline процесс (`check_screenshots.py`), которого текстовые
  сцены Playground пока не имеют (N01 отдельно).
- «DebugOverlay поверх текста» — структурно не должно ломаться (`DebugOverlayRenderer`
  добавляет свой слой поверх `hostLayer`, минуя иерархию узловых
  внешний/растровый слоёв целиком), но визуально не проверено.
- «scale 1/2/3» — раздельно покрыто T05/T06's raster-тестами на уровне
  `CoreTextRenderer`/`DisplayArtifact`; end-to-end через реальный host на всех
  трёх масштабах не проверялось на устройстве.

## 5. API baseline

`check_api.py --tvos` показал только `added` для `TrellisRender`
(`LayerRenderer.rasterLayer(for:)`, `.applyDisplayArtifact(_:for:)`,
`.clearDisplayContent(for:)`, `DisplayKey.hasEqualContent(to:)`) —
`changed`/`removed` пусты, ADR не потребовался. Обновлено командой
`check_api.py --tvos --update --review-note docs/validation/t07-text-raster-layer.md`.

## Приёмка T07

- Внешний node layer + внутренний raster layer (D65); artifact применяется к
  `contents`/`contentsScale`/`contentsGravity`; `applyAppearance` не стирает
  bitmap; node-children sorting сохраняет raster layer — done, §1, тесты §3.
- Перемещение без resize не создаёт raster job (T06's `DisplayKey.size`
  неизменен → no-op в `schedule`); resize не растягивает bitmap (masksToBounds
  + contentsGravity); clipping не меняет overflow/семантику внешнего node
  layer (не тронуто) — done.
- `skipsLayoutOnlyWrappers` не затрагивается; DebugOverlay поверх текста — первое
  done и протестировано, второе — не проверено визуально (§4).

Следующая карточка — T09 (Environment в хостах: `TextRendererKey`/`LocaleKey`
на `attach`) — T08 (Accessibility текста) уже выполнена отдельным коммитом.
