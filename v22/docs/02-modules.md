# Модули

**Статус: согласовано** как принцип (P1). Имена модулей — **предложено**.

Имя `Layout` использовать нельзя: это протокол SwiftUI, и модуль с таким именем ломает
квалификацию типов (`Layout.X`) у всех, кто импортирует оба. Модуль раскладки —
`LayoutCore`. Имена модулей, папок и файлов описывают содержимое и не содержат названия
продукта или кодового имени версии ([AGENTS.md](../AGENTS.md#имена)).

Каждая система — отдельный модуль. Пользователь берёт ровно то, что ему нужно: только
flex-раскладку для обычных `UIView`, только дерево нод, только состояние.

## Карта

```
LayoutCore      чистая математика и описание раскладки. Только Foundation. Не знает про ноды.
LayoutUIKit     та же раскладка для UIView (в layoutSubviews)
LayoutAppKit    та же раскладка для NSView (в layout())
Nodes           дерево нод: Node, NodeHost; раскладка всего дерева одним проходом,
                подписка по чтению в layoutSpec()/update(); расчёт в фоне
                (NodeHost.solvesInBackground). Использует LayoutCore, StateCore.
NodesRender     дерево нод → дерево CALayer (QuartzCore), общий для UIKit и AppKit.
NodesUIKit      встраивание нод в UIKit: view.addSubnode(node)
NodesAppKit     встраивание нод в AppKit
Theme           (ещё не создан) тема: шкала отступов, цвета, типографика; тема по
                умолчанию (см. 09). Шкала отступов пока живёт в LayoutCore.
StateCore       синхронное состояние на MainActor с отслеживанием чтений: State, Computed,
                Observer, Effect, StateTransaction (см. 08). Только стандартная библиотека.
StateFlux       адаптер Flux ↔ StateCore (Flux ≥ 1.2.1)
```

Зависимости направлены только вниз:

```
NodesUIKit ──► NodesRender ──► Nodes ──► LayoutCore ◄── LayoutUIKit
NodesAppKit ─┘                                      ◄── LayoutAppKit
StateFlux ──► StateCore ◄── Nodes   (Nodes отслеживает чтения в layoutSpec()/update())
Nodes ──► Theme ──► LayoutCore      (план: модуля Theme ещё нет, см. 09)
```

## Правила

1. **`LayoutCore` не знает слова «нода».** Он оперирует *элементом раскладки*: элемент умеет
   измерить себя под ограничение и принять итоговый frame. Элементом может быть `Node`,
   `UIView`, `NSView` или тестовая заглушка.
2. **Движок один.** «Layout для UIKit/AppKit» — не второй и не третий движок, а адаптер,
   отвечающий на два вопроса: как измерить элемент и как выставить ему frame.
3. **Место расчёта определяется адаптером, а не движком.**
   - `UIView`/`NSView` измеряются только на main (`sizeThatFits`, `fittingSize`), поэтому
     раскладка обычных view считается синхронно на main — как у Yoga/FlexLayout.
   - Ноды измеряются через `Sendable`-измеритель (CoreText), поэтому их раскладка
     по-прежнему считается в фоне по снимку, с отменой (D09 Trellis).
   Движок — одна и та же чистая функция в обоих случаях.
4. **Flux не протекает в `LayoutCore` и `Nodes`.** Как и в Trellis, внешняя зависимость
   живёт только в своём адаптерном модуле.
5. **Платформенные импорты** — только в `*UIKit`/`*AppKit`, под `#if canImport(...)` в
   файлах адаптеров. `#if os(...)` запрещён (как в Trellis).

## Сценарии использования по отдельности

| Нужно | Подключить |
|---|---|
| Flex-раскладка обычных UIView без нод | `LayoutCore` + `LayoutUIKit` |
| То же на macOS | `LayoutCore` + `LayoutAppKit` |
| Экран на нодах в UIKit-приложении | `Nodes` + `NodesUIKit` |
| Ноды + реактивные данные из Flux | `Nodes` + `NodesUIKit` + `StateCore` + `StateFlux` |
| Тесты математики раскладки без платформы | `LayoutCore` |
