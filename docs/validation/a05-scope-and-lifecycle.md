# A05 — Modal scope, восстановление и lifecycle

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решение D40 ([decisions.md](../decisions.md)); примеры —
[a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §5 7–11, 16–17.
Код — тот же `FocusEngine` A04 ([a04-focus-engine.md](a04-focus-engine.md)); здесь его
scope/lifecycle-часть и её тесты.

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Scope как ID (D40) | `FocusEngine.setScope(_:root:)`, `scopeID`, `restorationID` | Одна modal scope, без стека: неизвестный ID отклоняется, тот же ID — no-op, вложенный запрос заменяет текущий. Открытие запоминает `restorationID = focusedID` (только при открытии первой scope) и, если текущий focus вне scope, переводит его на initial candidate scope (`priority`, затем pre-order) с `reason: .scope`; пустая scope → `focusedID == nil`, `.next`/`.previous` → `.unchanged`, фон недоступен (`focus(background) == .unavailable`). Закрытие: `restorationID`, если он candidate и live, иначе текущий focus, если он candidate, иначе первый кандидат дерева. |
| Границы поиска | `isCandidate`, `focusCandidates(scope:)`, `sequentialNeighbour` | Кандидаты — только поддерево scope; `.next`/`.previous` внутри modal циклические, стрелки без wrap; explicit override на target вне scope игнорируется. |
| Исчезновение modal root | `apply(_:root:)` | Снимок без записи scope → scope закрывается, `restorationID` восстанавливается, если candidate; затем обычная перепроверка focused. |
| Suspend/resume (D40) | `suspend(root:)`, `resume(root:)` | Suspend: `restorationID = focusedID`, переход в `nil` с `focusOut(reason: .suspend)`, scope сохраняется; повторный suspend — no-op. Resume: восстановление, если live candidate; иначе следующий живой кандидат по прежнему порядку (`.invalidation`); повторный resume — no-op; никто не активируется. |
| Detach/replacement | `reset()`, `NodeHostBridge.detachCurrentRoot()` | Очищает focus, scope, restoration, snapshot, очередь deferred — без событий (дерево уходит, а не взаимодействует). Новый mount (другая `mountEpoch`) никогда не наследует состояние. Bridge: `focus`/`moveFocus` на suspended хосте — `.unavailable`. |
| Общая semantic boundary с accessibility | A06 | `AccessibilityTree.build(from:scope:)` строится от того же `scopeID` — реализуется в A06, здесь только engine-часть. |
| Pending press на suspend | A07 | Press-cycle появляется в A07; там же suspend/focusOut его отменяет. |

## Тесты

`swift test --filter a05_` — 13 тестов, все зелёные.

Core (`Tests/TrellisCoreTests/Focus/FocusScopeTests.swift`, фикстура `R > [A, modal > [X, Y]]`):

| Тест | Случаи |
|---|---|
| `a05_openingAScopeConfinesFocusAndWrapsSequentialMovesInsideIt` | §5 7: restoration = A, focus → X с `.scope`, `focus(A) == .unavailable`, wrap `.next`/`.previous`, стрелки без wrap и без выхода к A |
| `a05_overrideCannotLeaveTheScopeAndSameScopeTwiceIsNoOp` | override на фон игнорируется; §5 10; неизвестный scope отклонён |
| `a05_emptyScopeHoldsNoFocusAndNeverReleasesItToTheBackground` | §5 8; появившийся кандидат не крадёт focus, находится следующим `.next` |
| `a05_closingRestoresThePreviousFocusOrFallsBackToTheFirstCandidate` | §5 9: `.restoration`; restoration disabled → текущий остаётся; без обоих — первый кандидат `.scope` |
| `a05_removingTheModalRootOnCommitClosesTheScopeAndRestores` | §5 11 |
| `a05_currentFocusInsideTheScopeIsRevalidatedLikeAnywhereElse` | disable current → Y; remove current → nil при живой scope; reparent Y наружу → вне scope |
| `a05_suspendKeepsOnlyTheRestorationIdentityAndResumeRestoresIt` | §5 16: `focusOut:suspend`, scope сохранена, идемпотентность, `focusIn:restoration` |
| `a05_detachClearsEverythingWithoutEventsAndOldRootRemountedIsFresh` | §5 17: reset без событий; тот же root под новой epoch — с нуля |
| `a05_twoEnginesWithTheSameGenerationDoNotInterfere` | два хоста, одинаковая generation — ID чужого дерева `.unavailable`, scope не пересекаются |

Render (`Tests/TrellisRenderTests/FocusBridgeTests.swift`):

| Тест | Случаи |
|---|---|
| `a05_suspendClearsFocusKeepsRestorationAndResumeRestoresIt` | bridge.suspend/resume через engine; ввод на suspended хосте отклонён |
| `a05_resumeDoesNotRestoreACardThatWentAwayWhileSuspended` | disabled во время suspend → fallback `.invalidation` |
| `a05_replacingTheRootClearsFocusAndScope` | `attach(other)` очищает focus и scope |
| `a05_detachReleasesRootAndBridgeWithFocusAndScopeSet` | weak release root/bridge/control после detach при установленных focus, scope и `onFocusChange`; registry sizes — engine хранит только ID, snapshot `nil` |

## Не закрыто здесь

Semantic boundary accessibility (A06); отмена press-cycle на suspend (A07).
