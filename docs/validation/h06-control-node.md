# H06 — Control-примитив без Flux

Дата: 2026-09-11. Карточка B-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D22, D29 (5), D34 ([decisions.md](../decisions.md)). Контрактные случаи 1–7 из
[h01-contract.md](h01-contract.md) §5. Перенос из Weave `Controls.swift` — по духу (без
`Interaction`/`ActionPipe`), строка в [source-provenance.md](../source-provenance.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| `ControlNode` (`TrellisCore`) | `Sources/TrellisCore/Controls/ControlNode.swift` | `open class ControlNode: Node`. `activation: (@MainActor () -> Void)?` — без `ActionPipe`/`Interaction` (D22, G07). `isPressed` — приватный сеттер, `didSet` вызывает `markAppearanceDirty()` при изменении значения (paint-only путь). Внутренний `TapRecognizer`, зарегистрированный в `init` через `addGestureRecognizer`. |
| Pressed-tracking | `ControlNode.track(_:)`, вызывается из `handleEvent`/`handleBubble` | `pointerDown` → `isPressed = true` безусловно (маршрут доходит до control только если down уже «внутри» — D27); `pointerMove` → `event.snapshot?.contains(point, node: id)`; `pointerUp`/`pointerCancel` → `isPressed = false` безусловно. Не переопределяет `handleCapture` — обе оставшиеся фазы взаимоисключающи для одной ноды на одно событие (target получает `handleEvent`, предок — `handleBubble`, никогда оба), двойной обработки нет. |
| Up-inside по последнему коммиту (D22/D34) | `HitTestSnapshot.contains(_:node:)` (новый метод в `HitTest.swift`), `Event.snapshot` (новое поле) | `PointerSessions.deliver(...)` передаёt в `Event` **свой** аргумент `snapshot` (тот же снимок, что использован для валидности сессии на этом конкретном событии — не снимок с `pointerDown`, а текущий на момент вызова). `contains(_:node:)` — независимая от `hitTest(_:)` проверка: протаскивает точку через transform/clip предков **только до `identity`**, не ищет самый глубокий хит — декоративный ребёнок внутри control не meняет результат (H01 §5 (7)). `ControlNode.tapEnded(at:)` (колбэк `tap.onTap`) сверяет `lastSnapshot` (последний увиденный в `track()`, т.е. снимок этого самого `pointerUp`) перед вызовом `activation?()`. |
| Default action Tap (D29 (5)) | `tap.onTap = { [weak self] point in self?.tapEnded(at: point) }` | Активация — только когда Tap выиграл арбитраж (не Pan, не отменена сессией/`preventDefault`) **и** committed-геометрия говорит «внутри»; оба условия независимы и оба обязательны. |

## Почему не понадобился отдельный канал «снимок → control»

`HitTestSnapshot` уже живёт в `TrellisCore` (не в `TrellisRender`), поэтому добавить его как
поле на `Event` не нарушает границу слоёв (D16): `PointerSessions` (тоже `TrellisCore`) и так
получает актуальный снимок каждым вызовом `send(...)`, и естественно прокидывает его в
создаваемый `Event`. Это позволило не трогать сигнатуры `open`-хуков `Node` (уже публичный
контракт с H03) и не заводить параллельный API только для control.

## API baseline и ADR

`Event.init(type:targetID:payload:)` получил параметр `snapshot: HitTestSnapshot? = nil`;
добавление параметра меняет mangled-имя — старая сигнатура значится `removed`, новая
`added`, хотя изменение source-совместимо (тот же случай, что ADR 0002 для
`Node.init(environment:)`). Задокументировано в [ADR 0011](../adr/0011-event-init-gains-snapshot-parameter.md)
и использовано как `--review-note` при обновлении `api/TrellisCore.json`. Остальные новые
символы (`ControlNode` целиком, `HitTestSnapshot.contains(_:node:)`, `Event.snapshot`) —
только добавления.

`Node.markAppearanceDirty()` перестал быть `private` (стал internal, без модификатора) —
не публичный API, в baseline не попадает; причина — `ControlNode` живёт в отдельном файле
того же модуля и использует тот же paint-only путь, что `appearance`'s `didSet`.

## Тесты

`swift test --filter controlNode_` — 13 тестов, все зелёные (через
`PointerSessions`/`GestureArena` — как в production, не напрямую):

| Тест | Случай h01 §5 |
|---|---|
| `test_controlNode_downInsideSetsPressedAndInvalidates` | 1 |
| `test_controlNode_moveOutsideClearsPressedMoveBackRestoresIt` | 2 |
| `test_controlNode_upInsideActivatesExactlyOnceAndClearsPressed` | 3 (+ второй `up` без сессии — не крашится, не активирует повторно) |
| `test_controlNode_upOutsideDoesNotActivate` | 4 |
| `test_controlNode_cancelDoesNotActivateAndClearsPressed` | 5 (host pointerCancel) |
| `test_controlNode_hostCancelAllDoesNotActivateAndClearsPressed` | 5 (`cancelAll` — detach/suspend) |
| `test_controlNode_disposeDuringPressDoesNotActivate` | 5 (dispose control посреди press) |
| `test_controlNode_arbitrationLossToPersDoesNotActivateAndClearsPressed` | 5 (Pan выигрывает) |
| `test_controlNode_activationMayDisposeControlWithoutRepeatedDeliveryOrCrash` | 6 |
| `test_controlNode_activationMayDetachTheWholeTreeWithoutRepeatedDeliveryOrCrash` | 6 |
| `test_controlNode_decorativeChildHitStillRoutesActivationToControl` | 7 |
| `test_controlNode_commitBetweenDownAndUpUsesLatestGeometry` | D22/D34: control переехал между down и up — up-inside по новому снимку в обе стороны |
| `test_controlNode_moveTrackingFollowsLatestCommitTooD34` | то же для live pressed-tracking на `pointerMove` |

Случаи 6 (реентерабельность) проверены буквально, не только по рассуждению: активация,
вызывающая `control.dispose()` — тест проверяет `isDisposed` и `activations == 1`; активация,
вызывающая `sessions.cancelAll(reason: .hostDetached, root:)` (тот самый путь, которым
`bridge.detach()` внутри closure привёл бы к реентерабельному вызову в ту же
`PointerSessions`/`GestureArena`, которые в этот момент ещё выполняют текущий `handle(_:)`) —
тест проходит без падения и без второй активации; трассировка вручную подтвердила, почему:
`GestureArena.close()`/`cancel()` идемпотентны, а `ControlNode.track(_:)` для повторно
доставленного синтетического `pointerCancel` не совпадает по `trackedPointerID` (уже `nil`
после исходного `up`) и не производит побочных эффектов.

## Не входит

Настоящие `UITouch`/`NSEvent` → `PointerData` (H07/H08); `long-press`/`double-tap` (D23);
публичный API `isEnabled`/`isLoading` из Weave (не запрошены этим этапом, не входят в H06).
