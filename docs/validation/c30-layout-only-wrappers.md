# C30 — Эксперимент: служебные контейнеры без CALayer

Дата: 2026-09-11. Результат — **решение**, не обещанная экономия (приёмка карточки).

## Что сделано

`LayerRenderer.skipsLayoutOnlyWrappers` (и форвард `NodeHostBridge.skipsLayoutOnlyWrappers`),
по умолчанию `false`. При `true` implicit wrapper Arrangement (`isArrangementWrapper`) без
paint (`appearance == VisualStyle()`) и без групповых эффектов
(`style.visual == LayoutVisualProperties()`: overflow visible, opacity 1, identity transform,
zIndex 0) не получает `CALayer`; его дети паркуются к ближайшему предку со слоем.

- **Координаты.** Frames root-absolute, локальная позиция = `frame.origin − origin` рисующего
  предка — та же формула, что для обычного ребёнка, просто `parentFrame` передаётся сквозь
  wrapper. Геометрия идентична с точностью до равенства `LayoutFrame` (тест).
- **Порядок слоёв.** `orderOwnedChildren` строит желаемый порядок обходом в pre-order,
  спускаясь сквозь layer-less wrapper'ы: внуки занимают место своего wrapper'а.
- **Reparent.** Переключение флага действует на следующем commit: слой wrapper'а уходит как
  stale, дети переезжают к предку (identity их слоёв сохраняется); обратно — wrapper
  материализуется и забирает детей. Тест `togglingReparentsAtNextCommit…`.
- **DebugOverlay** читает `calculatedFrame`, а не слои: логические контейнеры видны и без
  слоя (тест: 7 рамок при 5 слоях).
- **Эффекты не пропускаются молча.** Clipping (`overflow: .hidden`), opacity, transform,
  zIndex или любой paint на wrapper'е → wrapper получает слой, даже с включённым флагом
  (тест `groupEffectsKeepALayer`). Правило — равенство с default-значениями, без списка
  исключений, который можно забыть дополнить.

## Замеры (Release, log off, 300 карточек × (1 owner + 3 wrapper + 4 листа) = 2401 нод)

Bench-fixture `wrappers-with-layers` / `wrappers-without-layers`
([measurements/2026-09-11-macos-arm64-c26-release.md](measurements/2026-09-11-macos-arm64-c26-release.md) (прогон C26 включает оба fixture));
память — отдельные процессы (`TRELLIS_BENCH_WRAPPERS=with|without`).

| Метрика | со слоями | без слоёв | Δ |
|---|---|---|---|
| CALayer | 2401 | 1501 | −900 (−37 %) |
| resident после mount, MiB | +13.8 | +12.0 | −1.8 MiB ≈ 2 KB/слой |
| `LayerRenderer.applyCommitted` (только рендерер), p50 | 3.9 ms | 2.8–3.0 ms | −25 % |
| правка геометрии всех карточек → commit, p50 | 13.6–14.9 ms | 12.5–13.5 ms | −7…−9 % |
| attach → первый commit | 20–38 ms | 19–20 ms | создание слоёв |

Allocations не измерялись (см. C31).

## Решение (D15)

**Базовая модель этапа 1 остаётся: слой на каждую ноду.** Флаг сохраняется как публичный,
выключенный по умолчанию эксперимент, чтобы C26 мог включить его в замеры на устройстве.

Почему не включать по умолчанию сейчас:
1. Выигрыш на полном пути обновления — 7–9 % и ~2 KB на wrapper. Рендерер — меньшая доля
   конвейера (3–4 ms из 13); snapshot/solve/apply весят больше, и там резервы C31 уже
   сработали (#13, #14).
2. Дерево слоёв перестаёт совпадать с деревом нод. Этап 2 приносит hit-testing, анимации
   и групповые эффекты на контейнерах — каждое из них либо материализует wrapper обратно
   (reparent на лету), либо требует учитывать «прозрачные» уровни. Решать это лучше с
   реальным контентом (Text), а не заранее.
3. Никакого дефекта базовой модели замеры не показали: 2401 слой коммитится за 4 ms.

Когда пересмотреть: если C26 на физическом устройстве покажет, что число слоёв — узкое
место (например, iOS с тысячами нод в списке), или когда wrapper'ов станет кратно больше
листьев. Тогда включение — одно присваивание, тесты и overlay уже готовы.

## Проверки

Тесты `LayoutOnlyWrapperTests` (3): равная геометрия, координаты относительно рисующего
предка, порядок, reparent при переключении, overlay, эффекты. `swift test` — 302;
`check_all.py` — PASS. API baseline по этой записке: `added` —
`LayerRenderer.skipsLayoutOnlyWrappers`, `NodeHostBridge.skipsLayoutOnlyWrappers`.
