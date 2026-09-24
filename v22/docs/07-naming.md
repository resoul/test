# Именование

## Правило суффиксов

**Статус: согласовано.**

> Суффикс `Node` убирается везде, **кроме имён, которые совпадают со стандартной
> библиотекой Swift**. Совпадения со SwiftUI допустимы.

Единственное исключение сейчас — `CollectionNode`.

Базовый класс остаётся `Node`. Бренд живёт в имени модуля, а не в имени типа (как в
AGENTS.md Trellis).

## Таблица переименований

| Trellis | v22 | Примечание |
|---|---|---|
| `Node` | `Node` | базовый класс |
| `TextNode` | `Text` | совпадает со SwiftUI — допустимо |
| `ImageNode` (планируемый) | `Image` | совпадает со SwiftUI — допустимо |
| `ControlNode` | `Control` | |
| кнопка | `Button` | совпадает со SwiftUI — допустимо |
| `ScrollNode` | `Scroll` | `ScrollView` занят в SwiftUI; `Scroll` свободно |
| `TableNode` | `Table` | совпадает со SwiftUI — допустимо |
| `GridNode` | `Grid` | совпадает со SwiftUI — допустимо |
| `TabsNode` | `Tabs` | |
| `TabbedScrollNode` | `TabbedScroll` | |
| `Pager` | `Pager` | уже без суффикса |
| `CollectionNode` | `CollectionNode` | **согласовано**: остаётся с суффиксом — `Collection` это протокол стандартной библиотеки Swift |

## Следствия совпадений со SwiftUI

Конфликт проявляется только в файле, где импортированы **и** SwiftUI, **и** модуль v22:
там тип указывается с модулем (`<Модуль>.Text`). На практике это редко, поэтому принято.

## Прочие имена

| Имя | Статус |
|---|---|
| `layoutSpec()` — метод раскладки (`layout()` занят в `NSView`) | реализовано |
| `LayoutSpec` — тип описания раскладки (не `Layout`: в файлах с SwiftUI была бы неоднозначность с `SwiftUI.Layout`); `FlexContainer` — его псевдоним | реализовано |
| `LayoutElement`, `LayoutSpecProviding`, `LayoutView`, `LayoutNSView`, `applyLayoutSpec()` | реализовано |
| `FlexContainer` | согласовано (по примеру) |
| `Breakpoint` | реализовано (`Breakpoint(from:) { } otherwise: { }`) |
| `BreakpointWidth` (`.sm` … `.xxl`, число) — тип порога; вместо `Breakpoint.Width` из черновика, потому что `Breakpoint` — псевдоним `LayoutSpec` и не может иметь вложенных типов | реализовано |
| `Spacing` (`.s1` … `.s9`, `.points`), `SpacingScale` (`.standard`) | реализовано |
| Пороги `.sm` / `.md` / `.lg` / `.xl` / `.xxl` | согласовано (значения — предложено, [04](04-conditionals-and-responsive.md#именованные-пороги)) |
| `from:` — единое слово порога в `Breakpoint` и модификаторах | предложено |
| Имена токенов отступов — номера шагов `.s1` … `.s9` | согласовано, [09](09-theme.md#имена-отступов--вариант-b) |
| `NodeCache` | предложено |
| `.hidden(_:)` / `.invisible(_:)` | предложено |
| `.collapsesWhenEmpty()` | предложено |
| `LayoutView` / `LayoutNSView` — базовые view-классы адаптеров | открыто |
| Названия модулей (`Nodes`, `State`, …) | предложено; окончательное — после решения «Trellis v2 или новая библиотека» |
| Модуль раскладки — `LayoutCore`; `Layout` нельзя (протокол SwiftUI) | принято |
| Имена модулей, папок, файлов, переменных окружения — по содержимому, без названия продукта (`Trellis`) и кодового имени (`v22`) | согласовано, [AGENTS.md](../AGENTS.md#имена) |
| Тип длины — `Length` (`.auto`, `.points`, `.fraction`); `Dimension` нельзя (класс Foundation) | принято |
