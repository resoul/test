# M07 — Взаимодействие и детерминированная готовность

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §5, D68/D69;
зависимости M05 ([m05-reduce-motion-lifecycle.md](m05-reduce-motion-lifecycle.md)) и M06
([m06-text-card-animation.md](m06-text-card-animation.md)) закрыты.

## 1. D68 — снимки и взаимодействие: подтверждение, не новая реализация

Hit-test (`HitTestSnapshot`), focus/AX (`SemanticSnapshot`) и `DebugOverlayRenderer` уже читают
исключительно committed-геометрию (`Node.calculatedFrame`, заполняемую `applyLayoutResult`), а не
`CALayer.presentation()` — контракт D25/D34/D46, код не менялся. Новых тестов на это M07
добавляет столько же, сколько добавил M06 для D65: доказательство, что это продолжает работать
**при активном explicit-переходе** (M04), не только в состоянии покоя.

## 2. D69 — готовность export: `NodeHostBridge.sceneReadiness`/`waitUntilSceneReady(timeout:)`

Новый публичный API — три независимых оси, каждая читается вживую с владеющей подсистемы, а не
выводится из прошедшего времени:

- **`layoutReady`** — `RenderCoordinator.hasPendingLayoutWork` (новое internal-свойство):
  `activeRequest != nil || pendingHostState != nil`. Намеренно **не** смотрит на
  `flushScheduled`: каждое завершение worker'а (`workerFinished`) безусловно планирует ещё один
  housekeeping-flush «проверить, не появилось ли работы», который почти всегда находит
  `pendingHostState == nil` и на следующем runloop-тике превращается в no-op — этот `true` на
  один тик не является свидетельством реальной ожидающей layout-работы. Найдено и исправлено до
  коммита: первая версия включала `flushScheduled` в проверку, из-за чего
  `sceneReadiness.layoutReady` был `false` **сразу после каждого коммита**, включая полностью
  тривиальную сцену без текста и анимации — стабильно воспроизводимо, поймано первым же тестом
  (`m07_sceneReadinessIsTriviallyTrueForAPlainSceneWithNoTextAndNoAnimation`), не дефект в
  продакшен-логике `RenderCoordinator`, а неверная формула в новом readiness-геттере.
- **`displayReady`** — `DisplayScheduler.activeJobCount == 0 && pendingJobCount == 0`;
  `pendingJobCount` — новый public accessor (симметричный уже существующему `activeJobCount`).
- **`animationReady`** — `!LayerRenderer.hasActiveAnimations(mountEpoch:)`, новый метод поверх
  нового `LayerAnimator.activeCount(mountEpoch:)` (подсчёт записей `active` по эпохе — то же
  bookkeeping, которым уже пользуются `finishAllActive`/`forgetNode`).

`waitUntilSceneReady(timeout:)` — ограниченный кооперативный опрос (`Task.yield()`), не
`sleep`/подобранная задержка (D69: «не sleep(60 ms) и не подбор delay под экспорт»); бросает
`NodeHostBridge.SceneReadinessError.timeout`, если дедлайн наступил раньше, чем все три оси стали
`true` — вызывающий код не получает возможности снять кадр как «готовый», если это не так.

## 3. Найденное ограничение: `animationReady` после естественного завершения не проверяется автотестом

m02-animation-prototype.md §1.4 уже зафиксировал: реальный CA completion callback
(`CATransaction.setCompletionBlock`/`CAAnimationDelegate`) не доставляется внутри
XCTest-хостированного процесса на этом тулчейне (пять независимых проб, воспроизводимо). Это
значит, что естественное истечение длительности `Node.animate` никогда не приводит к вызову
`LayerAnimator.completeIfCurrent` в тестовой среде — `active`-запись, а значит и
`animationReady`, остаётся `false` даже после того, как реальный `CALayer` уже показывает
финальное значение. M04/M05 уже сузили контракт до «логика `completeIfCurrent` проверяется прямым
вызовом, факт доставки колбэка — Playground-evidence»; M07 наследует то же ограничение для нового
потребителя (`sceneReadiness`) и **не** пытается писать тест, который ждёт реального завершения
через `Task.sleep` — это было бы либо вечно висящим тестом, либо тестом, ложно проходящим по
случайному совпадению. Вместо этого `animationReady`'s переход `false → true` проверяется через
`suspend()` (D67's `finishActiveAnimations`, который не зависит от CA completion вообще) —
`m07_suspendFinishesTheActiveAnimationAndRestoresAnimationReadiness`. Не новый дефект: то же
принятое сужение контракта, что и в M02, применённое к новому месту.

## 4. Тесты

`Tests/TrellisRenderTests/M07SceneReadinessTests.swift` — 7 тестов через настоящий
`NodeHostBridge` на слое, смонтированном под реальным окном (M02 §2's warm-up):

- `m07_sceneReadinessIsTriviallyTrueForAPlainSceneWithNoTextAndNoAnimation` — `nil` до `attach`,
  все три оси `true` после первого коммита сцены без текста/анимации;
  `waitUntilSceneReady(timeout: .milliseconds(200))` возвращается сразу.
- `m07_animationReadyIsFalseWhileAnExplicitAnimationIsInFlightAndTimeoutSurfacesAsAnError` —
  `animationReady == false` сразу после коммита с активной 30-секундной анимацией;
  `waitUntilSceneReady(timeout: .milliseconds(30))` бросает `.timeout`, не зависает и не
  возвращает частично готовое состояние.
- `m07_suspendFinishesTheActiveAnimationAndRestoresAnimationReadiness` — §3.
- `m07_hitTestFocusAndAccessibilityTargetTheCommittedFrameNotThePresentationDuringAnActiveAnimation`
  — D68: во время активного перехода (presentation-высота ещё меньше 80, санити-чек, что тест не
  вырожден) `hitTest`/`focus`/`semanticSnapshot` уже видят финальную (80pt) геометрию.
- `m07_debugOverlayOutlinesTheCommittedFrameNotThePresentationDuringAnActiveAnimation` — то же
  для `DebugOverlayRenderer`'s контуров (`overlayOutlines`-приём из `DebugOverlayTests.swift`).
- `m07_displayReadyTracksARealTextRasterJobFromScheduledToCommitted` — `displayReady == false`
  сразу после коммита `TextNode` (T06 планирует job синхронно внутри того же `onPostCommit`),
  `true` после реального (не имитированного) `CoreTextRenderer`-растра;
  `waitUntilSceneReady()` (дефолтный таймаут 2s) возвращает `isReady == true`.
- `m07_repeatedTapDuringAnInFlightRasterJobThenDetachLeavesNoStaleReadinessOrSessions` —
  интеграция третьего пункта карточки: настоящий `ControlNode`-based disclosure (полный
  pointerDown/pointerUp через `bridge.send`, не прямой вызов `Node.animate`), повторное нажатие
  до завершения первого raster/анимации, затем `detach()` — без падения, `sceneReadiness == nil`,
  `displayArtifact == nil`, `activePointerSessionCount == 0` после detach.

```text
TRELLIS_LOG=off swift test --filter M07
7 tests passed
```

```text
TRELLIS_LOG=off swift test
658 tests passed (was 651 before this card), no flakes
```

## 5. API baseline

Новые публичные символы (`TrellisRender`): `NodeHostBridge.SceneReadiness` (struct,
`layoutReady`/`displayReady`/`animationReady`/`isReady`), `NodeHostBridge.SceneReadinessError`
(enum, `.timeout`), `NodeHostBridge.sceneReadiness`, `NodeHostBridge.waitUntilSceneReady(timeout:)`,
`DisplayScheduler.pendingJobCount`. Все аддитивны — ни один существующий публичный символ не
изменился. `check_api.py --tvos --update --review-note docs/validation/m07-scene-readiness.md` —
`TrellisRender` baseline обновлён; `TrellisCore`/`TrellisAppKit`/`TrellisUIKit` без изменений.

## 6. Проверки

- `python3 Scripts/check_policy.py` — PASS (после исправления: `SceneReadinessError`'s doc
  изначально не содержала Ownership/Isolation/Errors/Cancellation-блока, поймано `check_policy.py`
  до коммита).
- `TRELLIS_LOG=off swift test --filter M07` — PASS.
- `TRELLIS_LOG=off swift test` — PASS, whole package, no flakes.
- `check_api.py --tvos --update --review-note` (this document) — updated, diff limited to the
  additive symbols listed above.
- `python3 Scripts/check_all.py` — PASS: policy/verifier unit tests, strict format,
  `-warnings-as-errors` library build + package test + external consumer, API baselines
  (macOS/iOS/tvOS), 52 macOS screenshot scenarios, `TRELLIS_LOG` behavior.

## Приёмка M07

- Hit-test/focus/AX/DebugOverlay следуют target во время перехода (D68) — done, §1/§4
  (второй и третий тесты).
- Общая готовность export: layout + display + animation, timeout как ошибка — done, §2/§4
  (первый, второй, пятый тесты); No-op/тривиальная сцена не зависает в export — первый тест.
- Интеграция повторного нажатия, нового commit во время растра и detach — done, §4
  (последний тест).

Открытый пункт, унаследованный от M02 (§3): `animationReady`'s переход после естественного
завершения CA — Playground/manual evidence, не автотест, на этом тулчейне. Не блокирует M07 по
той же причине, по которой не блокировал M02.

Next card — M08 (закрыть результат A: S27/S28, bench 1000 слоёв + текст, `check_all.py --matrix`).
