# R12b — GridNode

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R12b.
Зависимость: R12a (закрыта). Решение: [ADR 0033](../adr/0033-grid-node.md). Статус: **закрыта**.

## Что реализовано

| Файл | Содержание |
|---|---|
| `Sources/TrellisCore/Collections/GridLayout.swift` | `GridLayout` (`.fixed`/`.adaptive` колонки, `columnSpacing`, `.measured`/`.aspectRatio` высота), `CollectionMetrics`, `CollectionGeometry.resolve` — общий расчёт рядов для синхронной перестройки и воркера |
| `Sources/TrellisCore/Collections/MaterializationWindow.swift` | ряды как прокручиваемая единица, `grid`, `columnCount`, `itemOffset(at:)`, `itemIndex(at:)`, окно по рядам → элементы, размещение ячеек по колонкам, якорь по ряду; #87 |
| `Sources/TrellisCore/Collections/CollectionNode.swift` | весь runtime контейнера (бывший ListNode) |
| `Sources/TrellisCore/Collections/ListNode.swift`, `GridNode.swift` | тонкие подклассы: только выбор раскладки; `GridNode.layout` меняется на лету |
| `Playground/Shared/Scenarios/S36_GridNodeMedia.swift` | consumer: квадратные плитки, адаптивные колонки ≥ 96 pt, 30 на страницу с медленного API |

Отдельной копии reactive/scroll runtime нет: GridNode использует те же `CollectionLoader`,
`CollectionUpdateQueue`, `MaterializationBudget`, хостинг и события, что ListNode.

## Проверки

- `GridLayoutTests.swift` (8, реальный `FlexboxEngine`): число колонок и ширина ячейки
  (fixed/adaptive/минимум 1); ячейки по колонкам со spacing (x 0/110/220, ряд 106 при
  rowSpacing 6); высота ряда = самая высокая измеренная ячейка; aspect-ячейки без измерения
  и без прыжка при первой ширине (#87); 10 000 ячеек × 4 колонки → 32 живые ноды, видимые
  диапазоны — целые ряды; смена ширины 400 → 250 (3 → 2 колонки) и смена `grid` 2 → 5
  колонок сохраняют якорь, prepend тоже; пагинация `remainingItems` считает элементы после
  последнего видимого ряда.
- `ListNodeHostTests.swift` +2 (настоящий `NodeHostBridge`): GridNode грузит через общие hooks,
  один `.loadMore` у конца; изменение ширины хоста 320 → 200 перекладывает 3 → 2 колонки,
  якорь на месте, native offset совпадает с окном.
- Все прежние тесты коллекций (списки R10–R12a, property-тест R11) проходят без изменения
  ожиданий на новой основе с рядами.
- iPhone 18 Pro Simulator: S36 — 3 адаптивные колонки квадратных плиток со spacing 6 pt
  (скриншот при ручном запуске). Playground собирается для macOS, iOS, tvOS.

Прогоны: `swift test` — Core 542, Flux 28, Render 323; в полных прогонах падает по одному
нестабильному тесту анимаций (M12 или M06, дефект #82), изолированно проходят;
`check_policy.py` — 0; `swift format lint` чисто; strict build тестов чисто; API baseline
TrellisCore обновлён с `--review-note docs/adr/0033-grid-node.md` (члены ListNode переехали в
`CollectionNode`, для исходного кода совместимо).

## Найдено по ходу

- #87 (исправлен): якорь захватывался при нулевой полной длине и уводил в конец.

## Не закрыто

- Горизонтальные сетки, masonry и произвольные grid-solvers — вне плана (§7).
- UI-тест прокрутки сетки на Simulator не писался: механика прокрутки и якоря та же, что у
  ListNode (R12a XCUITest); сетка отличается только раскладкой, покрытой тестами выше.
