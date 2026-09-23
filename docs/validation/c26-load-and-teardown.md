# C26 — Нагрузочная проверка и завершение работы

Дата: 2026-09-11. Устройство: MacBook Air (Apple Silicon), macOS 26.4.1, Release,
`TRELLIS_LOG=off`, 20 итераций. **Физических iOS/tvOS-устройств нет (C20)** — бюджеты ниже
сняты на этом Mac и помечены предварительными; пункт «на выбранном физическом устройстве»
не выполнен.

## Что проверено

| Пункт | Как | Итог |
|---|---|---|
| Деревья 100/1000 нод, глубокая вложенность | fixtures C31 `wide-100/1000`, `deep-local-edit` (depth 30), scan глубины отдельными процессами | см. таблицу; глубина — см. #22/#23 |
| snapshot/solve/commit и layer create/reuse | `phase-*` в `deep-local-edit`; `createdLayerTotal` vs `materializedLayerCount` (тест `steadyTreeReusesEveryLayerAcrossCommits`: 20 commit'ов — 0 новых слоёв) | commit переиспользует слои |
| Burst mutations, отмена во время layout | тест `burstDuringLayoutCancelsInFlightWorkAndCommitsTheLastState` (depth 100, 30 правок, каждая после отправки request): `cancelled ≥ 1`, `retries == 0`, последнее состояние закоммичено; bench `resize-burst-60` — 1 request | нет бесконечных retry |
| Освобождение host/scenario/root после attach/detach | тест `repeatedAttachDetachReleasesEverything`: 10 mount'ов, после — `weak` root/bridge/hostLayer == nil, слоёв 0; bench `attach-detach` ×20: живой root нет, resident 18.8 → 51.1 MiB (allocator, не объекты) | нет необъяснимого роста |
| Реактивный сценарий C29 | `state-burst`: 1000 `send` → 1 update × 1000 нод → commit | 7.7 ms p50 |
| Лог off / выбранные области | основной профиль off; `--log all`: solve ×3 (C31) | — |

## Что нагрузка нашла и что исправлено

- **#22 — стек solver'а.** Worker жил на `Task.detached` (cooperative pool, 512 KiB стека);
  движок рекурсивен по уровню вложенности в обоих проходах → Release падал (SIGBUS) на
  глубине ~210, Debug — ~60. Тест C26 с depth 200 не проходил вовсе. Solve теперь на
  выделенном `Thread` с 16 MiB (`LayoutScheduler.workerStackSize`); Task остаётся владельцем
  ожидания у `beforeSolve`, отмена кооперативна (D09) через `Thread.cancel()` +
  `Thread.current.isCancelled` в `LayoutContext`. Поток регистрируется у планировщика из
  собственного тела — `Thread.cancel()` до старта тела не даёт ему выполниться, и
  continuation зависал бы (поймано тестом `recoversAfterStaleResult`). Новый предел:
  глубина 3000 (15 002 ноды) — 28 ms; 6000 — SIGSEGV. Цена: cancel → выход worker'а
  0.1 → 1.4–2.2 ms (hop поток → continuation → MainActor); при 16 ms кадре приемлемо.
- **#23 — O(nodes × depth) в размещении.** Каждый уровень возвращал массив placements
  всего поддерева и копировал его наверх: depth 3000 — 1032 ms. Один массив на проход
  (`inout`): 28 ms. depth 300: 12.3 → 1.7 ms.
- Артефакт харнесса: после #14/#23 200-уровневая цепочка решается за 1 ms — быстрее, чем
  cancel успевает прийти; `cancel-latency` перешёл на depth 1500 и не считает «финиш до
  cancel» как латентность.

## Сравнение с базой C31 (Release, p50 ms)

| Метрика | C31 | C26 | Что изменилось |
|---|---|---|---|
| deep-local-edit (272 нод, depth 30): solve | 3.53 | 0.43 | #14, #23 |
| deep-local-edit: правка листа → commit | 4.41 | 1.62 | — |
| deep-local-edit: attach → commit | 10.9 | 5.2 | — |
| wide-1000: геометрия → commit | 7.71 | 7.48 | без изменений (плоское дерево) |
| wide-1000: paint-only | 1.48 | 1.53 | — |
| state-burst | 8.00 | 7.69 | — |
| two-hosts | 3.81 | 3.62 | — |
| цепочка depth 200 (1002 нод): solve | 88.9 | ≈1.2 (в scan) | #14, #23 |
| цепочка depth 1500 (7502 нод): solve | падение стека | 13.2 | #22 |
| cancel → выход worker'а (deep / wide) | 0.09 / 0.08 | 2.2 / 1.4 | #22, цена потока |

Полные таблицы: [measurements/2026-09-11-macos-arm64-c26-release.md](measurements/2026-09-11-macos-arm64-c26-release.md).

## Ограничения и узкие места (зафиксированы)

- **Глубина:** до 3000 уровней на 16 MiB стека; практический ориентир — экраны глубже
  300 уровней не встречаются, depth 300 (1502 ноды) — 1.7 ms.
- **Переполняющиеся цепочки:** контейнер, чьё содержимое не влезает и сжимается на
  каждом уровне (или растёт через grow на каждом уровне), перемеряется под `.exact` на
  каждом уровне — известное поведение двухпроходного измерения; при глубине > ~100 таких
  уровней подряд время растёт быстро (наблюдение: depth 300 с overflow не завершался).
  Направление: basis по max-content с ключом только по cross-оси — меняет семантику
  basis (CSS vs fit-content), отдельное решение этапа 2. Записано как **#24, открыт**.
  *Дополнение 2026-09-11:* закрыто [ADR 0009](../adr/0009-flex-basis-is-max-content.md)
  после замеров числа состояний (fixture `overflow-chain`): depth 300 с overflow —
  4.7 ms, линейно; заодно исправлены найденные при этом #25, #26, #28 (геометрия) и #27.
- **Широкая линия:** 5000 items в одной линии — 121 ms (2 измерения на item и
  распределение); списки такого размера — предмет виртуализации, не движка.
- **Память:** 20 × mount/unmount 1000-нодного дерева удерживают +32 MiB resident при
  нуле живых объектов — allocator/CALayer-кэши; не течёт (повторные циклы не растут
  линейно — peak == resident-after).

## Предварительные бюджеты (этот Mac; на устройстве — переснять)

| Сцена | Обновление → commit p50 / p95 |
|---|---|
| 1000 нод, правка геометрии всех | 7.5 / 7.6 ms |
| 1000 нод, paint-only | 1.5 / 1.6 ms |
| 272 нод depth 30, локальная правка | 1.6 / 1.8 ms |
| реактивный burst 1000 → 1000 нод | 7.7 / 7.8 ms |
| два хоста по 501 | 3.6 / 3.7 ms |

## Проверки

`LoadAndTeardownTests` (3), `SchedulerStaleResultTests` (2, C31+), 305 тестов; `check_all.py`
PASS. API baseline по этой записке: `added` — `LayerRenderer.createdLayerTotal`,
`NodeHostBridge.createdLayerTotal`.
