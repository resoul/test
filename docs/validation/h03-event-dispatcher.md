# H03 — Event/EventPhase/PointerData и three-phase dispatcher

Дата: 2026-09-11. Карточка B-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D20, D28, D30 ([decisions.md](../decisions.md)). Контрактные случаи 1–10 из
[h01-contract.md](h01-contract.md) §2. Перенос из Weave `Events.swift` — по духу, строки в
[source-provenance.md](../source-provenance.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Типы | `Sources/TrellisCore/Events/Event.swift` | `EventType` (4 pointer-случая — D23/D30), `EventPhase`, `PointerData` (`point`, `pointerID`; без `windowID` — D30), `EventPayload` (один case, расширяемый), `Event` (`@MainActor final class`: `targetID: NodeID`, `phase`, `stopPropagation()`, `preventDefault()`), `EventResult` (`propagationStopped`, `defaultPrevented`, **`routeBroken`**, **`reachedTarget`**). |
| Хуки на `Node` | `Node.swift` | `open func handleCapture/handleEvent/handleBubble(_ event: Event)`, пустые — тот же стиль, что `arrangeSubnodes()`. |
| Dispatcher | `Sources/TrellisCore/Events/EventDispatcher.swift` | `dispatch(_:route:root:)`: маршрут `[NodeID]` (root → target) резолвится по живым `subnodes` от `root` один раз; перед **каждым** callback проверяется, что цепочка root → … → узел цела (`!isDisposed`, `supernode === предыдущий`). Первое нарушение — конец пользовательской доставки, `routeBroken = true`. В bubble-фазе проверяется весь маршрут до target: bubble идёт «от имени» target, и target, уехавший под другого родителя (случай 8), старых предков не имеет. Re-entrant. |
| Маршрут из снимка | `HitTestSnapshot.route(to:)` | root-first `[NodeID]` по `parent`-ссылкам снимка; `nil` для ноды не из commit'а. |
| Лог | `LogArea.event` | `unresolved` (маршрут не резолвится), `route-broken` (с фазой). |

## Уточнение контракта по ходу (D28 → h01 §2)

D28 в `decisions.md` говорит «отсутствующая/disposed нода **пропускается**», а согласованные
примеры h01 §2 (случаи 6–8) требуют: удаление target или предка **прекращает** дальнейшую
доставку, включая bubble на `R`. Реализована формулировка примеров — она строже и
безопаснее: продолжать bubble к предкам после того, как target исчез или переехал, значило бы
доставить `pointerUp`/`pointerMove` по маршруту, которого на экране уже нет; сессия после
этого всё равно отменяется (D21). Weave-тест
`eventDispatcherUsesAncestrySnapshotWhenTargetIsRemovedDuringCapture` ожидал обратного
(доставка по снимку живых ссылок) — это та «альтернатива», которую D28 явно отвергает, тест
перенесён с обратным ожиданием. Формулировку D28 в `decisions.md` уточнить при переносе
следующих решений — здесь только зафиксировано.

Второе: удаление и возврат ноды под того же родителя внутри callback маршрут **не** рвёт
(родительская связь восстановлена к моменту проверки) — добавлен тест.

## Тесты

`swift test --filter "eventDispatcher|routeIsRootFirst"` — 11 тестов, все зелёные:

| Тест | Случай h01 §2 |
|---|---|
| `test_eventDispatcher_runsCaptureTargetBubbleInExactOrder` | 1 |
| `test_eventDispatcher_stopPropagationInEachPhase` | 2, 3, 4 |
| `test_eventDispatcher_preventDefaultDoesNotStopPropagation` | 5 (половина dispatcher'а; recognizers — H05) |
| `test_eventDispatcher_disposingTargetDuringCaptureEndsDelivery` | 6 |
| `test_eventDispatcher_removingAncestorAtTargetEndsBubble` | 7 |
| `test_eventDispatcher_reparentingTargetAtTargetEndsBubble` | 8 |
| `test_eventDispatcher_removingAndReaddingUnderSameParentKeepsRoute` | — (уточнение выше) |
| `test_eventDispatcher_nestedDispatchHasItsOwnRoute` | 9 |
| `test_eventDispatcher_unresolvableRouteDeliversNothing` | 10 (+ чужой корень, пустой маршрут, disposed root) |
| `test_eventDispatcher_handlerMayDisposeWholeTreeSynchronously` | приёмка H03 «callback синхронно мутирует дерево» |
| `test_hitTestSnapshot_routeIsRootFirst` | `route(to:)` |

`python3 Scripts/check_all.py` — зелёный; API baseline `TrellisCore` +44 символа (типы событий,
dispatcher, три хука `Node`, `route(to:)`), без изменённых/удалённых — обновлён этим
документом как review note.

## Не входит

Кто строит `Event` и вызывает `dispatch` по реальному вводу — pointer session (H04);
recognizers и default action (H05/H06); резолв через bridge (`NodeHostBridge.hitTest` уже
даёт `NodeID`, `hitTestSnapshot.route(to:)` — маршрут; связка — H04).
