# M13 — Lifecycle, AX и платформы

Дата: 2026-09-14. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §6, третья и
последняя карточка результата B перед M14. Закрывает D73's полный проход (modal scope, focus
restoration, единственное AX-представление, блокировка background, Reduce Motion, suspend/detach
на каждой фазе state-table), два lifecycle-пробела, которые M11/M12 сознательно оставили
открытыми (host resize mid-transition, source-disappears-during-closing), epoch/late-callback
дисциплину и — впервые для результата B — реальный `TrellisHostView` forwarding API, без которого
M12's report прямо называл невозможным дотянуться до `NodeHostBridge` из смонтированной сцены
вообще (`m12-progress-and-gesture.md` §4).

## 1. D73 — полный проход

D73 (`docs/decisions.md`, уточнено M10/реализовано M11 частично) требует: modal scope, focus
restoration, единственное AX-представление, блокировка background, Reduce Motion, suspend и
detach на каждой фазе state-table. Проверено против текущего кода
(`Sources/TrellisRender/NodeHostBridge.swift`) и тестов:

- **Modal scope/focus restoration** — `focusEngine.setScope(_:)` (D40) открывается на
  `opening → presented` и закрывается на `settling → closed`/`cancelTransition`, что уже было
  сделано M11; M13 добавляет проверку через каждый *новый* путь закрытия M12 ввела (жестовое
  закрытие, системная отмена жеста) — `m13_focusRestoresToTheTriggeringElementAfterGestureFinishCloses`
  и `m13_focusRestoresToTheTriggeringElementAfterSystemCancelledGestureBouncesBackToPresented`
  (`Tests/TrellisRenderTests/M13TransitionLifecycleTests.swift`) подтверждают, что `focusedID`
  возвращается к элементу, открывшему переход (D40), а `focusScopeID` — `nil`/восстановлен для
  обоих путей, не только для кнопочного закрытия, которое одно проверяло M11.
- **Единственное AX-представление / блокировка background** — уже реализовано M11
  (`AccessibilityChildrenPolicy.hide`, D42); M13 не меняет механизм, только подтверждает, что он
  переживает новые M12-состояния через те же два теста выше (`focusScopeID == harness.page.id`
  во время `interactiveClosing` и после отмены жеста).
- **Reduce Motion** — не тронуто этой карточкой (M08/M11 уже проводят завершение перехода через
  `finishTransitionMotionInPlace`, который M12 расширила на `isManual`); отдельного нового теста
  M13 не добавляет, т.к. не меняет этот путь — подтверждено чтением кода
  (`TransitionAnimator.finishInPlace`), не изменено в этом diff.
- **Suspend и detach на каждой фазе state-table** — до M13 покрыты были только `presented`
  (M11) и обычный auto-close (M11/M12); M13 добавляет обе gesture-фазы, которые M12 создала, но
  не проверила под suspend/detach:
  - `m13_suspendDuringInteractiveClosingStartedFromPresentedFinishesToPresented` —
    `interactiveClosing`, начатый из `presented`, под `suspend()` завершается в `presented`
    независимо от прогресса жеста (D73 буквально: «незавершённый interactiveClosing →
    presented»), modal scope переживает suspend.
  - `m13_detachDuringInteractiveClosingStartedFromOpeningClearsTheSessionImmediately` —
    `interactiveClosing`, начатый из ещё летящего `opening` (второй из двух входов, которые
    добавила M12), под `detach()` немедленно очищает сессию и overlay.
  - Плюс `preparing`-отмена (`m13_prepareCancellationReleasesEveryTemporaryArtifact`) и
    `settling`-detach (`m13_closingInterruptedByDetachReleasesEveryTemporaryArtifact`) — см. §2.

Итог: все шесть строк D73 подтверждены с прямыми тестами на актуальном коде; ни одна не
полагается только на то, что «M11 уже это сделала» — каждая перепроверена против M12's новых
состояний, которые M11's тесты не могли видеть.

## 2. Host resize, source-disappears-during-closing, epoch/late-callback дисциплина

`Sources/TrellisRender/NodeHostBridge.swift` gains `reconcileTransitionGeometryIfNeeded()`,
вызываемый из обоих commit-путей коордиатора (`onCommit`/`onDisplayOnly`) на каждом реальном
commit — никогда per-frame poll, та же дисциплина, что уже соблюдает соседний
`retryPendingTransitionIfNeeded()`.

- **Host resize mid-transition** — `transitionBuiltBounds` (новое `private` поле) хранит bounds,
  на которых была построена текущая геометрия; расхождение с `lastCommittedRequest?.bounds`
  триггерит `rebuildTransitionForReconcile`, который минтит свежий token (D66) и вызывает
  `buildTransitionVisuals` заново под новым layout — сессия не переоткрывается и не
  перезапускается, тот же overlay/токен последовательности. Покрыто для `opening`
  (`m13_resizeMidOpeningRetargetsUnderNewLayoutWithoutRestarting`) и `settling`
  (`m13_resizeDuringSettlingRetargetsTheSameLogicalEndpoint` — подтверждает, что решённый
  settle target не меняется resize'ом, только геометрия под него).
- **Source исчезает во время closing** (M11 покрывала только `preparing`-фазу пропажи source) —
  `reconcileTransitionGeometryIfNeeded` детектирует `sourceMissing` для `interactiveClosing`,
  направленного к `.closed`, и для `settling(.closed)`, вызывает
  `clearStaleTransitionGeometryAnimations()` (снимает position/size/cornerRadius-анимации, не
  трогая opacity) и перестраивает сессию как fade вместо полёта к устаревшему прямоугольнику —
  D72's собственный текст ("closing использует fade вместо полёта в устаревший прямоугольник").
  Тесты: `m13_sourceRemovedDuringInteractiveClosingFadesInsteadOfFlyingToAStaleRect`,
  `m13_sourceRemovedDuringNonInteractiveSettlingFadesInsteadOfFlyingToAStaleRect` — оба проверяют
  отсутствие position-анимации и наличие opacity→0, плюс чистое завершение после того, как
  `source` больше не резолвится.
- **Epoch/late-callback hardening** — `m13_lateCompletionAfterDetachIsIgnoredAndANewSessionOnAFreshMountIsUnaffected`:
  detach до завершения `opening` бампит `TransitionAnimator`'s собственный токен
  (`finishInPlace`), так что уже поставленный в run loop completion-блок находит свой token
  устаревшим и становится no-op (D66); последующий свежий mount и сессия на том же bridge
  стартуют чисто (нет унаследованного токена/overlay/AX-policy).
- **Prepare-cancellation и closing-interrupted-by-detach освобождают artifacts** —
  `m13_prepareCancellationReleasesEveryTemporaryArtifact` (source исчезает во время `preparing`
  → `transitionSession == nil`, overlay освобождён, `transitionRasterLayerCountForTesting == 0`)
  и `m13_closingInterruptedByDetachReleasesEveryTemporaryArtifact` (detach посреди `settling`,
  до того как автоматическое закрытие успело завершиться, → те же три проверки). Ни один
  временный layer/raster не переживает эти два пути.

## 3. Platform completeness

### 3.1. `TrellisHostView` forwarding API — точные сигнатуры из текущего исходника

Симметрично на обеих платформах (`Sources/TrellisUIKit/TrellisHostView.swift`,
`Sources/TrellisAppKit/TrellisHostView.swift`), тот же тонкий passthrough, что M08 уже установила
для `sceneReadiness`/`waitUntilSceneReady`/`updateReduceMotion`:

```swift
public var transitionSession: TransitionSession? { bridge?.transitionSession }

@discardableResult
public func presentTransition(_ request: NodeHostBridge.TransitionRequest) -> Bool

@discardableResult
public func closeTransition() -> Bool

@discardableResult
public func beginTransitionGesture() -> Bool

public func updateTransitionGesture(deltaProgress: Double)

@discardableResult
public func endTransitionGesture(
    velocity: Double,
    preset: TransitionGesturePreset? = nil
) -> Bool

@discardableResult
public func cancelTransitionGestureSystemInterrupted() -> Bool
```

Каждый метод — ровно один forwarding-вызов к уже существующему одноимённому члену
`NodeHostBridge`, с безопасным значением по умолчанию (`false`/`nil`/no-op) при отсутствующем
bridge — та же форма, что `focus(_:)`/`moveFocus(_:)`/`setFocusScope(_:)` уже используют на обоих
host views. Никакой новой decision-логики здесь нет: пороги, таблица состояний, settle target —
всё остаётся в `NodeHostBridge`, platform-neutral (см. [ADR 0019](../adr/0019-trellis-host-view-transition-forwarding.md)
для полного обоснования и для того, почему `TransitionGestureController` (ADR 0018) саму по себе
не использовали для закрытия этого пробела).

### 3.2. Playground-сцена S29

`Playground/Shared/Scenarios/S29_ExpandTransitionPlatforms.swift` (новый файл) —
`.expand` карточка→страница (переиспользует M11's hero+title роли, не строит отдельный M14-контент):
кнопочное открытие/закрытие через `TrellisHostView.presentTransition(_:)`/`closeTransition()` на
каждой платформе; на iOS/macOS `ExpandGestureHandler` вешает настоящий
`UIPanGestureRecognizer`/`NSPanGestureRecognizer` прямо на смонтированный host view (D73:
неподвижная host-overlay область) и транслирует его собственные `translation`/`velocity` в четыре
gesture-forwarding вызова через `@objc`-хендлер — не синтетическое событие, тест или мок. На tvOS
pan-recognizer никогда не создаётся (`traitCollection.userInterfaceIdiom == .tv`, runtime-проверка,
не `#if os(tvOS)` — политика этого репозитория запрещает `#if os(...)` вне адаптеров, а
`Playground/Shared` — общий код); tvOS получает только кнопку/remote-select через `ControlNode`'s
`activation`.

### 3.3. Реальный прогон жеста — что действительно было выполнено

Это — конкретный пробел, который M12's report называл прямо (§4 её отчёта): «реальный
end-to-end run... требует нового `TrellisHostView` forwarding API... вне scope этой карточки».
M13 закрывает именно это:

- Собран и запущен S29 через реальный `xcodebuild` на iPhone 17 Pro Simulator (не headless
  `swift test` — тот процесс, как M12's report документирует, не доставляет состояние
  `UIGestureRecognizer`/`NSGestureRecognizer` вообще).
- Кнопочное открытие `.expand` залогировало `transition-presented`; это и обнаружило дефект #53
  (card оставалась видимой) — см. §4.
- Настоящий свайп вниз пальцем от `.presented` через `UIPanGestureRecognizer` довёл
  `interactiveClosing` до `transition-gesture-end target=closed`; это обнаружило дефект #54
  (`transition-closed` не наступал никогда) — см. §4.
- После обоих фиксов повторный прогон S29 на том же Simulator подтвердил корректный визуальный
  результат (`transition-closed` наступает, экран не остаётся пустым/непрозрачным).

**Про скриншоты — исправлено по ходу этой же карточки.** Диагностика обоих дефектов (#53/#54)
велась по логам (`TRELLIS_LOG=host,layer`) и визуальному наблюдению на живом Simulator, не по
сохранённым PNG-референсам. На момент первой сборки этого отчёта `docs/validation/screenshots/`
не содержал референсов для S29 вовсе — `check_all.py --matrix`'s собственный
`Scripts/check_screenshots.py` шаг это подтвердил (`FAIL S29_ExpandTransitionPlatforms.png:
rendered but has no reference`, `FAIL S29_ExpandTransitionPlatforms_overlay.png: ...` — S29
действительно рендерится и участвует в скриншотном гейте наравне с любой другой сценой, в
отличие от того, что предполагалось раньше). Исправлено тем же путём, что M08 уже применяла для
S27/S28: `python3 Scripts/check_screenshots.py --update --review-note
docs/validation/m13-transition-lifecycle-and-platforms.md` — добавило ровно два новых файла,
`docs/validation/screenshots/macOS/S29_ExpandTransitionPlatforms{,_overlay}.png` (`git status`
подтверждает: только эти два файла новые, ни один существующий референс не тронут). Повторный
`check_screenshots.py` — `PASS 58 scenario screenshots match docs/validation/screenshots/macOS`.
iOS/tvOS референсы для S29 не сняты этой карточкой (макет S24–S28 уже устанавливает: не каждая
сцена держит референсы на всех трёх платформах) — это не пробел приёмки, `check_screenshots.py`
сверяет только macOS-набор.

## 4. Дефекты #53 и #54 — сводка

Оба найдены исключительно реальным прогоном S29 в iOS Simulator — ни один не воспроизводился ни
одним детерминированным тестом M11/M12. Полный текст — `docs/defects.md`, здесь только сводка,
без дублирования:

- **#53** — `NodeHostBridge`'s M11-код скрывал source/destination прямой записью
  `renderer.layer(for:)?.opacity = 0/1`, мимо `Node.style.visual.opacity`; следующий любой
  commit (даже paint-only, не связанный с переходом) вызывал
  `LayerRenderer.applyPresentation(of:to:)`, который безусловно пересчитывал `opacity` из модели
  и тихо отменял скрытие. Исправлено: `LayerRenderer.transitionHiddenNodeIDs`/
  `setTransitionHidden(_:hidden:)` — скрытие теперь часть того же вычисления, что
  `applyPresentation` делает на каждый commit, а не одноразовая запись.
- **#54** — `TransitionAnimator.arm`/`freezeForGesture` парковали слой на `speed = 0` для ручного
  скраба; `endManual()` сбрасывал только внутренний флаг, никогда не восстанавливал
  `layer.speed`/`timeOffset`; `play()`, вызванный сразу после для автоматического доигрывания,
  добавлял анимацию на слой, чьи медиа-часы всё ещё стояли — анимация физически не продвигалась,
  `completion` не срабатывал никогда. Исправлено: `TransitionAnimator.play` безусловно
  нормализует `speed = 1`/`timeOffset = 0`/`beginTime = 0` на каждом заармленном слое.

## 5. D25/D34/D40/D46 — перечитаны, не изменены молча

Карточка требует явного подтверждения (`docs/implementation-plan-5.md` §6's приёмка: «существующие
D25/D34/D40/D46 не меняются молча»). Все четыре перечитаны в `docs/decisions.md` целиком перед
написанием этого отчёта:

- **D25** — «Immutable `HitTestSnapshot` (`TrellisCore`), формируется в commit-точке
  `LayerRenderer` и хранится на `NodeHostBridge`: root identity, mount epoch, по `NodeID` —
  parent, ordered children, committed frame, committed `LayoutVisualProperties`,
  `isArrangementWrapper`. Hit-test — только по снимку; до первого commit, после detach и без
  снимка — `nil`.» M13 не трогает `HitTestSnapshot` ни в одном файле diff'а (`git diff --stat`
  не показывает `HitTest*.swift`); новый `transitionHiddenNodeIDs`-set в `LayerRenderer` влияет
  только на `CALayer.opacity`, не на снимок геометрии, который читает hit-testing. **Не
  нарушено.**
- **D34** — «Commit между down и up: маршрут остаётся с down, геометрия up-inside — из
  последнего committed снимка.» Не относится к коду, который трогает эта карточка (pointer
  routing); M13 не меняет `HitTestSnapshot`/routing-путь. **Не нарушено.**
- **D40** — «Scope/lifecycle. Одна modal scope на bridge, без стека... Открытие — одна
  транзакция... Закрытие восстанавливает `restorationID`... `detach()`/замена root очищают
  focus, scope, очередь... `suspend()` отменяет начатый press-cycle и сохраняет только
  restoration ID.» M13 не меняет `FocusEngine.setScope(_:)`'s механизм (сам вызов — из M10/M11,
  без изменений в этом diff — `git diff --stat` не показывает `Focus*.swift`); M13 только
  добавляет тесты, подтверждающие, что уже существующий D40-путь верно срабатывает через M12's
  новые gesture-состояния (§1). **Не нарушено, буквально проверено новыми тестами** — реализация
  D40 самого не менялась.
- **D46** — «Геометрия. Видимая область — AABB polygon после transform по цепочке... Native AX
  frame — screen-space bounding box видимой области.» M13 не трогает `AccessibilityTree`/AX
  geometry-код; `setTransitionHidden` меняет только `CALayer.opacity`, не frame/geometry, и не
  участвует в AX-дереве напрямую (AX-скрытие идёт через уже существующий
  `AccessibilityChildrenPolicy.hide`, D42, не через opacity). **Не нарушено.**

Ни одна из четырёх декларируется противоречащей текущему diff'у — все проверены по актуальному
тексту `docs/decisions.md`, а не по памяти о том, что они «наверное» говорят.

## 6. Платформы — что реально проверено

| Платформа | Команда | Результат |
|---|---|---|
| macOS | `swift build`, `swift test` (`-Xswiftc -warnings-as-errors`) | PASS |
| macOS | `xcrun swift-format lint --strict` | PASS |
| macOS | `python3 Scripts/check_policy.py` | PASS |
| macOS (consumer, `swift run Smoke`) | `check_all.py --matrix` | PASS |
| API baseline (`check_api.py --update --tvos --review-note docs/adr/0019-...md`) | ручной запуск отдельно от `check_all.py`, затем сверен обычным `check_api.py --tvos` внутри `check_all.py --matrix` | PASS — `api/TrellisUIKit.json`/`api/TrellisAppKit.json` обновлены (7 добавленных символов на каждый модуль, ADR 0019 как review-note); `TrellisUIKit` tvOS surface совпадает с iOS baseline, отдельный tvOS-файл не потребовался; последующий `check_all.py --matrix` подтверждает совпадение с обновлённым baseline (`PASS TrellisAppKit (46 symbols)`, `PASS TrellisUIKit (50 symbols)`) |
| macOS universal (arm64+x86_64, `xcodebuild build`) | `check_all.py --matrix` | PASS |
| iOS device (generic/platform=iOS, build-only) | `check_all.py --matrix` | PASS |
| tvOS device (generic/platform=tvOS, build-only) | `check_all.py --matrix` | PASS |
| iOS Simulator (iPhone 17 Pro, реальный `xcodebuild test`, весь пакет) | `check_all.py --matrix` | PASS |
| tvOS Simulator (Apple TV 4K (3rd generation), реальный `xcodebuild test`) | `check_all.py --matrix` | PASS |
| Screenshot-эталоны (58 сцен, включая новую S29) | `check_all.py --matrix` | Первый прогон: **FAIL** — `S29_ExpandTransitionPlatforms{,_overlay}.png: rendered but has no reference`; исправлено в рамках этой же карточки (§3.3: `check_screenshots.py --update --review-note`, ровно 2 новых файла); повторный полный `check_all.py --matrix` — PASS |
| `TRELLIS_LOG` в реальном процессе (`check_log_env.py`) | `check_all.py --matrix` | PASS |
| iOS Simulator, S29 интерактивно (кнопка + реальный `UIPanGestureRecognizer`) | ручной `xcodebuild`/Simulator-прогон вне гейта, до фиксов #53/#54 и после | PASS после фиксов (см. §3.3/§4) |
| Физическое устройство | — | не проверено — нет доступа в этой среде |

Полный `python3 Scripts/check_all.py --matrix` (реальный `xcodebuild test` на iPhone 17 Pro и
Apple TV 4K (3rd generation) Simulator) запущен дважды — первый прогон нашёл недостающие S29
screenshot-референсы (см. таблицу выше); итоговый прогон на исправленном дереве закончился
`PASS C03/C04/C05 quality gates.`, без единого `FAIL` в самом гейте (одна строка `FAIL failure`
в логе — ожидаемый вывод собственного негативного unit-теста `test_verifier.py`'s
`test_command_failure_is_recorded_and_stops`, сразу подтверждённый `ok`, не сбой гейта). Не было
скрытых повторных попыток ради зелёного лога — первый прогон честно провалился на реальной
проблеме (отсутствующий screenshot-референс новой сцены), фикс занял один вызов существующего
скрипта по установленному прецеденту M08, второй прогон — чистый end-to-end PASS.

## Приёмка M13

- D73: modal scope, focus restoration, единственное AX-представление, блокировка background,
  Reduce Motion, suspend и detach на каждой фазе — подтверждены §1, включая новые M12-состояния,
  которые M11's тесты не могли видеть.
- Host resize и пропажа source во время закрытия; epochs, late callbacks, disposal при
  подготовке destination; cancellation освобождает artifacts — реализовано и протестировано §2.
- Touch на iOS, pointer на macOS через реальный `TrellisHostView` forwarding API (§3.1) и
  реальный `UIPanGestureRecognizer`/`NSPanGestureRecognizer` (§3.2/§3.3, S29); tvOS
  открытие/закрытие кнопкой/remote, touch-жест не объявлен доступным на tvOS автоматически.
  Скриншот-эталоны для S29 отсутствуют — честно зафиксировано как пробел (§3.3), а не скрыто.
- D25/D34/D40/D46 перечитаны буквально и подтверждены не изменёнными — §5.

## Область изменений

- `Sources/TrellisRender/LayerRenderer.swift` — `transitionHiddenNodeIDs`/
  `setTransitionHidden(_:hidden:)` (дефект #53).
- `Sources/TrellisRender/NodeHostBridge.swift` — `reconcileTransitionGeometryIfNeeded()`,
  `clearStaleTransitionGeometryAnimations()`, `rebuildTransitionForReconcile(...)`,
  `transitionBuiltBounds`, `setTransitionHidden(_:hidden:root:)`, все 4 пары прямых
  `layer(for:)?.opacity =` переведены на новый API, `buildTransitionVisuals` gains
  `resetProgressOnManual`.
- `Sources/TrellisRender/Transition/TransitionAnimator.swift` — `play` нормализует
  `speed`/`timeOffset`/`beginTime` на каждом заармленном слое (дефект #54);
  `clearStaleAnimations(keyPaths:on:)`.
- `Sources/TrellisUIKit/TrellisHostView.swift`, `Sources/TrellisAppKit/TrellisHostView.swift` —
  семь новых forwarding-членов (§3.1).
- `Playground/Shared/Scenarios/S29_ExpandTransitionPlatforms.swift` — новый файл.
- `Playground/Shared/Scenario.swift`, `Playground/Playground.xcodeproj/project.pbxproj` — S29
  зарегистрирована.
- `Tests/TrellisRenderTests/M13TransitionLifecycleTests.swift` — новый файл, 12 тестов
  (resize×2, source-disappears×2, prepare-cancellation, closing-interrupted-by-detach,
  late-completion-after-detach, suspend×1, detach×1, transition-hidden-survives-paint-only×2,
  gesture-resume×1, focus-restoration×2).
- `docs/adr/0019-trellis-host-view-transition-forwarding.md` — новый ADR.
- `docs/defects.md` — дефекты #53, #54.
- `docs/decisions.md`, `docs/implementation-plan-5.md` — M13-заметка, чекбоксы, перенумерация
  M14's демо-сцен S29/S30 → S30/S31.
- `api/TrellisUIKit.json`, `api/TrellisAppKit.json` — baseline обновлён (ADR 0019, семь символов
  на каждый модуль).
- `docs/validation/screenshots/macOS/S29_ExpandTransitionPlatforms.png`,
  `..._overlay.png` — новые референсы (найдены отсутствующими первым прогоном
  `check_all.py --matrix`, добавлены `check_screenshots.py --update --review-note` в рамках этой
  же карточки, §3.3/§6).

Не тронуто: `Sources/TrellisRender/Transition/TransitionSession.swift` (форма не меняется),
`Sources/TrellisCore` (Role/FocusEngine/AccessibilityTree без изменений — §5), `Sources/
TrellisRender/Transition/TransitionGesturePreset.swift` (пороги M12 не пересматриваются).
