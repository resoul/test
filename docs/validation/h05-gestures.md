# H05 — Регистрация recognizers, арбитр, Tap, Pan

Дата: 2026-09-11. Карточка B-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D21, D23, D29, D31 ([decisions.md](../decisions.md)). Контрактные случаи 1–11 из
[h01-contract.md](h01-contract.md) §4. Перенос из Weave `Gestures.swift` — по духу, строки в
[source-provenance.md](../source-provenance.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Recognizer contract | `Sources/TrellisCore/Gestures/GestureRecognizer.swift` | `GestureState`, `GestureResult`, `GestureConfiguration` (`tapSlop`, `panThreshold`, по 10 pt, невалидные → default), протокол `GestureRecognizer` (`state`, `handle(_:)`, `reset()`). `reset()` — активный жест отчитывается `.cancelled` ровно один раз, ожидающий молча в `.possible`; idempotent. |
| `TapRecognizer` | там же | down → move в пределах slop (`<=`; сверх — `.failed`) → up → `.ended`, `onTap(point)`. Без max duration и без clock (D31). |
| `PanRecognizer` | там же | `.began` при `distance > panThreshold` (ровно порог — нет), `.changed` на каждый move, `.ended`/`.cancelled` ровно один раз; `onPan(PanGesture)` со `start`, `current`, `translation`, `delta`. |
| Регистрация на ноде | `Node.addGestureRecognizer/removeGestureRecognizer/gestureRecognizers` | Порядок регистрации; дубликат — no-op; `dispose()` сбрасывает список (иначе node → recognizer → closure → node — цикл). |
| Arena | `Sources/TrellisCore/Gestures/GestureArena.swift` | Per-session. Порядок — как собрано: recognizers target, затем каждого предка до корня (D29 (3)). До победителя каждое событие идёт по порядку; первый `.began` — winner, остальные `reset()` и больше ничего не видят; `.ended` за один шаг (Tap) решает арбитраж, но **winner не сохраняется** (G06) — событие закрывает сессию. `.ended`/`.failed`/`.cancelled` winner'а, `pointerUp`/`pointerCancel` и `cancel()` закрывают arena и сбрасывают всех для следующей сессии. |
| Связка с сессией | `PointerSessions` | Arena создаётся на `down` из живого маршрута. После dispatch (capture → target → bubble): `routeBroken` → cancel; `defaultPrevented` → arena событие не получает (D29 (2)); иначе `arena.handle(event)`. На release (`up`/`cancel`) arena закрывается всегда — и когда up был prevented. При отмене сессии `arena.cancel()` вызывается **до** доставки `pointerCancel` по дереву — это и есть прямой сброс recognizers из D21, закрывающий ограничение, оставленное H04: маршрут может уже не резолвиться, recognizers всё равно узнают. |

Не перенесено намеренно: `DoubleTap`/`LongPress`/`Pinch`/`Rotation` (D23), `GestureClock`
(D31 — нет длительностей), capture внутри arena (D27 — сессия и так держит маршрут).

## Тесты

`swift test --filter gestures_` — 12 тестов, все зелёные (сессии гоняются через
`PointerSessions`, arena собирается так же, как в production):

| Тест | Случай h01 §4 / приёмка H05 |
|---|---|
| `test_gestures_tapWithoutMovementEndsAndPanResets` | 1 |
| `test_gestures_tapSlopBelowAtAndAboveThreshold` | 2, 3, 4 — 9 pt / ровно 10 / 11 |
| `test_gestures_panReportsTranslationAndDeltaThenEnds` | 5 — `began t=11 d=11`, `changed t=20 d=9`, `ended` |
| `test_gestures_targetRecognizerBeatsAncestorRecognizer` | 6 (+ down мимо target — только предок) |
| `test_gestures_registrationOrderBreaksTiesOnOneNode` | 7 |
| `test_gestures_oneStepEndedLeavesNoWinnerBehind` | 8 (G06), закрытая arena игнорирует события |
| `test_gestures_pointerCancelCancelsActivePanOnceAndEmptiesArena` | 9 (+ `cancelAll` хоста — `.cancelled` ровно один раз) |
| `test_gestures_brokenRouteResetsRecognizersDirectlyWithoutActivation` | D21: target disposed посреди Pan — `.cancelled` через arena, activation нет |
| `test_gestures_sequentialSessionsDoNotMixWinners` | 10 |
| `test_gestures_preventDefaultKeepsRecognizersOut` | 11 (+ prevent только на up — activation нет, recognizers чисты) |
| `test_gestures_recognizerRegistrationOnNode` | порядок, дубликаты, remove, dispose |
| `test_gestures_configurationNormalizesInvalidThresholds` | конфигурация |

`python3 Scripts/check_all.py` — зелёный; API baseline `TrellisCore` — только добавления
(типы жестов, arena, три метода `Node`), review note — этот документ.

## Не входит

Control-примитив и activation как default action Tap (H06); `preventDefault` до сих пор
проверен через override `handleEvent` в тесте — control сделает это своим API.
