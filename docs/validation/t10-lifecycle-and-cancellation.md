# T10 — Lifecycle и отмена

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
уточняет D58 ([decisions.md](../decisions.md)). Зависит от T06
([t06-display-pipeline.md](t06-display-pipeline.md)), T07
([t07-text-raster-layer.md](t07-text-raster-layer.md)).

## 1. Что проверено и что было уже готово

Карточка сформулирована как аудит существующего lifecycle-поведения
(`detach`/`replaceRoot`/`suspend` во время solve и во время растра, `dispose()`
с очередью, реентрантность из `onCommit`/`onFocusChange`) плюс исправление
того, что аудит найдёт — не новая функциональность с нуля. Большая часть
списка приёмки уже была реализована и покрыта тестами более ранними
карточками:

- **Detach/replaceRoot во время solve** — `RenderCoordinator.replaceRoot`/
  `suspend`/`invalidate` уже отменяют активный worker (`scheduler.cancel()`) и
  помечают `activeRequest = nil`; `handle(_:)` перепроверяет живое дерево
  (`treeIdentity`/`contentRevision`/`environmentRevision`/`root === newRoot`)
  перед применением результата — стале-результат никогда не коммитится.
  Тесты: `RenderCoordinatorTests.test_renderCoordinator_replaceRootRejectsPreviousTreesResult`,
  `LoadAndTeardownTests.test_load_burstDuringLayoutCancelsInFlightWorkAndCommitsTheLastState`,
  дефекты #19–#22 (docs/defects.md) уже закрыли конкретные гонки в этой
  области.
- **Detach во время растра** — `t06_detachDuringPendingDisplayWorkNeverLeavesAStaleArtifactReachable`
  ([Display/TextDisplayIntegrationTests.swift](../../Tests/TrellisRenderTests/Display/TextDisplayIntegrationTests.swift))
  уже проверяет: `text` меняется прямо перед `detach()` (задача почти
  наверняка ещё не завершилась), после `detach()` — `displayArtifact(for:)`
  == nil, `displayStatistics.completed == 0`.
- **Реентрантность `FocusEngine`** — `transition(to:reason:root:)` уже несёт
  `inTransition`/`deferred` — вызов `focus(_:)`/`moveFocus(_:)` изнутри
  `onFocusChange` не рекурсирует, а откладывается и дренируется после выхода
  из текущего перехода (`drainDeferred`). Не нашлось нигде документированным
  явно как «реентрантность», но механизм уже на месте до этой карточки.
- **Пустые очереди/счётчики после `detach()` целиком** — `RenderCoordinator.dispose()`
  и `DisplayScheduler.dispose()` уже отменяют весь активный и отложенный набор
  работы и очищают таблицы; `NodeHostBridge.detachCurrentRoot()` вызывает оба.

## 2. Найдено и исправлено (дефект #44, [defects.md](../defects.md))

D58 формулирует: «`dispose()` текстовой ноды отменяет её задачу в scheduler по
`nodeID`» — но это никогда не было реализовано для ноды, удалённой из дерева
*при живом mount'е* (структурная мутация, `removeFromSupernode()`,
`Node.dispose()`), а не через полный `detach()`/`replaceRoot`. Причина: у
`TextNode` (`TrellisCore`) нет и не может быть ссылки на `DisplayScheduler`
(он существует только на стороне `NodeHostBridge`/`TrellisRender`, один на
mount) — реализовать «сама себя отменяет» буквально было невозможно.

`LayerRenderer.removeStaleLayers` уже вычисляет ровно нужное множество —
`NodeID`, которые были активны на прошлом коммите и не активны на этом — и
корректно снимает их `CALayer`. Но ничего не уведомляло `DisplayScheduler`:
его `committedTable`/`activeJobs`/`pendingByNode` держали запись удалённой
ноды бессрочно — активная raster-задача продолжала рисовать в фоне на никому
не нужную ноду, а `committedTable` рос без ограничения на каждый удалённый за
время жизни mount'а `TextNode`. Визуального бага не было (`applyDisplayArtifact`
уже не находит `rasterLayers[nodeID]` и молча ничего не делает), но
`DisplayScheduler.dispose()`/`cancel(nodeID:)` — единственные способы это
когда-либо остановить — не вызывались.

Исправлено: `LayerRenderer.onNodeRemoved: (@MainActor (NodeID) -> Void)?` —
новый callback, вызываемый из `removeStaleLayers` для каждого более
неактивного `NodeID`, тем же tree-wide diff'ом, которым уже находили
удалённые слои. `NodeHostBridge.attach` подключает его к
`displayScheduler.cancel(nodeID:)` — `cancel(nodeID:)` уже существовал и уже
был no-op для идентификатора, которого `DisplayScheduler` не знает, так что
вызов для не-`TextNode` идентификатора безопасен.

## 3. Тесты

`Tests/TrellisRenderTests/TextNodeRemovalPurgesDisplayQueueTests.swift` (2,
доказывают дефект #44 и его фикс):

- `t10_removingATextNodeFromALiveTreePurgesItsCommittedArtifact` — узел с уже
  закоммиченным artifact'ом удаляется структурной мутацией
  (`removeFromSupernode()`) при живом mount'е; после следующего коммита
  `displayArtifact(for:)` == nil и `layer(for:)` == nil.
- `t10_disposingATextNodeWithAnInFlightRasterJobCancelsItRatherThanLeakingIt` —
  текст меняется (планирует новую raster-задачу) и сразу `dispose()`, так что
  задача почти наверняка ещё не завершилась (та же форма гонки, что и в
  `t06_detachDuringPendingDisplayWorkNeverLeavesAStaleArtifactReachable`, но
  через удаление ноды из живого mount'а, а не через `detach()` всего моста).

`Tests/TrellisRenderTests/BridgeCallbackReentrancyTests.swift` (3, фиксируют
существующее защитное поведение — без них регрессия выглядела бы как
бесконечная рекурсия/сбой процесса, а не как проваленный `#expect`):

- `t10_mutatingTextFromOnSemanticsPublishedDoesNotCrashAndSettlesOnASecondCommit` —
  текст меняется прямо внутри `onSemanticsPublished`, вызванного изнутри
  `RenderCoordinator.handle()` того же коммита; второй коммит приходит без
  краха, `statistics.stale == 0`.
- `t10_detachingFromOnSemanticsPublishedLeavesTheBridgeFullyTornDownNotHalfway` —
  `bridge.detach()` вызывается из того же callback'а, реентрантно поверх ещё
  не размотанного стека `RenderCoordinator.handle()`. Проверено: ни один
  геттер моста не видит промежуточное состояние (`hitTestSnapshot`/
  `semanticSnapshot`/`accessibilityTree` — nil, `displayStatistics.completed
  == 0`, `materializedLayerCount == 0`), и последующий `attach()` монтирует
  новое дерево нормально (`onSemanticsPublished` переживает `detach()` как
  настройка — тест явно снимает её перед вторым `attach`, иначе она
  немедленно детачит и второй mount).
- `t10_movingFocusFromOnFocusChangeIsDeferredNotRecursedAndConverges` —
  `onFocusChange` вызывает `bridge.focus(_:)` обратно на исходный узел;
  фиксирует, что `FocusEngine.inTransition` откладывает этот вызов, а не
  рекурсирует (последовательность событий: `first → second → first`, без
  переполнения стека).

## Приёмка T10

- Ноль поздних коммитов — done: коммит, чей `RenderCoordinator` реентрантно
  диспозится изнутри собственного `onCommitGeometry`, сам обнуляет
  `onPostCommit` до того, как `handle()` успевает его вызвать (уже было
  архитектурно; `t10_detachingFromOnSemanticsPublishedLeavesTheBridgeFullyTornDownNotHalfway`
  фиксирует наблюдаемое следствие).
- Пустые очереди после detach — done для полного `detach()` (уже было, T06/
  T07); **было не done** для удаления ноды при живом mount'е — исправлено
  этой карточкой (дефект #44), тесты §3.
- Счётчики cancelled согласованы — done: `DisplayScheduler.finish` не
  засчитывает `cancelled`/`stale` дважды для одной и той же задачи
  (`guard !isDisposed`/`guard activeJobs[nodeID]?.key == key`), не тронуто
  этой карточкой, перепроверено чтением кода.
- Повторный attach не оживляет старые artifact'ы — done: `attach()` создаёт
  новый `DisplayScheduler` при каждом mount'е (T06), плюс теперь и
  внутримонтовое удаление больше не оставляет запись, которая могла бы
  пережить сам mount дольше, чем нужно (дефект #44).

Прогон полного пакета: macOS (`swift test`) — 593/593 (было 588 после T09,
+5 новых теста этой карточки). iOS/tvOS Simulator — см. запись коммита ниже.
