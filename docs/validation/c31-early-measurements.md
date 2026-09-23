# C31 — Ранние измерения и повторяемые нагрузочные fixtures

Дата: 2026-09-11. Устройство: MacBook Air (Apple Silicon, arm64), macOS 26.4.1, Release,
`TRELLIS_LOG=off`, 20 итераций на метрику. Физических iOS/tvOS-устройств нет (C20) —
бюджеты по ним не выбирались.

## Инструмент

- `Bench/` — consumer-пакет (как Smoke в `verify_bootstrap.py`; манифест Trellis сохраняет
  граф из четырёх библиотек), исполняемый `TrellisBench`. Хост — голый `CALayer` через
  `NodeHostBridge`, MainActor-задачи (flush, hop результата, доставка binding'а)
  прокачиваются `RunLoop.main` — не `Task.yield()`: в `async main` yield ждал ~10 ms на
  каждый hop, и все «to-commit» показывали ровные 80 ms независимо от дерева.
- `Scripts/bench.py [--iterations N] [--log all] [--label …] [--write-summary]` — собирает
  Release, запускает, кладёт JSON в `docs/validation/measurements/<дата>-<label>-release[-log-…].json`
  и печатает Markdown. Измерения — evidence, не gate: время не проверяется; точные
  счётчики закреплены тестами (`HostRenderStatisticsTests`, 5 тестов).
- Новое публичное: `NodeHostBridge.statistics: HostRenderStatistics`
  (requested/coalesced/stale/committed/retries/cancelled), `materializedLayerCount`,
  `LayerRenderer.layerCount`.

Fixtures (фиксированные параметры, LCG seed 7 для размеров):

| Fixture | Что | Параметры |
|---|---|---|
| `deep-local-edit` | цепочка `Column` с padding, правка одного самого глубокого листа; отдельно фазы snapshot/solve/apply тем же путём, что координатор | depth 30, 8 соседей на уровень, 272 ноды |
| `wide-100`, `wide-1000` | wrap-row; resize по одному; burst из 60 bounds за один ход; paint-only всем нодам; геометрия всем нодам | 101 / 1001 нод |
| `attach-detach` | 20 циклов attach → commit → detach свежего дерева; слои после, живой root, resident/peak | 1001 нод |
| `state-burst` | `StateSubject<Int>` → `update` на 1000 нод; 1000 `send` за один ход | 1001 нод × 1000 sends |
| `two-hosts` | два bridge, синхронное обновление обоих деревьев | 2 × 501 |
| `cancel-latency` | `LayoutScheduler` напрямую: request → cancel → `onWorkerFinished`; и solve без отмены | цепочка depth 200 (1002 ноды); одна линия 5000 items |

## Результаты (Release, log off)

Полная таблица — [measurements/2026-09-11-macos-arm64-release.md](measurements/2026-09-11-macos-arm64-release.md).

| Метрика | p50 ms | p95 ms |
|---|---|---|
| wide-100: attach → первый commit | 0.69 | — |
| wide-100: правка геометрии всех нод → commit | 0.47 | 0.55 |
| wide-1000: attach → первый commit | 8.5 | — |
| wide-1000: правка геометрии всех нод → commit | 7.7 | 7.9 |
| wide-1000: resize → commit | 7.5 | 7.7 |
| wide-1000: burst 60 resize → commit (1 request) | 7.6 | — |
| wide-1000: paint-only всем нодам (0 solve) | 1.5 | 1.6 |
| deep-local-edit (272 нод, depth 30): snapshot / solve / apply | 0.48 / 3.5 / 0.05 | 0.79 / 4.9 / 0.07 |
| deep-local-edit: правка одного листа → commit | 4.4 | 4.5 |
| attach-detach (1001 нод): attach → commit → detach | 8.9 | 9.0 |
| state-burst: 1000 send → 1 update × 1000 нод → commit | 8.0 | 8.3 |
| two-hosts (2 × 501): оба обновления → оба commit | 3.8 | 3.9 |
| cancel → выход worker'а, depth 200 | 0.09 | 0.13 |
| cancel → выход worker'а, одна линия 5000 | 0.08 | 0.14 |
| solve без отмены: depth 200 / линия 5000 | 89 / 116 | 100 / 122 |

Счётчики: burst из 60 resize — `requested +1`; paint-only — `coalesced +1`, `requested`
без изменений; state-burst — 20 доставок на 20 burst'ов; два хоста — по 21 commit, `stale
= 0`; attach-detach — `layers-after = 0`, root после release освобождён (weak → nil).
Память: 1001 нод в слоях — +1.4 MiB resident; 20 циклов attach/detach — resident с 17.6
до 51.5 MiB при нулевых живых объектах — удержание allocator/runtime, как план и
допускает; peak = resident-after.

Накладные расходы диагностики (`--log all`, 3 итерации, stdout в pipe): solve 3.5 → 11.0 ms,
wide-1000 attach 8.5 → 15.4, state-burst 8.0 → 14.0, paint-only 1.5 → 2.2. Основной профиль
— только с логом off.

## Что измерения нашли и что исправлено

1. **Дефект #13 — кэш измерений на 64 записи** ([ADR 0007](../adr/0007-request-local-measure-cache-unbounded.md)):
   первый же fixture (depth 30) не завершался за 10 минут; глубина 14 стоила 141 ms в
   debug. Hash map без практического предела: depth 14 — 5.5 ms, depth 200 — 0.6 s debug /
   89 ms release.
2. **Дефект #14 — O(depth²) в проходе размещения** (открыт): каждый уровень измеряется под
   своим фактическим cross-constraint и промахивается всем поддеревом. depth 30 — 3.5 ms,
   depth 200 — 89 ms release. Реальные экраны глубже 30 редки; закрыть, когда потребуется
   (варианты в реестре).
3. **Дефект #15 — O(n²) сборка flex-линий**: `resolveLines` пересчитывал main-размер
   открытой линии reduce'ом по всей линии на каждый item. Исправлено бегущей суммой
   (одна линия 5000: 137 → 116 ms; остаток — 2 измерения на item).
4. **Checkpoints отмены (уточнение C12)**: точки были только на входе контейнера и на
   границах линий — одна линия из 5000 items отменялась 21.6 ms. Добавлен checkpoint
   каждые 256 items внутри линии: 0.08 ms; deep — 0.09 ms. Стоимость горячего цикла —
   одно сравнение остатка.
5. **Дефект #10 закрыт по замеру**: paint-only по всему дереву из 1001 ноды — 1.5 ms
   (1.5 µs/ноду); точечный список origin'ов не нужен на этапе 1.

Артефакты харнесса, которые тоже пришлось выучить (не дефекты Trellis): равное значение —
no-op и не даёт commit (два fixture ждали commit после записи того же размера — pump
теперь с таймаутом и WARNING); `settle()` не входит в измеряемое окно.

## По пунктам карточки

- [x] Baseline при первом рабочем C17 — **не выполнен вовремя**: C17 закрыт 2026-09-10,
  харнесс появился только сейчас. Первая база — эта, после renderer, Arrangement и C29;
  «до завершения Arrangement» — не сделано, это отмечено честно.
- [x] Fixtures: глубокая вложенность с локальной правкой, частые resize, attach/detach,
  burst state-updates — есть, параметры и seed фиксированы.
- [x] 100/1000 нод, два хоста; живая память (weak) отдельно от resident.
- [x] Повторять после renderer/реактивного пути/Arrangement — харнесс есть, повтор —
  одна команда; бюджеты на физическом устройстве — ждут C20-доступа.
- [x] Cancel-latency измерена, checkpoints уточнены.
- [x] Release + log off основной профиль, отдельный прогон с логом; счётчики — в тестах,
  время — не в тестах.

## Открыто

- Дефект #14 (квадратичность по глубине).
- Allocations не измерялись (нужны malloc-хуки/Instruments; `ru_maxrss`/`resident` есть).
- Бюджеты p50/p95 для C26 выбирать на физическом устройстве; на этом Mac ориентир для
  1000-нодного экрана: обновление геометрии ≈ 8 ms, paint-only ≈ 1.5 ms.
