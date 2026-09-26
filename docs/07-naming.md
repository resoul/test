# Именование

## Правило суффиксов

**Статус: согласовано.**

> Суффикс `Node` убирается везде, **кроме имён, которые совпадают со стандартной
> библиотекой Swift**. Совпадения со SwiftUI допустимы.

Единственное исключение сейчас — `CollectionNode`.

Базовый класс остаётся `Node`. Бренд живёт в имени модуля, а не в имени типа (как в
AGENTS.md Trellis).

## Таблица переименований

| Trellis | Espalier | Примечание |
|---|---|---|
| `Node` | `Node` | базовый класс |
| `TextNode` | `Text` | совпадает со SwiftUI — допустимо |
| `ImageNode` | `Image` | реализовано в `NodesRender`; совпадает со SwiftUI — допустимо |
| `ControlNode` | `Control` | |
| кнопка | `Button` | совпадает со SwiftUI — допустимо |
| `ScrollNode` | `Scroll` | `ScrollView` занят в SwiftUI; `Scroll` свободно. Реализовано (2026-09-25); `ScrollAxis`, `ScrollRange`, `ScrollItem`, `contentOffset`, `overscroll`, `platformDidScroll(to:)`, `scrollToReveal` — предложено |
| `TableNode` | `Table` | совпадает со SwiftUI — допустимо |
| `GridNode` | `Grid` | совпадает со SwiftUI — допустимо |
| `TabsNode` | `Tabs` | |
| `TabbedScrollNode` | `TabbedScroll` | |
| `Pager` | `Pager` | уже без суффикса |
| `CollectionNode` | `CollectionNode` | **согласовано**: остаётся с суффиксом — `Collection` это протокол стандартной библиотеки Swift |

## Следствия совпадений со SwiftUI

Конфликт проявляется только в файле, где импортированы **и** SwiftUI, **и** модуль Espalier:
там тип указывается с модулем (`<Модуль>.Text`). На практике это редко, поэтому принято.

## Прочие имена

| Имя | Статус |
|---|---|
| `layoutSpec()` — метод раскладки (`layout()` занят в `NSView`; `arrange()`/`makeLayout()` отклонены) | согласовано (2026-09-25) |
| `LayoutSpec` — тип описания раскладки (не `Layout`: в файлах с SwiftUI была бы неоднозначность с `SwiftUI.Layout`); `FlexContainer` — его псевдоним | реализовано |
| `LayoutElement`, `LayoutSpecProviding`, `applyLayoutSpec()` | реализовано |
| `FlexContainer` | согласовано (по примеру) |
| `Breakpoint` | реализовано (`Breakpoint(from:) { } otherwise: { }`) |
| `BreakpointWidth` (`.sm` … `.xxl`, число) — тип порога; вместо `Breakpoint.Width` из черновика, потому что `Breakpoint` — псевдоним `LayoutSpec` и не может иметь вложенных типов | реализовано |
| `Spacing` (`.s1` … `.s9`, `.points`), `SpacingScale` (`.standard`) | реализовано |
| Пороги `.sm` / `.md` / `.lg` / `.xl` / `.xxl` | согласовано (значения — предложено, [04](04-conditionals-and-responsive.md#именованные-пороги)) |
| `from:` — единое слово порога в `Breakpoint` и модификаторах | согласовано (2026-09-25) |
| Имена токенов отступов — номера шагов `.s1` … `.s9` | согласовано, [09](09-theme.md#имена-отступов--вариант-b) |
| `NodeCache` | согласовано (2026-09-25) |
| `LazyStack` (`items`, `estimatedLength`, `spacing`, `laidOutItems`) — колонка или строка, раскладывающая только элементы у окна; имя по `LazyVStack`/`LazyHStack` SwiftUI, ось — `ScrollAxis`, как у `Scroll` | реализовано (2026-09-26); имена — предложено |
| `.hidden(_:)` — убирает из раскладки (CSS `display: none`, `isHidden` в `UIStackView`) / `.invisible(_:)` — оставляет место. В SwiftUI `.hidden()` место оставляет — смысл обратный; это сказано в doc-комментарии | согласовано (2026-09-25) |
| `.collapsesWhenEmpty()` | реализовано |
| `.sticky(top:leading:bottom:trailing:)` — CSS `position: sticky`; `StickyPosition`, `Node.stickyOffset`, `subnodesInDrawingOrder`, `applyLayoutSticky` | реализовано (2026-09-25); имена — предложено |
| `.if(_:_:)` — условный модификатор | реализовано |
| `LayoutView` / `LayoutNSView`, `NodeView` / `NodeNSView` — view-классы адаптеров: UIKit без префикса, AppKit с `NS` | согласовано (2026-09-25) |
| «Раскладку надо пересчитать»: `Node.setNeedsLayout()`; у view — `setNeedsLayoutSpec()`, потому что системный `setNeedsLayout` не сбрасывает `intrinsicContentSize`, а переопределить его нельзя — UIKit зовёт его сам при смене bounds, и Auto Layout зациклится | согласовано (2026-09-25) |
| Названия модулей (`Nodes`, `StateCore`, …) | предложено; вопрос «Trellis v2 или новая библиотека» закрыт — отдельная библиотека, совместимость с API Trellis не нужна |
| Название продукта и пакета — `Espalier` (`Trellis` занят другим Swift-пакетом) | согласовано (2026-09-25) |
| Модуль раскладки — `LayoutCore`; `Layout` нельзя (протокол SwiftUI) | принято |
| Имена модулей, папок, файлов, переменных окружения — по содержимому, без названия продукта (`Espalier`, `Trellis`) и кодового имени (`v22`) | согласовано, [AGENTS.md](../AGENTS.md#имена) |
| Тип длины — `Length` (`.auto`, `.points`, `.fraction`); `Dimension` нельзя (класс Foundation) | принято |
