# H01 — Контракт hit-testing и событий: примеры с ожидаемым результатом

Дата: 2026-09-11. Карточка A-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5. Решения D16–D34 согласованы и перенесены в [decisions.md](../decisions.md);
дефект #30 закрыт [ADR 0010](../adr/0010-transform-pivot-is-frame-center.md).
Кода hit-testing здесь нет — таблицы ниже становятся тестами H02–H06 один в один.

Обозначения: `R` — root, frame `(0, 0, 400, 400)`; `frame (x, y, w, h)` — committed
absolute frame; точка `p` — host point в points, origin сверху слева. `hit(p)` —
результат `HitTestSnapshot` → `NodeID?`.

## 1. Hit-test по снимку (D17, D19, D25, D32, D33)

| # | Дерево и состояние | `p` | `hit(p)` | Почему |
|---|---|---|---|---|
| 1 | `R > A (10, 10, 100, 100)` | `(50, 50)` | `A` | обычная нода |
| 2 | то же | `(200, 200)` | `R` | ни один ребёнок не хит, root — хит по умолчанию (`opacity > 0`) |
| 3 | то же | `(−1, 50)`, `(400, 50)` | `nil` | вне root: half-open — `400` исключён (D33) |
| 4 | `R > A (10, 10, 100, 100)`, `A` — `isArrangementWrapper`, без детей | `(50, 50)` | `R` | обёртка никогда не target (D19) |
| 5 | `R > W (wrapper, 0, 0, 400, 400) > A (10, 10, 100, 100)` | `(50, 50)` / `(300, 300)` | `A` / `R` | обёртка прозрачна; мимо её детей — к владельцу |
| 6 | до первого commit | любая | `nil` | снимка нет (D25) |
| 7 | после `detach()` | любая | `nil` | снимок сброшен |
| 8 | commit с `A (10, 10, 100, 100)`; затем live: `A.style.width = 300` без нового commit | `(200, 50)` | `R` | снимок не изменился — на экране старый `A` (T01) |
| 9 | продолжение 8, после следующего commit с `A (10, 10, 300, 100)` | `(200, 50)` | `A` | снимок обновился в commit-точке |
| 10 | `R > A (0, 0, 100, 100), B (0, 0, 100, 100)`, оба `zIndex 0` | `(50, 50)` | `B` | equal-z — последний в `subnodes` спереди (D32, G08) |
| 11 | то же, `A.zIndex = 1` | `(50, 50)` | `A` | zIndex убыв. раньше порядка |
| 12 | `R > A (0, 0, 200, 200) > A1 (0, 0, 100, 100, zIndex 100)`, `R > B (0, 0, 100, 100)` | `(50, 50)` | `B` | `A1.zIndex` сравнивается только с siblings внутри `A`; `B` рисуется после `A` (stacking context, D32) |
| 13 | `R > A (0, 0, 100, 100), B (100, 0, 100, 100)` | `(100, 50)` | `B` | общая граница: `A.max` исключён, `B.min` включён (D33) |
| 14 | `R > A (10, 10, 0, 0)` | `(10, 10)` | `R` | zero-sized frame не хит (D33) |
| 15 | `R > P (0, 0, 100, 100, overflow .visible) > C (150, 150, 50, 50)` | `(160, 160)` | `C` | child вне parent при `.visible` виден и hittable (T03) |
| 16 | то же, `P.overflow = .hidden` | `(160, 160)` | `R` | клип предка исключает `C` |
| 17 | `R > P (0, 0, 100, 100, overflow .hidden) > C (50, 50, 100, 100)` | `(75, 75)` / `(125, 125)` | `C` / `R` | клип по локальным bounds `P` |
| 18 | `R > P (0, 0, 200, 200, opacity 0) > C (10, 10, 50, 50)` | `(20, 20)` | `R` | `opacity == 0` предка исключает поддерево (D17/T04) |
| 19 | то же, `P.opacity = 0.01` | `(20, 20)` | `C` | `0 < opacity ≤ 1` не отключает |
| 20 | `R > A (110, 120, 100, 50, rotation π/2)` — центр `(160, 145)`, образ занимает x∈[135,185], y∈[95,195] | `(184, 96)` | `A` | локальная точка `(111, 121)` внутри frame; по y точка **вне** исходного AABB `[120, 170)` — отказ по исходному frame дал бы `R` (ADR 0010, D17) |
| 21 | `R > A (100, 100, 100, 50, rotation π/2)` | `(150, 125)` центр / `(175, 80)` | `A` / `A` | центр неподвижен; `(175, 80)` — внутри повёрнутого прямоугольника (x∈[125,175], y∈[75,175]), но **вне** исходного AABB по y |
| 22 | то же | `(105, 105)` | `R` | внутри исходного AABB, но вне повёрнутого образа |
| 23 | `R > P (100, 100, 200, 100, translation (50, 0)) > C (100, 100, 50, 50)` | `(175, 125)` / `(125, 125)` | `C` / `R` | transform родителя двигает и детей; исходное место `C` пусто |
| 24 | `R > P (100, 100, 200, 100, rotation π/2) > C (100, 100, 50, 50)` | образ центра `C` `(125, 125)` под поворотом вокруг `(200, 150)` = `(225, 75)` | `C` | композиция transform по цепочке |
| 25 | `R > P (100, 100, 100, 100, overflow .hidden, rotation π/4) > C (0, 0, 400, 400)` | `(150, 150)` / `(100, 100)` | `C` / `R` | клип предка проверяется в локальном пространстве `P`: угол `(100,100)` после поворота лежит вне ромба |
| 26 | `R > A (10, 10, 100, 100) > A1 (10, 10, 100, 100)` (frame совпадают) | `(50, 50)` | `A1` | ребёнок выигрывает (аналог теста overlay о совпадающих frame) |
| 27 | `skipsLayoutOnlyWrappers == true` | — | не поддерживается | записанное ограничение (D32); bridge отвечает `nil`/assert в debug — выбрать в H02a |

## 2. Dispatch (D20, D28)

Маршрут `[R, A, A1]`, target `A1`.

| # | Ситуация | Ожидание |
|---|---|---|
| 1 | обычное событие | capture: `R, A, A1`; target: `A1`; bubble: `A, R` — ровно в этом порядке |
| 2 | `stopPropagation()` в capture на `A` | `A1` не получает ни capture, ни target; bubble не идёт |
| 3 | `stopPropagation()` в target | bubble не идёт; capture уже прошёл целиком |
| 4 | `stopPropagation()` в bubble на `A` | `R` bubble не получает |
| 5 | `preventDefault()` в любой фазе | все фазы идут до конца; recognizers события не получают (D29) |
| 6 | callback `A` (capture) делает `A1.dispose()` | target-фаза не выполняется; bubble — `A, R` не выполняется для пользовательской доставки; сессия отменена (D21) |
| 7 | callback `A1` (target) делает `A.removeFromSupernode()` | bubble на `A` пропускается (маршрут нарушен), `R` тоже — сессия отменена |
| 8 | callback `A1` (target) делает `A1.removeFromSupernode(); B.addSubnode(A1)` (reparent) | bubble по старому маршруту не идёт; сессия отменена |
| 9 | вложенный dispatch из callback | получает собственный маршрут; внешний продолжает по своему |
| 10 | target ID нет в live mounted tree | ни один callback не вызван; результат — «не доставлено» |

## 3. Pointer session (D21, D27, D30, D34)

| # | Ситуация | Ожидание |
|---|---|---|
| 1 | down на `A`, move на соседний `B`, up на `B` | все три события идут по маршруту `A` (implicit capture); `B` ничего не получает |
| 2 | down, resize хоста, up | сессия жива; Tap завершён (resize не отменяет) |
| 3 | down на `A`, `C.style.width` меняется (sibling `A`), новый commit, up | сессия жива (unrelated mutation) |
| 4 | down на `A`, `A.dispose()`, up | сессия отменена на dispose; up не доставляется; activation нет; control получил внутренний cancel |
| 5 | down, `bridge.detach()` | cancelAll; никаких callback после |
| 6 | down, `suspend()` | cancelAll; после `resume()` новая сессия работает |
| 7 | down (pointer 1), up, down (pointer 1) | второй раз — новая сессия, старая полностью освобождена |
| 8 | down (pointer 1), down (pointer 2) | pointer 2 получает cancel, сессии не создаёт (single-touch) |
| 9 | down на control `(10, 10, 100, 40)`, commit сдвигает control на `(10, 200, 100, 40)`, up в `(50, 20)` | маршрут — тот же control; up-inside — по **новому** снимку: `(50, 20)` вне → cancelled, activation нет (D34) |
| 10 | то же, up в `(50, 220)` | up-inside по новому снимку → activation |
| 11 | `PointerData` с `NaN` | отклоняется адаптером/bridge; сессия не создаётся |

## 4. Арбитр, Tap, Pan (D29, D31)

Пороги: tap slop 10 pt, pan threshold 10 pt.

| # | Ситуация | Ожидание |
|---|---|---|
| 1 | down, up без движения | Tap `.ended`, Pan `reset()` |
| 2 | down, move 9 pt, up | Tap `.ended` (внутри slop) |
| 3 | down, move ровно 10 pt, up | Tap `.ended`; Pan не начат (threshold — строго больше) |
| 4 | down, move 11 pt | Pan `.began`, Tap `reset()` — ровно один раз |
| 5 | down, move 11, move 20, up | Pan `.changed` (translation 20, delta 9), `.ended` |
| 6 | два Tap-recognizer на `A1` и `A` | побеждает `A1` (target раньше предков); `A` — `reset()` |
| 7 | два recognizer на одной ноде, оба eligible на одном событии | более ранний по регистрации |
| 8 | Tap `.possible → .ended` за один up | сессия закрыта; winner не остаётся в arena (G06) |
| 9 | pointerCancel во время Pan | Pan `.cancelled` один раз; arena пуста |
| 10 | две сессии (после single-touch — последовательные) | winners не смешиваются |
| 11 | `preventDefault()` на down | ни один recognizer не получает событие; activation нет |

## 5. Control (D22)

| # | Ситуация | Ожидание |
|---|---|---|
| 1 | down внутри | `isPressed == true`, invalidation |
| 2 | move наружу | `isPressed == false`; move обратно внутрь — `true` |
| 3 | up внутри | activation ровно один раз, `isPressed == false` |
| 4 | up снаружи | activation нет |
| 5 | cancel / detach / dispose / arbitration loss (Pan победил) | activation нет, `isPressed == false` |
| 6 | activation closure делает `control.dispose()` или `bridge.detach()` | без повторной доставки, без crash |
| 7 | control с декоративным ребёнком; down и up над ребёнком | hit → ребёнок, маршрут содержит control; activation control |

## Явно вне рамок этапа

focus engine и accessibility; scroll (D18); текстовый ввод; мультитач (D30);
общий hit-test behavior/opt-out (D26); `skipsLayoutOnlyWrappers == true` (D32);
explicit capture вне маршрута (D27); автоматизированная симуляция реального тапа
(H11). Карточки H02+ не расширяются в эти области.

## Приёмка H01

- Каждый случай выше имеет один ожидаемый результат — таблицы без «зависит».
- #30 — исправлен: ADR 0010, `python3 Scripts/check_all.py` зелёный, baseline
  обновлён с review note (`+3` символа, `1` изменённая декларация в
  `TrellisCore`).
- D16–D34 — в `decisions.md`, статус «принято (H01)», записанные ограничения
  названы записанными.
