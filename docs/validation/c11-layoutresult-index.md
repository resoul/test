# C11 — Индекс LayoutResult

Дата: 2026-09-10. Реализована на `LayoutResult` (C06) без изменения формы
`placements`/`treeIdentity`.

## Что добавлено

- `Sources/TrellisCore/Layout/LayoutResult.swift`: private `index: [NodeID: Int]`,
  построенный один раз в `init`, прямо из переданного `placements` — другого
  пути его построить нет, поэтому индекс не может разойтись с массивом
  (чек-лист: «структура неизменяема, индекс не может разойтись с массивом»).
- `placement(for:)` теперь использует `index[identity].map { placements[$0] }`
  — indexed lookup, не `.first { $0.identity == ... }`. Это ровно паттерн,
  который `LINEAR_IDENTITY_LOOKUP` ловит в `Sources/TrellisCore/Layout/`
  (не написан здесь намеренно ни разу, включая цикл построения индекса,
  который проходит массив один раз целиком, а не ищет по одному элементу).
- `duplicateIdentities: Set<NodeID>` — собирается тем же проходом, что строит
  индекс. Первое вхождение дублированного `NodeID` остаётся в индексе,
  повторные добавляются в `duplicateIdentities`, не перезаписывают первое —
  явный отказ от «победил последний» без диагностики.
- `isWellFormed: Bool` — `duplicateIdentities.isEmpty`. Не бросает и не
  паникует: результат остаётся обычным значением, а решение «не коммитить
  это» откладывается будущему coordinator (C14), у которого есть что не
  начинать — до применения хотя бы одного placement, а не посреди прохода.
- `LayoutResult` получил ручной `Equatable`/`Hashable` (по `placements`+`treeIdentity`
  — `index` не сравнивается и не хэшируется, поскольку он полностью выводим
  из `placements`: у равных массивов всегда равные индексы, отдельно сравнивать
  нечего). Причина ручной реализации — `[NodeID: Int]` не `Hashable`, синтез
  не сработал бы, если бы `index` остался в списке синтезируемых свойств.

## Проверки

`Tests/TrellisCoreTests/Layout/LayoutResultTests.swift` — 7 новых тестов:
существующий/отсутствующий identity, `isWellFormed`/`duplicateIdentities`
на обычном результате (пусто) и на результате с одним дублированным
`NodeID`, `placement(for:)` для дублированного identity детерминированно
возвращает первое вхождение (не последнее), `duplicateIdentities` не задевает
уникальные identity в том же результате, и корректность lookup на 500
placements — обычная проверка соответствия индекса массиву, явно
прокомментированная как **не** доказательство O(1) (по требованию приёмки).

| Проверка | Результат |
|---|---|
| `swift test` (162 теста, включая 7 новых) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics — включая `LINEAR_IDENTITY_LOOKUP` |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c11-layoutresult-index.md` | UPDATED — только добавления |
| `python3 Scripts/check_all.py` | PASS |

## Не засчитывается этим отчётом

Никто ещё не читает `isWellFormed`/`duplicateIdentities` перед commit — этот
потребитель появляется в C14 (`RenderCoordinator`). Сам солвер, который мог
бы производить дубликаты, тоже не существует (C12).
