# R12c — TableNode и действия строк

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R12c.
Зависимость: R12a (закрыта). Решение: [ADR 0034](../adr/0034-table-node.md). Статус: **закрыта**.

## Что реализовано

| Файл | Содержание |
|---|---|
| `Sources/TrellisCore/Collections/CollectionNode.swift` | `CollectionNode<Provider, SourceItem>`: преобразование источник → окно, `refreshPresentation()`, `didApply(_:)` |
| `Sources/TrellisCore/Collections/SwipeActions.swift` | `RowAction`, `RowActionResult`, `RowSwipeEdge`, `SwipeActionsPolicy`, `RowSwipeContextKey`, `RowSwipePhase`, `RowSwipeController` |
| `Sources/TrellisCore/Collections/TableNode.swift` | `TableRow`, `TableSelectionMode`, `RowSwipeRecognizer`, `TableAppearance`, `TableCellNode`, `TableCellProvider`, `TableNode` |
| `Playground/Shared/Scenarios/S37_TableNodeInbox.swift` | consumer: 3 секции, 40 писем, Pin / Archive / Delete, выбор, статус swipe |
| `Playground/UITests/iOSScrollTests.swift` | XCUITest: настоящий swipe строки внутри вертикальной прокрутки |

Покрытие P6.6: leading/trailing; несколько действий; full swipe (первое действие стороны,
`allowsFullSwipe`); RTL — стороны по направлению чтения, физический жест и сдвиг зеркалятся;
update — ячейка обновляется на месте по ID; delete — открытая строка закрывается, действие не
переходит на соседа и не повторяется; reuse — пула нет, ноды привязаны к ID (R10); failure →
строка остаётся открытой с «Retry», повтор блокируется пока действие выполняется;
альтернативный ввод — те же действия как AX custom actions у строки (VoiceOver, switch
control, AppKit/tvOS accessibility); политики `.automatic/.disabled/.enabled` и
`RowSwipeContextKey` для составных контейнеров.

## Проверки

- `TableContractTests.swift` (8): строки с контекстом секции и выбором; политики; контроллер —
  порог открытия, full swipe, сторона без действий, одна открытая строка, удалённая строка,
  блокировка повтора, ошибка → retry, действие удалённой строки не повторяется; распознаватель
  — горизонтальный начинается, вертикальный отказывает.
- `TableNodeHostTests.swift` (7, настоящий `NodeHostBridge`, события указателя через bridge):
  выбор single/multiple и `onSelect`; заголовки в первых строках, нет разделителя у последней;
  swipe открывает 2 кнопки (сдвиг −160), Delete удаляет только эту строку; full swipe
  выполняет Archive; RTL открывает trailing слева (сдвиг +160); контекст контейнера выключает
  жест, AX custom action работает, `.enabled` переопределяет; ошибка → Retry → успех.
- iPhone 18 Pro Simulator, XCUITest с настоящими касаниями
  (`testTableRowSwipeRevealsActionsAndDeleteRemovesTheRow`): нажатие выбирает строку;
  горизонтальный swipe внутри вертикального `UIScrollView` открывает строку
  (`open=2 revealed=160 phase=open`), кнопки Archive/Delete доступны как кнопки; Delete
  удаляет только эту строку (`rows=39 last=deleted 2`); вертикальная прокрутка после этого
  работает. Все 4 iOS UI-теста (R08, R12a, R12c) — `** TEST SUCCEEDED **`.

Прогоны по частям: TrellisCoreTests 550, TrellisFluxTests 28, TrellisRenderTests 330 — все
прошли; `check_policy.py` 0; `swift format lint` чисто; strict build тестов чисто; API baseline
TrellisCore обновлён с `--review-note docs/adr/0034-table-node.md` (второй generic-параметр
`CollectionNode`, снятые ограничения `evaluateDemand`). Playground собирается для macOS, iOS,
tvOS.

## Найдено по ходу (в собственном коде карточки, исправлено до сдачи)

- Нажатие на кнопку действия считалось и нажатием на строку (закрывало её до результата) —
  распознаватель нажатия перенесён на контент.
- Элемент доступности сначала был всей ячейкой, потом строкой: заголовок секции и кнопки
  сливались с ней; теперь элемент — контент строки, заголовок и кнопки отдельно.
- Кнопки действий не имели роли `.button`.
- Уже созданные ячейки не пересчитывали политику swipe при её смене и при смене контекста.

## Не закрыто

- Закреплённые (sticky) заголовки секций, контекстное меню и клавиатурные сочетания для
  действий строк — не входят; путь без жеста — AX custom actions.
- Использование `RowSwipeContextKey` pager'ом — R14.
- Swipe на iPad trackpad / macOS trackpad не проверялся.
