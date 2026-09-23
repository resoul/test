# C29 — Развиваемый реактивный путь: model → Node → render

Дата: 2026-09-11.

## Что сделано

**`StateSubject<Value: Sendable & Equatable>`** (TrellisCore) — источник актуального
состояния с latest-value семантикой: `current`, `send(_:)` (равное значение — `false` и
ничего), `observe` (package, для binding'а хоста). MainActor-изолирован: продюсер с другого
executor'а делает hop к `send`, все мутации `Node` остаются на MainActor без lock'ов и без
`@unchecked Sendable` (policy `UNSAFE_CONCURRENCY`). Очереди нет — ровно одно значение.

**`NodeHostBridge.bindState(_:update:)` → `StateBinding`** (TrellisRender) — владелец
подписки: mounted session (D14).
- Доставка следует состоянию монтирования, не моменту создания binding'а: значения идут
  только пока root attached и не suspended.
- На `attach` (или сразу при `bindState`, если уже attached) `current` доставляется
  **синхронно** — до flush, который attach только что запланировал: первый commit уже
  показывает состояние, а не голое дерево.
- Синхронный burst `send` → один отложенный `update` с последним значением на следующем
  ходу MainActor (та же граница, что у flush'а); ≤ 1 ожидающая доставка на binding, без
  Task на поле.
- `detach()` снимает наблюдателя с subject'а, binding остаётся; повторный `attach` снова
  подписывается и отдаёт `current`, если он изменился с последней доставки.
- `suspend()` держит только latest; `resume()` доставляет его. `cancel()` — конец:
  ничего, включая уже запланированное, не доходит.
- `TrellisHostView.bindState` (AppKit/UIKit): view теперь держит **один bridge на всю
  жизнь** (раньше создавала новый на каждый `attach`), поэтому binding'и переживают
  `detach`/`attach`. Имя `bindState`, потому что у `NSView` уже есть Cocoa-`bind(_:to:)`.

**`update(model)` на примерной ноде**, не на базовом `Node`: `DownloadCardNode` (S20) и
`CardNode` (тесты) сравнивают с показанным и трогают только изменившееся — `style` для
геометрии, `appearance` для paint, `markArrangementDirty()` для структуры (C32); строки
ключуются по имени файла, так что существующий `Node` и его `CALayer` переживают вставку и
перестановку. «Одна транзакция» — это один синхронный ход MainActor: pending-окно C09
складывает все мутации в один flush, публичный `InvalidationTransaction` не понадобился.

## Найденный и исправленный дефект C14: коалесценция никогда не срабатывала

`RenderCoordinator.flush()` сравнивал `request == lastCommittedRequest`, а синтезированный
`Hashable` у `HostRenderRequest` включает `generation` — счётчик, который растёт на каждый
запрос. Равенство было невозможно: `coalescedCount` не рос никогда, а **любой** пинг,
включая appearance-only, шёл в полный snapshot → measure → place → commit (probe:
смена цвета одной ноды давала `committedCount == 2`). Приёмка C09 «appearance-only даёт
ноль snapshot/solve» держалась только на уровне `Node`.

Исправлено: `describesSameWork(as:)` сравнивает всё, что читает движок, без `generation`;
коалесцированный flush с `.appearance` в pending-окне зовёт новый
`RenderCoordinator.onPaintOnly`, bridge → `LayerRenderer.applyAppearance(root:)` —
presentation переприменяется по дереву (pending-окно хранит только первый origin), без
snapshot и без Flex. Тест `appearanceOnlyChangeRepaintsWithoutALayoutPass`: `committedCount`
не меняется, цвет слоя — новый.

## Тесты

`StateSubjectTests` (2): равное значение — no-op и не уведомляет; наблюдение не
воспроизводит `current`; burst без наблюдателя оставляет одно значение; отмена.

`StateBindingTests` (8), через `NodeHostBridge` на голом `CALayer`:

| Тест | Приёмка C29 |
|---|---|
| `currentValueLandsInTheFirstCommitAndEqualStateDoesNothing` | одинаковое состояние не запускает render; первый commit уже с моделью |
| `burstDeliversOnlyTheLastValueAndOneCommit` | burst из 10 моделей → 1 `update`, 1 commit, последнее значение |
| `appearanceOnlyChangeRepaintsWithoutALayoutPass` | appearance-only не вызывает Flex |
| `structureChangeGoesThroughArrangementAndKeepsIdentity` | identity стабильна (тот же `CALayer` карточки), структура через `markArrangementDirty` |
| `detachStopsDeliveryAndReattachRestoresLatest` | detach отменяет доставку (0 наблюдателей), reattach даёт latest ровно один раз |
| `suspendHoldsLatestAndResumeDeliversIt` | suspend держит latest, resume доставляет |
| `cancelPreventsLateMutationsAndReleasesOwnership` | нет поздних мутаций после cancel, даже уже запланированной; binding и наблюдатель освобождены; reattach не воскрешает |
| `bridgeReleasesNothingItShouldNot` | после cancel + detach нода и subject освобождаются (weak → nil) |

## Playground: S20_ReactiveUpdates

`StateSubject<DownloadModel>` → `DownloadCardNode.update`; сессия по 1 с гоняет фазы:
initial → равное состояние → burst ×30 → только accent → структура (файл в середине).
`ScenarioInstance.onAttach` — место binding'а после `attach`; `teardown()` отменяет сессию
и binding'и при смене сцены (bridge теперь общий для всех сцен view — забытый binding
продолжал бы гнать отсоединённое дерево). Скриншот — фаза 0 с доставленной моделью:
fill 96×8 = 0.3 × 320, две строки файлов.

detach/reattach в статическом скриншоте не показать — покрыто тестами; на устройстве это
смена сцены и возврат.

## Направление расширения (без реализации)

Источники/адаптеры (Flux, Observation, Combine) подключаются к этому пути одним способом:
адаптер держит `StateSubject` и зовёт `send` на MainActor. Полноценный store,
dependency tracking и property wrappers — по реальному потребителю (N04). Семантика
latest-value — только для отображаемого состояния; события/действия сюда не идут.

## Проверки

`swift test` — 290; `check_all.py` — PASS. API baseline по этой записке: `added` —
`StateSubject`, `NodeHostBridge.bindState`/`bindingCount`/`cancelAllBindings`,
`StateBinding`, `RenderCoordinator.onPaintOnly`, `LayerRenderer.applyAppearance(root:)`,
`TrellisHostView.bindState`. Скриншоты: + `S20_ReactiveUpdates(.png|_overlay.png)`.

## Открыто

- Paint-only переприменяет presentation всему дереву, не только изменившимся нодам —
  pending-окно знает лишь первый origin; при 1000 нод это O(n) CALayer-записей на смену
  одного цвета. Измерить в C31, точечный список origin'ов — если цифры потребуют.
- `StateObservation` без `deinit`-отмены (Swift 6: deinit не изолирован) — единственный
  держатель, binding, отменяет всегда.
