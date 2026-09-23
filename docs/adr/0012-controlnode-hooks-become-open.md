# ADR 0012 — `ControlNode.handleEvent`/`handleBubble` become `open`

Дата: 2026-09-11. Часть H09.

## Изменение

`api/TrellisCore.json` помечает оба переопределения как `changed` (не `added`/`removed`):
мангл-имя не меняется, меняется только `accessLevel` в декларации символа.

```
- public override func handleEvent(_ event: Event)
+ open override func handleEvent(_ event: Event)

- public override func handleBubble(_ event: Event)
+ open override func handleBubble(_ event: Event)
```

## Почему это не breaking change для существующих вызовов

`open` **расширяет** доступ (`public` → `open`), не сужает: любой существующий вызов или
переопределение, которое компилировалось при `public`, продолжает компилироваться без
изменений — `open` лишь добавляет возможность, которой раньше не было (переопределение вне
модуля `TrellisCore`), а не убирает существующую.

## Зачем это понадобилось

H09 (`Playground/Shared/Scenarios/S21_TapCounter.swift`, отдельный модуль-потребитель)
подклассирует `ControlNode`, чтобы показать pressed-состояние и исход жеста без Flux/текста
(N01 вне рамок): `TapCardNode.handleEvent`/`handleBubble` вызывают `super.xxx(event)` (тем
самым `ControlNode.track(_:)` обновляет `isPressed`), затем читают `isPressed` и
`event.type`, чтобы перекрасить карточку. Без `open` это переопределение невозможно вне
`TrellisCore` — `ControlNode` сам по себе уже `open class` (иначе Playground не мог бы
наследоваться от него вовсе), но два конкретных метода остались `public`, что и потребовало
исправления здесь.

## Решение

Обновить baseline через этот ADR: единственный практический эффект — consumer-код (Playground,
будущие приложения на Trellis) может встраивать собственную реакцию на события поверх
`ControlNode`'а базового трекинга нажатия, не изобретая параллельный набор колбэков.
