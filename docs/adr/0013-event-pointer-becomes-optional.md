# ADR 0013 — `Event.pointer` становится `PointerData?`; новые типы и payloads событий

Дата: 2026-09-11. Решение D48 (A01), реализация в A07.

## Изменение

```
- public var pointer: PointerData
+ public var pointer: PointerData?

  public enum EventType {
      case pointerDown, pointerMove, pointerUp, pointerCancel
+     case focusIn, focusOut
+     case keyDown, keyUp
  }

  public enum EventPayload {
      case pointer(PointerData)
+     case focus(FocusData)
+     case key(KeyData)
  }
```

`api/TrellisCore.json` фиксирует `pointer` как `changed` (тип), новые cases
и типы `FocusData`/`KeyData`/`KeyboardKey` — `added`.

## Почему это source-breaking и почему принято

`Event.pointer` с H03 был non-optional, потому что `EventPayload` имел одну
case. Любой внешний код вида `let p = event.pointer.point` перестаёт
компилироваться и должен стать `guard let pointer = event.pointer`. Это
единственное source-breaking изменение этапа; альтернатива — оставить
non-optional accessor, который для focus/key событий возвращал бы
фиктивные координаты, — прямо противоречит D43 («без поддельных
координат»): `ControlNode.track` читал `event.pointer` **до** `switch` по
типу и на `.focusIn` получил бы `(0, 0)`, а не отказ.

Добавление cases в публичный `enum` без `@unknown default` в потребителе
тоже не считается source-compatible (exhaustive `switch` над `EventType`
или `EventPayload` перестаёт компилироваться). Этап принимает это
осознанно: пакет без ABI-стабильности, единственный внешний consumer —
`Scripts/verify_bootstrap.py`, мигрирует в том же коммите (A07).

## Миграция

| Было | Стало |
|---|---|
| `event.pointer.point` | `guard let pointer = event.pointer else { return }` |
| `switch event.payload { case .pointer(let p): … }` | добавить `case .focus`, `case .key` (или `default`) |
| `switch event.type { … }` exhaustive | добавить четыре новых case |

`ControlNode` мигрирует сам: `track(_:)` сначала выбирает ветку по типу
события и читает `pointer` только для pointer-типов; focus/key ветки
читают `event.focus`/`event.key`.

## Решение

Обновить baseline через этот ADR при реализации A07 (`check_api.py --update
--review-note docs/adr/0013-event-pointer-becomes-optional.md`).
