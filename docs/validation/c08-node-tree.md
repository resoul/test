# C08 — Минимальный Node и операции дерева

Дата: 2026-09-10. Реализован в объёме плана: только identity, style/appearance,
frame-слот и структура дерева. Flux/state/events/focus/accessibility/scroll/
backing/compose не перенесены — см. таблицу переноса `Node.swift` в
`docs/weave-analysis.md` (строка 492).

## Что добавлено

- `Sources/TrellisCore/Node.swift`: `@MainActor open class Node` (D02) —
  `id: NodeID`, `style: LayoutStyle`, `appearance: VisualStyle`,
  `calculatedFrame: LayoutFrame?` (пока никто не пишет — ждёт индексированный
  `LayoutResult.placement(for:)` из C11 и coordinator C14), `isDisposed`,
  `supernode`/`subnodes`.
- Дерево: `addSubnode(_:)` (append + reparent), `insertSubnode(_:at:)`,
  `moveSubnode(from:to:)` — выделенная операция reorder, отдельная от
  add-как-no-op при повторном добавлении текущего ребёнка. `removeFromSupernode()`
  — detach без dispose, допускает повторный attach в другое место с сохранением
  `NodeID`.
- `dispose()` — терминален и идемпотентен, каскадно освобождает поддерево,
  отсоединяется от родителя через `removeFromSupernode()` — родитель не
  остаётся со ссылкой на disposed-ребёнка в своём списке.
- Каждая операция дерева печатает `Log.on(.tree, …)` с исходом:
  `created`/`added`/`removed`/`moved`/`disposed`/`no-op`/`cycle-rejected`/
  `add-rejected`/`insert-rejected`/`move-rejected` — самоцикл и ancestor-cycle
  печатаются, а не молча игнорируются (правка §6.4/F-фикс из
  `weave-analysis.md`: «`addSubnode` молча игнорирует self/цикл — это обязано
  печататься»).
- `Scripts/verify_bootstrap.py::check_consumer` расширен: внешний `Card: Node`
  без `@testable`, переопределяющий `dispose()`, строит `addSubnode`/frame
  дерево и проверяет `disposed`/`subnodes.isEmpty` после dispose — закрывает
  открытый пункт C04 («subclass Node и DSL» consumer) для той части, что не
  требует ещё не существующего `arrangeSubnodes()`/DSL (C22).

## Осознанно не сделано в этой карточке

- `apply(_ result: LayoutResult)`/`didApplyLayoutResult` — ждут индексированный
  lookup `LayoutResult.placement(for:)` (C11) и coordinator (C14).
- `setNeedsLayout()`/ревизии/invalidation — C09. `style`/`appearance` пока
  простые mutable-поля без `didSet`.
- `EnvironmentScope`, safe area, `makeLayoutInputSnapshot()` — C10.
- `findNode(id:)`, `rootNode` — не входили в чек-лист C08; не добавлены
  превентивно (YAGNI), добавятся при первом реальном потребителе.
- `arrangeSubnodes()` — C22; `open` уже установлен на классе для будущего
  переопределения (D02), но метод не объявлен.

## Проверки

`Tests/TrellisCoreTests/NodeTests.swift` — 27 тестов: identity/defaults,
append/insert/move с валидными и невалидными индексами, self/ancestor-cycle
rejection, disposed-node rejection в обе стороны, same-parent no-op отдельно
от reorder, detach/reattach с сохранением `NodeID`, dispose идемпотентность,
каскад на потомков, отсутствие disposed-ребёнка в списке родителя,
subclass-override дисциплина (`guard !isDisposed` в переопределении).

| Проверка | Результат |
|---|---|
| `swift test` (103 теста, включая 27 новых) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/verify_bootstrap.py` (consumer с `Card: Node`) | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c08-node-tree.md` | UPDATED — только добавления |
| `python3 Scripts/check_all.py` | PASS |

## Не засчитывается этим отчётом

Инвалидация (C09), environment/safe area/snapshot (C10), измерение/раскладка
(C12), coordinator/commit (C14), Arrangement/DSL (C21–C22) — Node пока не
участвует ни в одном реальном layout-проходе.
