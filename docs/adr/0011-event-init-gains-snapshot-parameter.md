# ADR 0011 — `Event.init` gains a `snapshot` parameter

Дата: 2026-09-11. Часть H06.

## Изменение

`api/TrellisCore.json` помечает старый инициализатор как `removed` (а не
`changed`), по той же причине, что и ADR 0002: добавление параметра меняет
mangled-имя символа:

```
- init(type: EventType, targetID: NodeID, payload: EventPayload)
+ init(type: EventType, targetID: NodeID, payload: EventPayload,
+      snapshot: HitTestSnapshot? = nil)
```

Новый `public let snapshot: HitTestSnapshot?` на `Event` и новый метод
`HitTestSnapshot.contains(_:node:)` добавлены тем же коммитом — `added`, не
`removed`/`changed`.

## Почему это не breaking change для существующих вызовов

Новый параметр `snapshot` — с дефолтом `nil` в конце списка. Каждый
существующий вызов (`EventDispatcherTests`, `GestureTests`, ручное
конструирование `Event` в будущих платформенных адаптерах) продолжает
компилироваться и вести себя одинаково: `nil` даёт событие без снимка, как
раньше — эти вызовы никогда не читали геометрию. Ломается только *бинарная*
сигнатура, что для source-уровня Swift-пакета без ABI-стабильности не
является проблемой на этом этапе (тот же аргумент, что в ADR 0002).

## Зачем нужен снимок на Event

`ControlNode` (H06, D22) должен решать «up-inside» по **последнему**
committed снимку геометрии на момент конкретного события, а не по снимку на
момент `pointerDown` (D34: между down и up может пройти commit, сдвинувший
control). `PointerSessions` уже держит текущий снимок в момент каждого
вызова `send(...)` — он же передаётся в создаваемый `Event`, и обработчик
(`ControlNode.track(_:)`, `tapEnded(at:)`) читает `event.snapshot` вместо
того, чтобы протаскивать снимок отдельным параметром через
`Node.handleCapture/handleEvent/handleBubble`, сигнатура которых менять не
хотелось (это `open`-хуки, уже часть публичного контракта с H03).

Синтезированный `pointerCancel` из `PointerSessions.cancel(...)` снимок не
передаёт (`nil`) — отмена не активирует ничего и не нуждается в геометрии.

## Решение

Обновить baseline через этот ADR: единственный практический эффект —
`Event` можно создать со снимком коммита, который держатели `open`-хуков
читают через `event.snapshot` для точных, актуальных на момент события
геометрических проверок (up-inside, live pressed-tracking).
