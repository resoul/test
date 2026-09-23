# H02b — Point + snapshot → NodeID?

Дата: 2026-09-11. Карточка B-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D16, D17, D19, D32, D33 ([decisions.md](../decisions.md)). Контрактные случаи
1–5, 10–27 из [h01-contract.md](h01-contract.md) §1 (6–9 закрыты в H02a).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| `HitTestSnapshot.hitTest(_:) -> NodeID?` | `Sources/TrellisCore/HitTesting/HitTest.swift` | Чистая функция по снимку. Обход от корня к переднему потомку; точка протаскивается через transform каждого узла (`inverseApplying(_:in:)`, pivot — центр, ADR 0010), поэтому transform предка двигает поддерево. `opacity == 0` — поддерево исключено; `.hidden`/`.scroll` — клип по локальным bounds узла, дети `.visible` узла тестируются и вне его bounds; siblings — `zIndex` убыв., при равенстве обратный порядок `children`; обёртка — не результат; bounds half-open; root — fallback, если точка внутри него. |
| Точка входа bridge | `NodeHostBridge.hitTest(_:)` | `hitTestSnapshot?.hitTest(point)`; `nil` при `skipsLayoutOnlyWrappers == true` (D32, лог `hit-test-unsupported`), до первого commit и после `detach()`. Резолв `NodeID` в живую ноду — H03. |
| Отсечение поддеревьев | `HitTestSnapshot.Record.hittableBounds`, считается в `capture` снизу вверх | AABB в пространстве родителя вокруг всего, что поддерево может «поймать»: свой frame ∪ боксы детей (только если узел не клипует), затем bounding box этого прямоугольника после transform узла (4 угла через `applying(_:in:)`). Проверка — **closed** (`<=`), чтобы никогда не отсечь точку на краю округлённого бокса; решает всегда half-open тест точного frame. Исходный `LayoutPlacement.frame` родителя как граница для детей **не используется** (T03). |

## Замер (по D17 (6): сначала линейный обход, затем оптимизация)

Дерево 1111 нод (root → 10 рядов → 100 ячеек → 1000 листьев), 1000 hit-test'ов в разные
точки, `test_hitTest_thousandNodeTreeWalksInMicroseconds`, Apple Silicon, лог
`TRELLIS_LOG=snapshot`:

| Вариант | Debug | Release |
|---|---|---|
| Линейный обход без отсечения (каждый промах — обход всего поддерева) | 453 µs/hit | 59 µs/hit |
| С `hittableBounds` | 9.1 µs/hit | **1.4 µs/hit** |

59 µs на событие в release для touch допустимо, но `mouseMoved`/`Pan` дают сотни событий
в секунду, а обход всего дерева на каждый промах — плохой запах; бокс считается за один
проход в commit-точке, которая и так обходит дерево, поэтому оптимизация принята. Тест
держит щедрую границу 500 ms на 1000 вызовов (шум CI), фактические цифры — здесь.

## Тесты

`swift test --filter HitTest` — 20 тестов (7 из H02a + 13 новых), все зелёные.
Номера — случаи h01-contract §1:

| Тест | Случаи |
|---|---|
| `test_hitTest_ordinaryNodeRootFallbackAndOutsideRoot` | 1, 2, 3 (`−1`, `400` — вне; `0` — внутри) |
| `test_hitTest_arrangementWrapperIsTransparent` | 4, 5 |
| `test_hitTest_equalZIndexLastSiblingWinsAndZIndexOrdersSiblingsOnly` | 10, 11, 12 |
| `test_hitTest_halfOpenBoundsSharedEdgeAndZeroSize` | 13, 14 |
| `test_hitTest_overflowVisibleKeepsChildOutsideParentHittableHiddenClips` | 15, 16, 17 (+ `.scroll` клипует) |
| `test_hitTest_opacityZeroHidesSubtreeAnyOtherOpacityDoesNot` | 18, 19 (+ root с `opacity 0` → `nil`) |
| `test_hitTest_rotatedNodeIsHitWhereDrawnNotByOriginalFrame` | 20, 21, 22 |
| `test_hitTest_parentTransformMovesChildrenAndComposes` | 23, 24 (+ композиция: `+π/2` родитель и `−π/2` ребёнок — образ ребёнка снова осевой, 50×20 вокруг `(240, 75)`) |
| `test_hitTest_transformedAncestorClipsInItsLocalSpace` | 25 (+ вершина ромба `(150, 82)` внутри) |
| `test_hitTest_coincidingParentAndChildFramesChildWins` | 26 |
| `test_hitTest_thousandNodeTreeWalksInMicroseconds` | замер выше |
| `test_hitTestSnapshot_hittableBoundsFollowTransformClipAndDescendants` | бокс: `.visible` расширяется ребёнком, `.hidden` — только свой frame, поворот 100×50 → 50×100 вокруг центра |
| `test_nodeHostBridge_hitTestUsesLastCommitAndRefusesFlattenedWrappers` | 6, 7, 27: точка входа bridge; `skipsLayoutOnlyWrappers` → `nil` |

`python3 Scripts/check_all.py` — зелёный; API baseline `TrellisCore`
(+`hitTest(_:)`, +`Record.hittableBounds`) и `TrellisRender` (+`NodeHostBridge.hitTest(_:)`)
обновлён этим документом как review note — только добавления.

## Изменение по ходу

Из `hitTest` убран guard на non-finite точку: `LayoutPoint` конечен по конструкции
(`Geometry.swift`, «replacing non-finite coordinates with zero»), проверка была мёртвой.
Отклонение non-finite ввода остаётся обязанностью адаптеров (D30, H07/H08).

## Не входит

Резолв `NodeID` → живая `Node` и проверка mount'а (H03); `skipsLayoutOnlyWrappers == true`
(записанное ограничение D32).
