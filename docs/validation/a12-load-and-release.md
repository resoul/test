# A12 — Нагрузка и освобождение ресурсов

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5.
Численные значения — evidence, не gate: точные счётчики утверждают тесты, время —
`Scripts/bench.py` в release с `TRELLIS_LOG=off`
([measurements/2026-09-12-macos-arm64-a12-semantics-release-release.md](measurements/2026-09-12-macos-arm64-a12-semantics-release-release.md)).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Bench fixture `semantics-1000` | `Bench/Sources/TrellisBench/main.swift` (`fixtureSemantics`) | 1000 `ControlNode` с labels + modal из двух кнопок: attach → первый publish, label burst ×1000 → один metadata-only publish, 1000 Tab, пары стрелок, geometry commit при установленном focus, modal open/close; счётчики публикаций/запросов, размер снимка/дерева, RSS до/после. `TRELLIS_BENCH_ONLY=semantics-1000`. |
| Кэш кандидатов focus | `FocusEngine.candidates()`/`candidatePosition(of:)` | Список кандидатов и позиции считаются один раз на `(mountEpoch, revision, scope)`, а не на каждый move: Tab по 1000 controls стал 227 → 149 ms (последовательный сосед O(1)). Оставшаяся стоимость — резолв committed маршрута в live дерево перед focusOut/focusIn (`EventDispatcher.resolve`, линейный поиск среди siblings, H03): 0.15 ms на переход при 1000 siblings. |
| Счётчики native proxies | `TrellisHostView.createdNativeProxyTotal` (UIKit), `createdNativeAccessibilityElementTotal` (AppKit) | Как `createdLayerTotal` C26: с текущим количеством говорит, сколько publish'ей переиспользовали proxies. |

## Замер (macOS 26.4.1, Apple Silicon, release, TRELLIS_LOG=off, 20 итераций)

| Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|
| attach → первый publish (1004 записи, 1002 leaves) | 16.1 | — | — |
| label burst ×1000 → metadata-only publish | 2.2 | 2.6 | 3.0 |
| 1000 Tab-переходов (с focusOut/focusIn событиями) | 149.5 | — | — |
| пара стрелок ↓↑ (directional score по 1000) | 1.8 | 1.9 | 1.9 |
| geometry commit всех 1000 + republish + engine revalidate | 9.2 | 9.4 | 9.4 |
| modal open + close (два rebuild дерева, restoration) | 1.5 | 1.7 | 1.7 |

Счётчики: `metadata-only-publishes=20` на 20 bursts, `requested-after-bursts=1` (solver не
запускался), `committed=21`, `semantic-publishes=41`. RSS: 12.8 → 20.8 MiB mounted → 20.8
detached (аллокатор не отдаёт; live-объекты проверяются weak-ссылками в тестах). Сравнение
с A02: 1000 proxies ~1 ms создание — здесь proxies не создаются повторно (см. тесты).

Бюджеты по A02/этому замеру: publish 1000 элементов ≤ 20 ms; metadata burst ≤ 5 ms; один
Tab ≤ 0.5 ms; directional move ≤ 1 ms; proxies == число элементов снимка.

## Тесты

macOS `swift test --filter a12_` — 4 (`Tests/TrellisRenderTests/SemanticLoadAndReleaseTests.swift`);
iOS/tvOS Simulator — +1 (`UIKitKeyboardAndFocusProxyTests.swift`), 105/104 в `TrellisRenderTests`.

| Тест | Приёмка |
|---|---|
| `a12_thousandElementsPublishOnceAndBurstsNeverSolve` | 1004 записи/1002 кандидата и leaves; burst value ×1000 — один metadata-only publish, `requested` не растёт; 1000 Tab — ровно по кандидатам, без layout; modal open/close ×100 — дерево 2 ↔ 1002, focus восстановлен, snapshot не переопубликован; geometry burst — ровно один запрос |
| `a12_detachReleasesBridgeRootControlsAndEngineStateWithNoLateCallbacks` | detach при focus + scope + открытом press-cycle → nil focus/scope/snapshot/tree, 0 сессий; мутации после detach не доходят до callbacks; weak release bridge/root/control |
| `a12_repeatedAttachDetachDoesNotAccumulateAndDeepTreesBuildIteratively` | 20 циклов attach/focus/move/detach — epoch 20, ничего не накапливается; цепочка глубиной 1500 — `SemanticSnapshot` и `AccessibilityTree` строятся на 512 KiB стеке теста (итеративно), 30 групп + leaf |
| `a12_appKitElementsAreBoundedByTheTreeNotByCommitsAndReleaseOnDetach` (macOS) | 302 элемента; 20 geometry commits + 20 value bursts — `created` не растёт; удаление/возврат ноды — −1/+1 элемент, +1 created; detach → 0, weak element освобождён |
| `a12_proxyCountFollowsTheSnapshotAndDetachDuringAPendingNativeRequestIsClean` (iOS/tvOS) | 3 proxies через 20 commits/bursts, `createdNativeProxyTotal` не растёт; detach при pending native request — pending nil, 0 proxies, `preferredFocusEnvironments` пуст, proxy освобождён |

## Не закрыто

Замер на устройствах (Apple TV, iPhone) — нет доступа; release-замер только macOS.
Линейный резолв маршрута среди siblings (H03) — кандидат на индекс детей, если Tab по
очень широким деревьям окажется узким местом на устройстве.
