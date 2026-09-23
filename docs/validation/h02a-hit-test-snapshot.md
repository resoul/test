# H02a — Committed hit-test snapshot

Дата: 2026-09-11. Карточка B-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D19, D21, D25 ([decisions.md](../decisions.md)). Контрактные случаи 6–9 из
[h01-contract.md](h01-contract.md) §1.

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Тип `HitTestSnapshot` (`TrellisCore`) | `Sources/TrellisCore/HitTesting/HitTestSnapshot.swift` | `Sendable` value: `root`, `mountEpoch`, `bounds` (host bounds коммита), приватный индекс `NodeID → Record`. `Record`: `id`, `parent`, `children` в порядке `subnodes` (paint order при равном `zIndex`, D32), committed `frame`, committed `LayoutVisualProperties`, `isArrangementWrapper` (D19). Только Foundation. Новый код, не перенос из Weave — в `source-provenance.md` не входит. |
| Формирование в commit-точке | `NodeHostBridge.attach`, closure `onCommitGeometry` | Сразу после `renderer.applyCommitted(...)`, в том же синхронном MainActor-вызове, из тех же `calculatedFrame`/`subnodes`/`style.visual` — между ними ничего не исполняется, поэтому слои и снимок совпадают. `HitTestSnapshot(root:mountEpoch:bounds:)` — `@MainActor` failable init: `nil`, если у корня нет frame (как `applyCommitted` — `missing-frame`). |
| Хранение и сброс | `NodeHostBridge.hitTestSnapshot` (`public private(set)`) | `nil` до первого commit, `nil` после `detach()`/замены корня (`detachCurrentRoot`). |
| Mount epoch | `NodeHostBridge.mountEpoch` (`public private(set)`) | Инкремент на каждый `attach`; снимок несёт epoch своего mount'а. Основа проверки валидности сессии (D21, H04). |
| Нода без frame | `capture` | Пропускается с поддеревом, родитель её не перечисляет — зеркало `LayerRenderer.update` (`missing-frame`). В production недостижимо в commit-точке (`applyLayoutResult` отклоняет неполный результат — `incomplete-or-malformed-result`), достижимо только при построении вне commit; тест есть. |

## Тесты

`swift test --filter HitTestSnapshot` — 7 тестов, все зелёные:

| Тест | Контракт |
|---|---|
| `test_hitTestSnapshot_capturesTreeFramesVisualAndPaintOrder` | записи, parent/children в порядке `subnodes`, committed frame и `visual`, `bounds`, `mountEpoch` |
| `test_hitTestSnapshot_marksArrangementWrappersAndSkipsUncommittedSubtrees` | флаг обёртки; нода без frame и её поддерево не в снимке |
| `test_hitTestSnapshot_isNilWithoutCommittedRoot` | корень без frame → `nil` |
| `test_hitTestSnapshot_doesNotFollowLiveMutations` | после `style.visual`, `removeFromSupernode`, `dispose` снимок не меняется |
| `test_nodeHostBridge_buildsHitTestSnapshotOnlyAtCommit` | h01 §1 №6: после `attach`, до commit — `nil`; после commit — frames как у `calculatedFrame`, epoch 1 |
| `test_nodeHostBridge_hitTestSnapshotIgnoresLiveMutationsUntilNextCommit` | h01 §1 №8–9 (T01): `style.width`, `style.visual`, удаление sibling, добавление ноды — снимок прежний; после следующего commit — новый frame/visual/children |
| `test_nodeHostBridge_detachClearsHitTestSnapshotAndReattachBumpsMountEpoch` | h01 §1 №7: `detach()` → `nil`; повторный `attach` того же корня → `nil` до commit, epoch 2 |

`python3 Scripts/check_all.py` — зелёный; API baseline `TrellisCore` (+`HitTestSnapshot`,
`Record`) и `TrellisRender` (+`mountEpoch`, `hitTestSnapshot`) обновлён этим документом как
review note (только добавления, без изменённых/удалённых символов).

## Решение, оставшееся с H01 (контракт §1 №27)

`skipsLayoutOnlyWrappers == true`: снимок **строится всегда** — это committed-дерево, и
flattening слоя не меняет ни frames, ни `subnodes`; расходится только сравнение
`zPosition` детей обёртки с её siblings. Отказ (`nil`) при включённом режиме — в точке
входа `hitTest(_:)` H02b, не в снимке: так снимок остаётся честным описанием commit'а, а
ограничение D32 живёт там, где применяется.

## Не входит

Чистая функция `point + snapshot → NodeID?` — H02b. Снимок пока никем не читается, кроме
тестов.
