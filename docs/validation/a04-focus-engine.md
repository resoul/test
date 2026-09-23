# A04 — FocusEngine и детерминированный поиск

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D35, D37–D39, D48 ([decisions.md](../decisions.md)); примеры —
[a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §4–§5.
Дефекты источника #33 (nearest-neighbour Tab, tie-break) и #34 (strong `focusedNode`,
потеря focusOut) закрыты этой карточкой — см. [defects.md](../defects.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| События D48 ([ADR 0013](../adr/0013-event-pointer-becomes-optional.md)) | `Sources/TrellisCore/Events/Event.swift` | `EventType` + `focusIn/focusOut/keyDown/keyUp`; `FocusData(previous, next, reason)`, `KeyboardKey`, `KeyData(key, isShiftDown, isRepeat)`; `EventPayload.focus/.key`; `Event.pointer: PointerData?`, `Event.focus`, `Event.key`. `ControlNode.track`, `TapRecognizer`/`PanRecognizer.handle` начинают с `guard let data = event.pointer` — не-pointer событие игнорируется, а не читается как press в (0, 0). `PointerSessions.send` отвечает `.noSession` на не-pointer тип. Key-события в этой карточке только объявлены; доставка — A07. |
| `FocusEngine` (D35, D39) | `Sources/TrellisCore/Focus/FocusEngine.swift` | `@MainActor final class`: `focusedID`, `scopeID`, `restorationID`, `transitionRevision`, `lastTrace`, `snapshot`, `onFocusChange`; живой `Node` — только borrowed `root:` в каждом вызове, как у `PointerSessions`. `apply(_:root:)` принимает publish и перепроверяет focus/scope; `focus(_:root:reason:)`, `move(_:root:)`; `setScope`/`suspend`/`resume`/`reset` — A05. `FocusChangeReason` (request/navigation/restoration/invalidation/scope/native/suspend/detach), `FocusChange`, `FocusTrace`, `FocusMoveResult` (moved/unchanged/unavailable/deferred). |
| Транзакция перехода (D39) | `runTransition` | `focusOut` предыдущему (three-phase dispatch по committed маршруту `SemanticSnapshot.route(to:)`) → повторная валидация `next` (candidate в scope **и** live guard: маршрут цел, не disposed, enabled) → `focusedID = next`, `transitionRevision += 1` → `focusIn` → одно `onFocusChange`. Тот же ID — `.unchanged` без событий. Инвалидированный в `focusOut` target → `focusedID = nil`, `reason: .invalidation`, одно уведомление. `reset()` из callback (detach) поднимает `epoch` — транзакция прерывается после текущего callback без focusIn и без уведомления. |
| Реентрантность (D39) | `transition`/`drainDeferred` | Запрос из callback — в очередь (`.deferred`), выполняется после завершения текущего перехода с повторной валидацией; лимит `deferredRequestLimit = 8` на цепочку, сверх — `droppedRequestCount` и лог `request-dropped`. |
| Обход (D38) | `move`, `sequentialNeighbour`, `directionalRanking`, `initialCandidate` | `.next`/`.previous` — `SemanticSnapshot.focusCandidates(scope:)` (committed pre-order), без wrap вне modal. Стрелки — центры `visibleBounds`, строго положительная проекция, `primary + 0.5·secondary`, tie — `traversalIndex`; порядок создания `NodeID` и `zIndex` не участвуют. `preferredNext[direction]` — раньше поиска, если target ≠ self и кандидат. Без focus: `.next`/стрелки — max `priority`, tie — min index; `.previous` — max index. Без кандидата — `.unchanged`. |
| Восстановление на publish (§3.1) | `apply`, `fallbackCandidate` | Исчезнувший/disabled/clipped focused → следующий живой кандидат по **прежнему** списку кандидатов (старый снимок), затем предыдущий, затем первый в scope, иначе `nil`; `reason: .invalidation`. Resize не трогает focus. Снимок другой `mountEpoch` → `reset()` перед применением. |
| Bridge (D35) | `TrellisRender/NodeHostBridge.swift` | Владеет `FocusEngine` (private): `focusedID`, `focusScopeID`, `lastFocusTrace`, `onFocusChange`, `focus(_:reason:)`, `moveFocus(_:)`, `setFocusScope(_:)`; `publishSemantics` вызывает `engine.apply` до `onSemanticsPublished`; `suspend()`/`resume()` → `engine.suspend/resume`; `detachCurrentRoot()` → `engine.reset()`; запросы на неактивном (suspended) хосте — `.unavailable`. |

## Тесты

`swift test --filter "a04_"` — 22 теста (18 Core + 4 Render), все зелёные.

Core (`Tests/TrellisCoreTests/Focus/FocusEngineTests.swift`, фикстура `R > [A, B, C]`):

| Тест | Случаи A01 |
|---|---|
| `a04_tabWalksPreorderAndStopsAtTheBoundary` | §4 1–4: A→B→C, `.unchanged` на границе, обратный обход, 5 переходов/уведомлений |
| `a04_previousWithoutFocusPicksTheLastAndPriorityPicksTheInitial` | §4 5; priority — только initial |
| `a04_zIndexAndCreationOrderDoNotAffectTabOrder` | §4 6 (C создан раньше A, `B.zIndex = 5`) |
| `a04_arrowsUseStrictlyPositiveProjectionAndTheScoreFormula` | §4 7–8; secondary·0.5 меняет победителя (C 90 < A 100); `.left` без кандидата — `.unchanged` |
| `a04_equalScoresBreakTiesByTraversalIndexNotByIdentityOrder` | §4 9 + reorder siblings через `moveSubnode` сохраняет `NodeID` |
| `a04_explicitOverrideWinsWhenValidAndIsIgnoredOtherwise` | §4 10–11: self / неизвестный / disabled target |
| `a04_rightToLeftDoesNotChangePhysicalDirections` | §4 12 |
| `a04_disabledInvisibleClippedAreSkippedButAccessibilityHideIsNot` | §4 13–16 |
| `a04_focusRequestRejectsNonCandidatesAndNonLiveTargets` | не-focusable, неизвестный ID, no-op на том же (§5 2), reparent до commit — `.unavailable`, после — ok (§5 14), disabled live до publish, engine без снимка |
| `a04_transitionDeliversFocusOutThenFocusInThenOneNotification` | §5 1–2: порядок событий с `FocusData`, одно уведомление, ревизия |
| `a04_disposingNextInsideFocusOutEndsWithNoFocusAndOneNotification` | §5 3 |
| `a04_resetInsideFocusOutAbandonsTheTransition` | §5 4 |
| `a04_requestInsideFocusInIsDeferredAndRunsAfterTheCurrentTransition` | §5 5: `.deferred`, два уведомления, порядок событий |
| `a04_callbackLoopIsCutAtTheDeferredLimit` | §5 6: 9 уведомлений, 1 dropped, engine работоспособен после |
| `a04_teardownInsideFocusInDoesNotCrashOrNotifyTwice` | dispose дерева + reset в `focusIn` |
| `a04_removedFocusedNodeFallsBackToTheNextThenPreviousThenFirst` | §5 12: B→C, C→A, пусто→nil |
| `a04_disablingOrClippingTheFocusedNodeOnPublishFallsBack` | §5 13 + полностью вне host |
| `a04_resizeKeepsFocusAndNewMountNeverInheritsTheOldEpoch` | §5 15, 17 |

Render (`Tests/TrellisRenderTests/FocusBridgeTests.swift`): до первого commit — `.unavailable`;
`moveFocus` через реальный pipeline; dispose сфокусированной карточки → fallback на commit;
`isEnabled = false` → metadata-only publish двигает focus; `detach` очищает без событий,
повторный attach начинает с нуля. (`a05_*` там же — A05.)

Native tvOS selection подтверждает адаптер (A08), не score — здесь только headless.

## API baseline

`Event.pointer` — `changed` (тип `PointerData?`, ADR 0013); `EventType`/`EventPayload` —
новые cases; добавлены `FocusData`, `KeyboardKey`, `KeyData`, `Event.focus`/`key`,
`FocusEngine`, `FocusChange`, `FocusChangeReason`, `FocusTrace`, `FocusMoveResult`,
`SemanticSnapshot.route(to:)`, bridge API выше. Review notes — ADR 0013 и этот отчёт.
