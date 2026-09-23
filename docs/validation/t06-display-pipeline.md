# T06 — Display pipeline (`TrellisRender`)

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует D52/D53/D54/D58 ([decisions.md](../decisions.md)), зависит от T02
([t02-raster-prototype.md](t02-raster-prototype.md)) и T05
([t05-coretext-measurement.md](t05-coretext-measurement.md)). Применение
`DisplayArtifact` к `CALayer.contents` — не эта карточка (T07); T06 отвечает
только за то, чтобы у каждой видимой `TextNode` появлялся актуальный
закоммиченный bitmap, без layout snapshot/solve на пути.

## 1. Что добавлено

`Sources/TrellisRender/Display/`:

- `DisplayArtifact.swift` — bitmap-результат раста (`CGImage` + pixel size +
  scale), Sendable по D54 напрямую (без `Data`-копии).
- `DisplayKey.swift` — `DisplayKey` (contentRevision/displayRevision/
  environmentRevision/size/scale) и `TextDisplayRequest` (переиспользует
  `TextLayoutInput` целиком + финальный size + resolvedColor + scale) —
  значение, которое пересекает границу изоляции в фоновый worker (D49's
  паттерн, применённый к растру).
- `TextRasterizer.swift` — протокол `TrellisRender` (не `TrellisCore`: `CORE_IMPORT`
  запрещает `CGImage` в Core), `rasterize(_:context:) throws -> DisplayArtifact`.
- `DisplayScheduler.swift` — планировщик: один активный + один согласованный
  pending job на ноду, общий `maxConcurrency` бюджет на все ноды сразу,
  committed-таблица, статистика scheduled/started/completed/cancelled/dropped/
  stale.

`Sources/TrellisRender/Text/CoreTextTypesetter.swift`: новый `rasterize(request:context:)`
переиспользует `makeAttributedString`/`makeFont`/`makeParagraphStyle` измерения
(T05) — единая логика построения шрифтов/paragraph style для measure и raster;
`makeAttributedString` получил параметр `resolvedColor: ThemeColor?` (`nil` для
measure — цвет не влияет на границы, non-nil для raster — устанавливает
`kCTForegroundColorAttributeName` по каждому run с учётом run-level `color`
override). `CoreTextRenderer` теперь конформит и `TextRenderer` (T05), и
`TextRasterizer` (T06).

`Sources/TrellisRender/NodeHostBridge.swift`: владеет `DisplayScheduler`,
пересоздаваемым в `attach()` и `dispose()`'нутым в `detachCurrentRoot()` — тем
же способом, каким уже живёт `RenderCoordinator`. `coordinator.onPostCommit` и
`coordinator.onDisplayOnly` оба запускают `scanForDisplayWork(root:scale:)` —
full-tree walk, вычисляющий `DisplayKey` для каждой `TextNode` и вызывающий
`schedule(...)`, если ключ разошёлся с уже закоммиченным. Публичные
`displayArtifact(for:)`/`displayStatistics` — точки наблюдения для T07 и тестов.

## 2. Три уточнения относительно наброска D53

1. **Нет отдельного `DisplayTransaction`.** Его роль (какой ключ в полёте у
   ноды, какой закоммичен) целиком берут на себя `DisplayScheduler`'s
   `activeJobs`/`pendingByNode`/committed-таблица — обёртка без собственного
   поведения не добавлена.
2. **`mountEpoch` не хранится в `DisplayKey`.** `NodeHostBridge` создаёт новый
   `DisplayScheduler` на каждый `attach` и вызывает `dispose()` при detach —
   предыдущий mount физически не может закоммитить в текущий, потому что его
   планировщик уже не существует (тот же принцип, что уже применяет
   `RenderCoordinator`'s собственный пересоздаваемый-на-attach жизненный цикл).
3. **`environmentRevision` — конкретизация «typography/theme входов» D52.**
   `contentRevision`/`displayRevision` уже покрывают все поля самой
   `TextNode`; единственный вход, который может измениться без изменения
   ЛЮБОГО поля ноды, — унаследованные из environment тема/locale/renderer,
   отражённые в `Node.environmentSnapshot.revision`.

## 3. Планировщик: одна активная + одна согласованная pending-задача на ноду

`DisplayScheduler` обобщает дисциплину `LayoutScheduler` (один активный worker
+ одна заменяемая pending-заявка на хост) на много нод, делящих один
`maxConcurrency` бюджет:

- `schedule(nodeID:key:request:)` с уже закоммиченным `key` — истинный no-op.
- С активной задачей для другого `key` — активная отменяется
  (`Task.cancel()`), новая заявка кладётся в pending (заменяя более старую
  pending-заявку той же ноды, если была — счётчик `dropped`).
- Когда отменённая задача действительно завершается (`finish`), она видит
  `cancelled`, освобождает слот и запускает pending-заявку, если она есть.
- `drain()` стартует ноды из ready-очереди (high-приоритет впереди), пока
  `activeJobs.count < maxConcurrency`.

Burst из N быстрых изменений одной ноды поэтому даёт **один** активный worker
за раз и ровно один финальный committed artifact — не N растров.

## 4. Растр: почему он не переиспользует `measure`'s unbounded-проверку впрямую

`measure()` строит `CTFrame` с неограниченной высотой, чтобы узнать
естественное число строк при данной ширине (T05). `rasterize()` вместо этого
строит `CTFrame`, ограниченный **точным** финальным размером
(`request.size`) — CoreText сам решает, сколько строк туда влезает; поверх
этого применяется `maxLines`, если он обрезает раньше. Когда после видимых
строк остаётся ещё текст и `truncation == .tail`, последняя видимая строка
заменяется на реально измеренную усечённую версию
(`CTLineCreateTruncatedLine` от подстроки «от начала последней строки до
конца документа» до эллипсиса) — не догадка по числу символов (класс дефекта
#37, отрисовочная половина). `.clip` и случай без усечения используют один
`CTFrameDraw` на весь кадр — путь, идентичный прототипу T02.

## 5. Тесты и результаты

20 новых тестов, весь пакет зелёный на трёх платформах:

| Платформа | TrellisCoreTests | TrellisRenderTests |
|---|---|---|
| macOS (`swift test`) | — | — (558 тестов пакета целиком) |
| iOS 26.5 Simulator | 407/407 | 148/148 |
| tvOS 26.5 Simulator | 407/407 | 148/148 |

- `Tests/TrellisRenderTests/Display/CoreTextRasterizeTests.swift` (8) —
  пиксельный размер = `size × scale`; пустая строка и нулевой размер не
  падают; `maxLines`/`clip` рисуют без ошибок и сохраняют заявленный box;
  run-level цвет не ломает растеризацию; отменённый контекст бросает до
  рисования; RTL рисуется без ошибок.
- `Tests/TrellisRenderTests/Display/DisplaySchedulerTests.swift` (7), через
  управляемый `ControllableRasterizer` (искусственная задержка + счётчики,
  тот же приём, что `SchedulerStaleResultTests.SignallingEngine` для
  `LayoutScheduler`): burst из 100 изменений одной ноды → один artifact;
  resize во время активного растра → старая геометрия отброшена, новая
  закоммичена; `dispose()` во время растра → ноль коммитов; `maxConcurrency`
  реально не превышается; 20 нод при `maxConcurrency=1` — после drain у
  каждой есть artifact; уже закоммиченный `key` — истинный no-op;
  `cancel(nodeID:)` вычищает активное/pending/committed состояние.
- `Tests/TrellisRenderTests/Display/TextDisplayIntegrationTests.swift` (5),
  через реальный `NodeHostBridge`/`TextNode` (без host-рендерера — измерение
  идёт через `PortableTextMeasurer`, растр — через реальный
  `CoreTextRenderer`, который `DisplayScheduler` использует по умолчанию):
  первый коммит в итоге даёт artifact; смена текста заменяет artifact; смена
  только цвета планирует новый display pass **без** нового layout snapshot;
  `detach()` во время отложенного растра не оставляет доступным
  устаревший/новый artifact; ноды без текста растром не занимаются.

## 6. API baseline

`check_api.py --tvos` показал только `added` для `TrellisRender`
(`DisplayArtifact`, `DisplayKey`, `TextDisplayRequest`, `TextRasterizer`,
`DisplayScheduler`, `DisplayStatistics`, `DisplayPriority`,
`CoreTextRenderer.rasterize`, `NodeHostBridge.displayArtifact`/
`.displayStatistics`) — `changed`/`removed` пусты, ADR не потребовался.
Обновлено командой `check_api.py --tvos --update --review-note
docs/validation/t06-display-pipeline.md`.

## Приёмка T06

- `DisplayScheduler`/`DisplayArtifact` (`DisplayTransaction`'s роль — внутри
  планировщика, §2) в `TrellisRender`; `onPostCommit`/`onDisplayOnly` →
  display pass только для нод с несовпавшим ключом; `.display` flush не
  требует layout snapshot/solve — done, §1/§3, тесты §5.
- Валидность по committed-таблице и ключу; устаревший результат отброшен со
  счётчиком (`stale`); suspend/resume/detach — отмена без поздних коммитов —
  done (`dispose()`, §2 п.2, тест `t06_disposeDuringRasterCommitsNothingLate`,
  `t06_detachDuringPendingDisplayWorkNeverLeavesAStaleArtifactReachable`).
- Статистика scheduled/started/completed/cancelled/dropped/stale — done
  (`DisplayStatistics`, §3).

Следующая карточка — T07 (`LayerRenderer` и текстовый слой: внешний node
layer + внутренний raster layer, применение `DisplayArtifact` к
`contents`/`contentsScale`/`contentsGravity`).
