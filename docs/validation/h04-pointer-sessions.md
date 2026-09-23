# H04 — Pointer session lifecycle

Дата: 2026-09-11. Карточка B-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D16, D21, D27, D30, D34 ([decisions.md](../decisions.md)). Контрактные случаи
1–10 из [h01-contract.md](h01-contract.md) §3 (11 — non-finite — обязанность адаптеров,
`LayoutPoint` конечен по конструкции).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| `PointerSessions` (`TrellisCore`) | `Sources/TrellisCore/Events/PointerSessions.swift` | Сессия на `pointerID`: маршрут `[NodeID]` из снимка на `down` (implicit capture, D27), `mountEpoch`, `rootID`, последняя точка. `send(_:_:snapshot:root:)`: `down` → hit-test последнего снимка → `route(to:)` → dispatch; `move`/`up`/`cancel` → та же сессия, где бы ни был указатель; `up`/`cancel` освобождают ровно один раз. Отмена: `routeBroken` в результате dispatch (D21/D28), другой `mountEpoch` (D21/D34), `cancelAll` — сессия забывается, затем один `pointerCancel` по маршруту (с последней точкой). Single-touch (D30): второй `pointerID` при живой сессии → `.secondaryPointer`, сессии нет; повторный `down` того же `pointerID` без `up` → старая отменена (`.pointerRestarted`), новая начата. Хранит только identity/epoch — ни одной `Node`. |
| `PointerOutcome` / `PointerCancelReason` | там же | `.delivered(EventResult)`, `.noTarget`, `.noSession`, `.secondaryPointer`, `.hostInactive`; причины отмены — для лога и будущего arena-reset (H05). |
| Вход на bridge | `NodeHostBridge.send(_:_:)`, `activePointerSessionCount` | `.hostInactive` без корня, в `suspend`, при `skipsLayoutOnlyWrappers`. `suspend()` и `detachCurrentRoot()` (detach и замена корня) — `cancelAll` **до** остановки coordinator'а и снятия слоёв: handlers на маршруте ещё видят живое дерево. |
| Лог | `LogArea.event` | `session-begin`/`session-end`/`session-cancel` (reason), `no-target`, `secondary-pointer`, `host-inactive`. |

## Дефект по ходу — #31

Weak-тест `PointerSessions` показал, что корень с одним `addSubnode` не освобождается — и
без сессии, и после `dispose()`. Причина не в H04: `Node.pendingOrigin` (C09) сильно
удерживал origin pending-окна инвалидации до `consumePendingInvalidation()`; когда origin —
сам корень (любая мутация на корне), это self-retain, и дерево без хоста или с мутацией после
последнего commit до `detach()` жило вечно. Зарегистрирован [#31](../defects.md), исправлен в
этой карточке: `pendingOrigin` — `weak`, при исчезновении origin до drain корень отчитывается
собой. Регрессионный тест —
`test_invalidation_pendingWindowDoesNotRetainAnUnmountedTree` в `InvalidationTests.swift`.

## Ограничение, оставленное H05

Отмена доставляет `pointerCancel` через обычный dispatch. Если маршрут уже не резолвится
(target disposed/reparent-нут), через дерево не доходит ничего — даже к живым предкам.
D21 требует «recognizers/control получают внутренний cancel»: это делает arena H05, которая
держит recognizers сессии и сбрасывает их напрямую, без дерева. Здесь зафиксировано, чтобы
H05 не считала это решённым.

## Тесты

`swift test --filter "pointerSessions|nodeHostBridge_pointer|suspendAndDetach|flattenedWrappersRefuse|replacingRootCancels"`
— 16 тестов, все зелёные:

| Тест | Случай h01 §3 / приёмка H04 |
|---|---|
| `test_pointerSessions_routeIsFixedAtDownAndReleasedAtUp` | 1; release ровно один раз |
| `test_pointerSessions_downOutsideAnyNodeOrWithoutSnapshotStartsNothing` | `.noTarget` |
| `test_pointerSessions_commitOnSameMountKeepsSession` | 2, 3, 9/10 (commit между down и up не рвёт сессию) |
| `test_pointerSessions_newMountCancelsSession` | смена mount epoch |
| `test_pointerSessions_disposingRouteNodeCancelsSessionWithoutDelivery` | 4 |
| `test_pointerSessions_handlerBreakingRouteMidDispatchCancelsSession` | reparent внутри callback |
| `test_pointerSessions_cancelAllDeliversOneCancelAndEmptiesStore` | 5, 6; idempotent |
| `test_pointerSessions_pointerCancelFromHostReleasesOnce` | host cancel |
| `test_pointerSessions_pointerIDIsReusableAfterSessionEnds` | 7 |
| `test_pointerSessions_secondPointerIsRefusedWhileOneIsActive` | 8 |
| `test_pointerSessions_downWithoutPreviousUpRestartsDeterministically` | повторный down |
| `test_pointerSessions_retainsNoNode` | stale session не удерживает `Node` (weak) |
| `test_nodeHostBridge_pointerEventsFollowSessionAcrossCommits` | bridge: `.hostInactive`/`.noTarget` до commit, resize сохраняет сессию |
| `test_nodeHostBridge_suspendAndDetachCancelSessions` | 5, 6 через bridge; reattach — чистый старт |
| `test_nodeHostBridge_flattenedWrappersRefusePointerInput` | `skipsLayoutOnlyWrappers` → `.hostInactive` |
| `test_nodeHostBridge_replacingRootCancelsSessionOnOldTree` | замена корня — cancel на старом дереве, epoch 2 |

`python3 Scripts/check_all.py` — зелёный; API baseline `TrellisCore` (+`PointerSessions`,
`PointerOutcome`, `PointerCancelReason`) и `TrellisRender` (+`send(_:_:)`,
`activePointerSessionCount`) — только добавления, review note — этот документ.

## Не входит

«Сброс pressed/recognizers не вызывает activation» из приёмки H04 — проверяется в H05/H06,
когда появятся recognizers и control; здесь сессия лишь гарантирует, что после отмены ни одно
событие не доставляется и `activeCount == 0`.
