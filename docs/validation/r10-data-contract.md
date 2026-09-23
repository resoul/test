# R10 — контракт данных и окно материализации

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R10.
Зависимость: R09 (закрыта). Решения: [ADR 0030](../adr/0030-collection-data-contract.md).
Статус: **закрыта 2026-09-23**. Контейнеры, собирающие эти части (ListNode/GridNode/TableNode),
и подключение к хосту (`beginPass()`, correlation при mount) — R12a/b/c.

## Решения пользователя (2026-09-23)

| Вопрос | Выбор |
|---|---|
| Связь контейнеров со ScrollNode | Свой ScrollNode через композицию (owns-a), один native scroll на страницу |
| Дубли item ID | First-wins + строка лога `droppedDuplicates=N` |
| Trigger догрузки по умолчанию | `.remainingViewportLengths(2)`; `.remainingItems(n)` — явная настройка |

## Consumer до реализации контейнеров (P6.10)

Эскиз уточняет P6.10 на реальные типы R10. `ListNode`/`TableNode` появятся в R12a/R12c;
остальные имена ниже уже существуют.

```swift
struct FileRow: Sendable, Equatable { let name: String; let size: Int64 }

@MainActor
final class FileRowProvider: ItemProvider {
    func makeNode(for item: FileRow, id: FileID) -> FileRowNode { FileRowNode(item) }
    func update(_ node: FileRowNode, with item: FileRow, id: FileID) { node.update(item) }
}

// Модель владеет источником; сеть живёт в service и публикует snapshot.
let files = StateSubject(CollectionSnapshot<FileID, FileRow>.initial(dataKey: peerID))

let table = TableNode(                         // R12c
    source: files,                             // доставка — bindState mounted session (D14)
    provider: FileRowProvider(),
    pagination: PaginationPolicy(pageSize: 20) // trigger по умолчанию: 2 высоты viewport
)
table.events.onSelect = { [weak model] id in model?.openFile(id) }
table.events.delegate = coordinator            // weak; closure выше имеет приоритет
```

Внутри контейнера: `ScrollNode` → `MaterializationWindow.content`; `onScrollStateChanged`
передаёт offset/viewport в `updateViewport`, после commit раскладки контейнер зовёт
`recordMeasurements()`, `CollectionLoader.evaluateDemand(in:)` решает, запускать ли
`onLoadMore`. Hooks потребителя:

```swift
table.loader.onLoad = { [weak model] context in await model?.loadFirst(context) ?? .completed }
table.loader.onLoadMore = { [weak model] context in await model?.loadNext(context) ?? .completed }
// модель: после каждого await — guard loader.isCurrent(context); затем files.send(snapshot)
```

## Что реализовано (`Sources/TrellisCore/Collections/`)

| Файл | Содержание |
|---|---|
| `CollectionSnapshot.swift` | `CollectionItem`, `CollectionSection`, `CollectionLoadState`/`CollectionLoadError`, `CollectionSnapshot` с first-wins и O(1) `index(of:)` |
| `VirtualizationWindow.swift` | `ItemExtentIndex` (prefix sums, O(log N) lookup), `PreparationRanges`, `VirtualizationWindow.compute`, `ScrollDirectionHint` |
| `Pagination.swift` | `PaginationTrigger`, `PaginationPolicy`, `PaginationDecision`, `PaginationGate` |
| `ItemMeasurementCache.swift` | Кэш длин с причинами miss: absent/content/cross-extent/environment |
| `ItemProvider.swift` | `ItemProvider`, `ClosureItemProvider`, `CollectionDelegate`, `CollectionEventDispatcher` |
| `MaterializationWindow.swift` | MainActor-ядро: окно, make/update/replace/dispose по ID, абсолютное размещение, запись измерений, correlation, RTL для горизонтальной оси, `evaluatePagination` |
| `MaterializationBudget.swift` | Общий бюджет хоста: создания за проход, лимит live-нод, приоритеты active/adjacent/background, ротация |
| `CollectionLoader.swift` | `onLoad`/`onRefresh`/`onLoadMore`/`onRetry`, `CollectionLoadContext`, владение задачами и отмена |
| `Environment.swift` (изменение) | `EnvironmentKey.affectsLayout`, `EnvironmentSnapshot.layoutRevision`, общий clock ревизий (#81) |

Логи P6.12 в существующих областях: `commit dataset-applied` (dataKey, dataRevision, items,
droppedDuplicates), `schedule materialize` (visible/display, made/updated/replaced/disposed,
live), `measure extents-rebuilt` (reason, hit, miss по причинам), `measure items-measured`.

## Тесты

`Tests/TrellisCoreTests/Collections/` — 47 тестов, плюс регрессия #81 в `EnvironmentTests.swift`:

- `CollectionContractTests.swift` (19): first-wins по секциям; equality с revision/load state;
  extents с измеренными длинами и spacing; окно 10 000 элементов; ведущая сторона по
  направлению; cap сохраняет видимые; пустой viewport; пагинация — default trigger, один
  запрос на revision и повторное взведение после роста, no-progress до user scroll, лимит
  автоматических страниц на коротком контенте, failure → только явный retry, отмена,
  endReached и новый data key, `remainingItems` от последнего видимого; причины miss и prune
  кэша; dispatcher — приоритет closure и возврат к delegate, coalescing, weak delegate.
- `MaterializationWindowTests.swift` (9): 10 000 моделей → 20 live нод у начала и ≤ 64
  в середине; cap при огромном viewport; identity остающихся в окне и освобождение
  ушедших (weak); update vs replace по `canUpdate`; удаление элемента и prune измерений;
  смена data key; измеренные длины (реальный `FlexboxEngine`) перемещают следующие
  элементы, повторный проход стабилен; смена ширины инвалидирует измерения; dispose.
- `MaterializationBudgetTests.swift` (11): видимые не ждут бюджета, поля — по проходам;
  active раньше adjacent; лимит live-нод в пользу более срочного окна; снижение лимита
  отрезает поля на следующем проходе, видимые остаются; отложенный demand следует за
  сдвинутым viewport; ротация равных приоритетов; dispose снимает регистрацию, хосты
  независимы; формат лога — `host=none gen=none` до mount и два хоста; пагинация логирует
  решения, но не холостые тики; смена темы сохраняет измерения, смена направления — сбрасывает;
  RTL горизонтально — элемент 0 у правого края (реальный solve), физический offset
  переводится в логический.
- `CollectionLoaderTests.swift` (8, управляемый fake API): hooks не запускаются до активации;
  один initial, повтор после отмены, remount загруженных данных без запроса; поздний ответ
  старого data key игнорируется; dedup догрузки и refresh отменяет её, поздний результат
  страницы не применяется; успех страницы взводит следующую revision; ошибка страницы → только
  retry с `.retry(of: .loadMore)`; retry initial через `onRetry`; освобождение владельца
  отменяет задачу.

Прогоны 2026-09-23: `swift test` — 314 + 28 + 509 тестов прошли (в двух более ранних
прогонах по одному тесту, завязанному на время, упало вне R10 — дефект #82);
`python3 Scripts/check_policy.py` — 0 diagnostics; `swift format lint` чисто;
`check_api.py` PASS для всех модулей, baseline TrellisCore обновлён с
`--review-note docs/adr/0030-collection-data-contract.md`.

`python3 Scripts/check_all.py`: policy, toolchain, format, build, tests (со второй попытки —
#82), consumer, bootstrap, API (включая tvOS) — PASS; `check_log_env.py` — PASS.
**Screenshot gate — FAIL**, дефект #83: 41 расхождение и нет эталонов S33/S34; воспроизводится
и без изменений R10 (A/B), эталоны не обновлялись.

## Weave CollectionsTests → Trellis

Разбор по [weave-scroll-analysis.md](../weave-scroll-analysis.md) §9.

| Weave тест | Trellis |
|---|---|
| `virtualizationWindowKeepsOverscanBounded` | `test_window_tenThousandUniformItemsKeepsDisplayBounded` |
| `listRendersOnlyOverscanRangeAndPreservesStableIDs` | `test_materialization_tenThousandModelsCreateBoundedNodes`, `…keepsIdentityInWindow…` |
| `selectionAndDuplicateIDsAreBounded` | `test_snapshot_dropsDuplicateIDsFirstWinsAcrossSections`; selection — R12c |
| `sectionSnapshotProvidesHeaderContextAndMeasuredAnchor` | секции в snapshot; anchor — R11 |
| `adaptiveGridComputesAtLeastOneColumn` | R12b |
| `reuseAndContextMenuKeepStableIdentity` | reuse pool не вводится; focus/menu — R12 |
| `virtualizationWindowWithVariableHeightsComputesAccurateWindow` | `test_extentIndex_usesMeasuredLengthsForOffsetsAndLookup` |
| `virtualizedViewAutomaticallyCapturesMeasuredHeightsAfterLayout` | `test_materialization_measuredLengthsRepositionItems` (реальный solve) |

## Чек-лист карточки

| Пункт R10 | Статус |
|---|---|
| Анализ collections §3.1; measurement invalidation и log events в контракте/тестах | Готово: weave-scroll-analysis §9, причины invalidation, формат лога с двумя хостами и `none` |
| DataSource/ItemProvider/Delegate/hooks P6.11 | Готово: `StateSubject` как источник, provider, dispatcher, `CollectionLoader` |
| make/update, state lifetime, host budget, measurement pipeline P6.9; consumer P6.10 | Готово: make/update/replace, состояние у модели (ADR), `MaterializationBudget`, измерение через обычный проход раскладки хоста |
| Data trigger отдельно от UI preparation P6.8; no-progress | Готово |
| Разделение ListNode/TableNode/GridNode на consumer API | Готово в ADR (общее ядро, свой ScrollNode); проверка на реальных контейнерах — R12 |
| P6.4: IDs, duplicates, revision, snapshot/delta, anchor, estimates | Готово как контракт; delta и anchor реализуются в R11 по ADR 0030 |
| Visible/preload окна, ограниченные cache/jobs, отмена ушедших из demand | Готово: окна, cap, бюджет хоста, отложенный demand пересчитывается от текущего окна |
| Прототип 10 000 моделей, identity, weak-очистка | Готово |

## Найдено по ходу

- Дефект #81 (исправлен): ревизия environment потомка могла не меняться после изменения у
  предка — влияло на `DisplayKey` и проверки актуальности `RenderCoordinator`.
- Дефект #82 (открыт, вне R10): тесты, завязанные на время, иногда падают при полном прогоне.
- Дефект #83 (открыт, вне R10): screenshot gate `check_all.py` не проходит.

## Оставлено следующим карточкам

1. R11: anchor compensation, delta по base revision, фоновая подготовка diff/метрик.
2. R12a: `ListNode` — сборка ScrollNode + окно + loader + dispatcher, `beginPass()` и
   correlation от host bridge при mount.
3. Измерение строки без создания Node не вводится до замеров (P6.9).
