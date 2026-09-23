# R12 — Закрыть результат C

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R12.
Зависимости: R12a/R12b/R12c (закрыты). Решение: [ADR 0035](../adr/0035-collection-reveal-and-row-focus.md).
Статус: **закрыта частично**. Корректность и ограниченная материализация подтверждены на
всех платформах. Числовые бюджеты R06 не назначены — нет замеров на устройстве
(см. «Не закрыто»).

## Что добавлено в карточке

| Файл | Содержание |
|---|---|
| `Sources/TrellisCore/Collections/CollectionNode.swift` | `scrollTo(_:alignment:animated:completion:)`, `CollectionScrollResult` (P6.9) |
| `Sources/TrellisCore/Collections/HostedContainer.swift`, `Sources/TrellisRender/Scroll/NodeHostBridge+Containers.swift` | `ContainerHost.scrollContainer` через команды R07 |
| `Sources/TrellisCore/Collections/TableNode.swift` | строка — `ControlNode` (фокус, выбор с пульта/клавиатуры/AX); открытый swipe закрывается при вытеснении |
| `Sources/TrellisCore/Collections/Pagination.swift` | исправление #88 |
| (дефект) | #89 — строки таблицы не принимали фокус; найден на tvOS, исправлен |
| `Tests/TrellisRenderTests/CollectionResultCTests.swift` | 10 тестов на настоящем bridge |
| `Tests/TrellisFluxTests/ExternalConsumerCollectionsTests.swift` | внешний consumer без `@testable`: 4 теста, 10 случаев |
| `Tests/TrellisCoreTests/Collections/*` | #88, смена окружения между prepare и commit (layout / только paint) |
| `Scripts/verify_bootstrap.py` | внешний пакет-consumer собирает и запускает List/Grid/Table |
| `Playground/Shared/PerfHarness.swift` | сценарий `--perf-scenario collections` |
| `Playground/UITests/tvOSScrollTests.swift` | XCUITest с настоящим пультом по строкам S37 |

## Пункты карточки

- **check_policy.** `PASS policy 2.0.0 (0 diagnostics)`, включая PUBLIC_DOCUMENTATION для
  нового API.
- **Внешний consumer P6.10/P6.11.** Два уровня.
  - `verify_bootstrap`-consumer — отдельный пакет, `-warnings-as-errors`: provider,
    delegate и `RowAction` объявлены вне модуля; public init всех трёх контейнеров;
    closure и delegate в одном dispatcher; `scrollTo` до mount → `.notAttached`.
    Результат: `PASS consumer`.
  - `ExternalConsumerCollectionsTests` (import без `@testable`, Flux-модель через
    `bindFlux`), для List/Grid/Table с одинаковым dataset:
    - хуки до mount не запускают запросы;
    - viewport заполняется без жеста до `endReached`: `[initial, loadMore ×3]`, у каждой
      ревизии один запрос;
    - на mount ровно две привязки: Flux-лента и контейнер;
    - remount не повторяет запрос;
    - замена источника дважды: поздний ответ `files-a` не попадает в `files-b`;
    - closure-only, delegate-only и смешанный режим вызывают ровно один callback; снятие
      closure возвращает delegate; слабый delegate освобождается;
    - провайдер вызывается только на MainActor (`assertIsolated`);
    - после unmount модель и контейнер освобождаются.
- **Standalone на платформах.**
  - iOS Simulator: 4 XCUITest.
  - tvOS Simulator: 2 XCUITest, из них новый — настоящий `XCUIRemote` доводит фокус до
    `message-20` за экраном, `select` выбирает строку (`selected 20`).
  - Скриншоты S35/S36/S37 на iOS и tvOS.
  - macOS: `--export-all` S35–S37; запуск сцен с `TRELLIS_LOG` — у всех трёх
    `container-attach` и 4–6 `dataset-applied`; AppKit-тесты с настоящим
    `NSScrollView` (R12a); perf-прогон в настоящем окне.
- **Consumer 10 000 моделей.** `test_resultC_tenThousandModelsPrependDeleteAndLoadMoreWhileScrolling`:
  40 шагов прокрутки, в каждом prepend / удаление 20 случайных / смена высот. В каждом шаге:
  - нет дублей ID;
  - нет ID вне snapshot;
  - живых ≤ 48 и столько же подузлов контента;
  - применена последняя ревизия.

  Догрузка в конце срабатывает. На 1 000 и 10 000 моделей при одинаковом viewport число
  живых элементов одинаково.
- **Focus/AX и reveal виртуализированного элемента.**
  - `scrollTo(7321)` в List/Grid/Table на 10 000: `.completed`, верх измеренного кадра у
    края viewport (±0.5 pt), материализовано ≤ 96.
  - В AX-дереве элемент ровно один, дублей идентификаторов нет.
  - `.end` и `.center` используют измеренную длину.
  - Фокус с клавиатуры вниз по 60 строкам списка и 30 строкам таблицы идёт строго по порядку;
    Return выбирает строку.
- **P6.9.**
  - Выбор строки таблицы восстанавливается после вытеснения и возврата; открытый swipe
    сбрасывается.
  - List и Grid в одном хосте делят один `MaterializationBudget`.
  - Известная цель → `.completed`; неизвестная → `.notFound` без движения.
  - Новая команда отменяет старую (`.cancelled`); жест отменяет; удаление цели во время
    reveal → `.notFound`; detach → `.notAttached`.
  - Смена окружения, влияющего на layout, между prepare и commit отклоняет подготовку
    (`rejectedCount == 1`), якорь сохраняется. Смена только paint не отклоняет.
- **Cold/warm, fling/разворот, 100 циклов.**
  - Bridge: `test_resultC_hundredOpenCloseCycles…` — 100 × attach/detach TableNode.
    Привязки возвращаются к базовому числу, бюджет 0, задач загрузки 0, запросов нет,
    контейнер освобождается.
  - Нативно: сценарий `collections`, таблица ниже.

Мутации проверены: без цикла уточнения reveal падают тесты выравнивания и отмены; без
закрытия swipe при вытеснении — тест P6.9; без исправления #88 — unit-тест и consumer-тест
для всех трёх контейнеров.

## Замеры (`--perf-scenario collections`, 10 000 моделей, Release)

Команда та же, что в [R06](r06-native-performance/README.md), с
`--perf-scenario collections --perf-count 10000 --perf-seed 7 --perf-repeats 20 --perf-warmup 0`.
Viewport: 402×874, на tvOS 1920×1080.

Строка — `TextNode` с текстом переменной длины. Шаг прокрутки — команда
`.to(offset)` на 0.75 viewport (40 шагов вперёд и 20 назад, разворот) до commit, в котором
видимые строки имеют кадры и display готов. Проход «cold» идёт по неизмеренным строкам,
«warm» повторяет тот же путь. «Warm open» — 100 циклов открытия и закрытия нового контейнера.
Данные: [r12-collections-perf/](r12-collections-perf/).

| Платформа | Контейнер | cold open (1 замер) | cold шаг p50/p95 | warm шаг p50/p95 | разворот p50/p95 | warm open p50/p95 | max живых | после закрытия (живых / привязок) | RSS МиБ до → после 100 циклов |
|---|---|---|---|---|---|---|---|---|---|
| macOS | list | 42.0 | 13.2 / 29.7 | 9.5 / 12.7 | 9.7 / 11.7 | 25.6 / 30.6 | 40 | 0 / 0 | 92 → 84 |
| macOS | grid | 28.5 | 12.1 / 14.4 | 8.2 / 10.4 | 8.3 / 9.3 | 26.4 / 35.6 | 42 | 0 / 0 | 81 → 81 |
| macOS | table | 45.5 | 21.9 / 38.8 | 15.8 / 19.7 | 15.2 / 17.2 | 35.9 / 42.9 | 39 | 0 / 0 | 57 → 50 |
| iOS Sim | list | 452.7 | 28.7 / 86.9 | 19.8 / 92.3 | 32.4 / 44.0 | 35.5 / 62.2 | 44 | 0 / 0 | 142 → 114 |
| iOS Sim | grid | 76.7 | 18.1 / 25.3 | 12.8 / 18.6 | 18.4 / 33.9 | 38.7 / 66.3 | 42 | 0 / 0 | 99 → 95 |
| iOS Sim | table | 61.0 | 25.6 / 29.7 | 20.6 / 29.0 | 20.9 / 35.7 | 38.1 / 68.4 | 44 | 0 / 0 | 102 → 92 |
| tvOS Sim | list | 142.5 | 35.9 / 77.2 | 19.6 / 36.3 | 24.0 / 72.3 | 35.4 / 78.4 | 64 | 0 / 0 | 147 → 141 |
| tvOS Sim | grid | 60.7 | 48.1 / 96.6 | 54.4 / 103.4 | 42.8 / 72.9 | 69.8 / 158.5 | 90 | 0 / 0 | 100 → 93 |
| tvOS Sim | table | 95.2 | 51.6 / 102.1 | 24.9 / 57.9 | 46.4 / 62.3 | 54.0 / 126.2 | 64 | 0 / 0 | 117 → 104 |

Время в мс. Таймаутов нет ни в одном прогоне. `deviceModel` везде `Mac14,2`:
Simulator работает на хостовом Mac.

## Не закрыто (явно)

- **Числовые бюджеты R06 не назначены.** R06 записал baseline только на Simulator и хосте.
  Физического iPhone, iPad и Apple TV нет, Instruments trace и hitch rate не сняты. По §6 это
  открытый пункт: числа выше — эталон для повтора в R15, а не бюджет. Разбивка на
  snapshot / worker / commit по фазам тоже не снята — измерено время от запроса до commit.
- Fling в замере эмулирован шагами программной прокрутки. Настоящая инерция проверена
  только на корректность: XCUITest R08 (detach во время инерции) и R12a (drift=0 при
  приходе данных). Кадров и пропусков во время инерции никто не мерил.
- iPad (трекпад, клавиатура) не запускался; swipe трекпадом на macOS и iPad не проверен
  (как в R12c).
- Снимок окна macOS не сделан: `screencapture` без права на запись экрана не снимает окно.
  macOS подтверждён экспортом, логом и AppKit-тестами.
- Эталоны screenshot gate для S35–S37 не добавлены: gate сломан до R10 (#83, открыт).
- Timing-тесты класса #82: `m04_…` упал в одном полном прогоне Render на macOS и вместе с
  `m12_…` — в matrix на tvOS Simulator. Отдельно оба зелёные, Render частями —
  201 + 41 + 37 + 209 без падений. Причина не устранена (#82 открыт).

## Проверки

| Проверка | Результат |
|---|---|
| `swift format lint -r` | чисто |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| TrellisCoreTests / TrellisFluxTests | 553 / 32 — все зелёные |
| TrellisRenderTests | 340; в полном прогоне 1 падение timing-теста (#82), частями — все зелёные |
| `check_api.py` (5 модулей) | PASS; baseline TrellisCore (+8) и TrellisRender (+1) обновлены по ADR 0035 |
| `verify_bootstrap.py --matrix` | PASS: toolchain/format/manifest, library-build, tests (полный `swift test` в этом прогоне зелёный), consumer, macOS universal, iOS device, tvOS device, iOS Simulator (все тесты). tvOS Simulator: 553 + 32 зелёные, Render 336/338 — упали `m12_gesture…` и `m04_nodeAnimate…` (класс #82); отдельно на том же tvOS Simulator — 2/2 дважды. Первый прогон matrix упал раньше: строгая сборка нашла предупреждение в новом тесте (`weak var` → `weak let`), исправлено |
| iOS XCUITest (iPhone 18 Pro Simulator) | 4/4 |
| tvOS XCUITest (Apple TV 4K Simulator) | 2/2 |
| Playground Release: macOS, iOS Simulator, tvOS Simulator | собираются, perf-прогоны завершены |

## Приёмка

Материализация ограничена окном и не зависит от числа моделей. Все три контейнера работают
отдельно на macOS, iOS и tvOS: данные, reveal, фокус, AX, действия. Внешний consumer
использует только public API. Остаются открытыми числовые бюджеты и trace на устройстве:
это требование §6, закрывается в R15 на физических устройствах. Интеграция в pager — R14.
