# Источник переноса и лицензии

Дата фиксации: 2026-09-10. Карточка: C01.

Документ отвечает на один вопрос: **из какого именно состояния какого репозитория
перенесён каждый файл Trellis**, чтобы перенос можно было воспроизвести и чтобы
через полгода было понятно, что где менялось руками.

## 1. Источник

| | Значение |
|---|---|
| Репозиторий | `git@github.com:resoul/Weave.git` |
| Ветка | `v2` |
| Commit | `17da626632d6493e9b402ddb213b4bbab8c59bec` |
| Дата коммита | 2026-09-09 20:25:27 +0300 |
| Сообщение | `weave release candidate` |
| Состояние checkout | **чистый** — `git status --porcelain` пуст на момент фиксации |
| Локальный путь на момент анализа | `/Users/resoul/projects/v2/Weave` |

Проверка воспроизводимости:

```bash
git -C Weave rev-parse HEAD          # 17da626632d6493e9b402ddb213b4bbab8c59bec
git -C Weave status --porcelain      # пусто
```

Checkout был чистым, поэтому весь перенос ссылается на этот commit без оговорок
про несохранённые правки. Если при возобновлении работы `rev-parse` даст другой
хэш или `status` окажется непустым — **сначала обновить эту таблицу**, потом
переносить. Анализ в `docs/weave-analysis.md` также выполнен по этому состоянию.

**Weave не изменяется ради Trellis.** Любая правка, которая выглядит нужной в
Weave, записывается сюда как расхождение, а не вносится в источник.

## 2. Список источников переносимых файлов

Заполняется по мере выполнения C03 и карточек C05–C24. Источники Weave ниже
относятся к commit `17da626632d6493e9b402ddb213b4bbab8c59bec` из §1. Формат строки:
`целевой файл ← исходный файл @ commit — характер переноса`.

Характер переноса — одно из:

- `как есть` — копия с точностью до имён модуля и форматирования;
- `правка` — перенос с изменением, указанным номером находки/карточки;
- `заново` — написано с нуля, источник указан как ориентир.

| Целевой файл Trellis | Источник в Weave | Характер | Карточка |
|---|---|---|---|
| `Sources/TrellisRender/Scroll/NodeHostBridge+ScrollInput.swift`; reveal geometry в `HitTest.swift`; focus/key integration в `NodeHostBridge.swift` | нет | заново: snapshot-only reveal plan, scope/live guards, native confirmation и AX paging по ADR 0028 | R08 |
| `Sources/TrellisUIKit/NativeProxies.swift`, `Sources/TrellisAppKit/AccessibilityElements.swift`; scroll backings | нет | доработка Trellis: AX page actions, native reveal request, bounds ticks и cancellation/dispose guards | R08 |
| `Tests/TrellisRenderTests/UIKitScrollInputTests.swift`, `AppKitScrollInputTests.swift`; R08 tests в `ScrollNodeHitTestTests.swift` | нет | заново: native AX/actions, stale callbacks, reveal, scope, cancellation | R08 |
| `Playground/UITests/iOSScrollTests.swift`, `tvOSScrollTests.swift`; UI-test targets/schemes и S33 test viewport/value | нет | заново: реальные XCUITest touch/remote события, без прямого вызова bridge | R08 |
| `Sources/TrellisRender/Scroll/ScrollGestureArbiter.swift`; coordinate-aware transition entry point в `NodeHostBridge.swift` и platform controllers | нет | заново: R09 direction lock, one-owner delta accounting, scroll-priority close gating по ADR 0029 | R09 |
| `Playground/Shared/Scenarios/S34_NestedScrollArticle.swift` | нет | заново: внешний consumer — длинная статья с вложенной горизонтальной галереей | R09 |
| `Sources/TrellisCore/Collections/*.swift`; `Tests/TrellisCoreTests/Collections/*.swift` | `Sources/WeaveUI/Collections.swift`, `Tests/WeaveBootstrapTests/CollectionsTests.swift` — ориентир | заново: snapshot first-wins, extents по измеренным длинам (без формулы #64), окно/cap, пагинация, кэш измерений, provider/dispatcher, окно материализации, бюджет хоста, loader по ADR 0030 | R10 |
| `Sources/TrellisCore/Collections/CollectionTransactions.swift`, `CollectionUpdateQueue.swift`; anchor/commit в `MaterializationWindow.swift`; `Tests/TrellisCoreTests/Collections/CollectionTransactionTests.swift` | нет (Weave #64 — пример, чего не делать; Telegram `ListViewTransactionQueue` — ориентир очереди) | заново: воркерная подготовка, атомарный commit, якорь по измеренным длинам, property-тест по ADR 0031 | R11 |
| `Sources/TrellisCore/Collections/HostedContainer.swift`, `ListNode.swift`; `Sources/TrellisRender/Scroll/NodeHostBridge+Containers.swift`; `Playground/Shared/Scenarios/S35_ListNodeFeed.swift`; R12a tests в `Tests/TrellisRenderTests/ListNodeHostTests.swift`, `AppKitListNodeTests.swift`, `Playground/UITests/iOSScrollTests.swift` | нет (StreetScroller/UITableView — ориентир: смена contentOffset во время жеста) | заново: обнаружение контейнеров, сдвиг offset в geometry commit, consumer 20 + 20 по ADR 0032 | R12a |
| `Sources/TrellisCore/Collections/GridLayout.swift`, `CollectionNode.swift`, `GridNode.swift`; ряды в `MaterializationWindow.swift`; `Tests/TrellisCoreTests/Collections/GridLayoutTests.swift`; `Playground/Shared/Scenarios/S36_GridNodeMedia.swift` | `Sources/WeaveUI/Collections.swift` (`GridLayout.columnCount`) — ориентир | заново: ряды в общем окне, adaptive/fixed колонки, aspect-ячейки по ADR 0033 | R12b |
| `Sources/TrellisCore/Collections/SwipeActions.swift`, `TableNode.swift`; transform в `CollectionNode.swift`; `Tests/TrellisCoreTests/Collections/TableContractTests.swift`, `Tests/TrellisRenderTests/TableNodeHostTests.swift`; `Playground/Shared/Scenarios/S37_TableNodeInbox.swift` | `Sources/WeaveUI/Collections.swift` (`SwipeActionsConfiguration`, full-swipe threshold) — ориентир; Telegram — ориентир поведения | заново: строки с контекстом, контроллер swipe, политики P6.6, AX actions по ADR 0034 | R12c |
| `CollectionNode.scrollTo` / `CollectionScrollResult`, `ContainerHost.scrollContainer`, строка-`ControlNode` в `TableNode.swift`, `PaginationGate` (#88); `Tests/TrellisRenderTests/CollectionResultCTests.swift`, `Tests/TrellisFluxTests/ExternalConsumerCollectionsTests.swift`, consumer в `Scripts/verify_bootstrap.py`, сценарий `collections` в `Playground/Shared/PerfHarness.swift`, tvOS XCUITest | отсутствует (Weave в этой карточке не использовался); опора — собственные R07 scroll commands и ADR 0028 reveal-before-focus | заново: reveal с уточнением после измерения, фокусируемые строки, внешний consumer, замеры контейнеров по ADR 0035 | R12 |
| `Sources/TrellisCore/Pager/*.swift`; `pagePosition`/page state в `CollectionNode.swift`/`TableNode.swift`; `ScrollCommand.timed`, `presentedContentOffset`/`scroll(to:animation:)` в бэкингах UIKit/AppKit; `Tests/TrellisCoreTests/Pager/*`, `Tests/TrellisRenderTests/PagerNodeHostTests.swift`, `AppKitPagerTests.swift`; `Playground/Shared/Scenarios/S38_PagerTabs.swift`, XCUITest iOS/tvOS | отсутствует: исходники Telegram (`PeerInfoPaneContainerNode.swift`) и XLPagerTabStrip в `../old` на машине нет; ориентир — описание в плане §1.1.1/§3 | заново: собственный pan поверх нативного горизонтального scroll, общий progress и кривая по ADR 0036 | R13 |
| `Scripts/check_policy.py` | `Scripts/check_policy.py` | правка: raw/code разделение, новые правила, docs/links и точечные исключения | C03 |
| `Scripts/swift_lex.py` | отсутствует | заново: маска Swift с интерполяциями и сохранением позиций | C03 |
| `Scripts/test_policy.py` | `Scripts/test_policy.py` | правка: unittest, прежние 8 фикстур и новые позитивные/негативные случаи | C03 |
| `Tests/PolicyFixtures/` | `Tests/PolicyFixtures/` | фикстуры как есть; README дополнен | C03 |
| `Scripts/verify_bootstrap.py` | `Scripts/verify_bootstrap.py` | правка: Trellis manifest, без Flux/resolve, consumer и матрица; внешний consumer H11 исполняет публичный committed-snapshot event/control путь без `@testable` | C03, H11 |
| `Scripts/test_verifier.py` | отсутствует | заново: ошибки manifest и fail-closed выполнение команд | C03 |
| `Scripts/check_all.py` | `Scripts/check_all.py` | правка: C03/C04/C05 gates; build, tests, API baseline, log env | C03, C04, C05 |
| `policy.json` | `policy.json` | правка: версия 2.0.0, Trellis boundaries и конвенции | C03 |
| `toolchain.json` | `toolchain.json` | правка: сохранены C02 toolchain pins, linter 2.0.0 | C03 |
| `.github/workflows/quality.yml` | `.github/workflows/ci.yml` | правка: локальный C03 gate; hosted run и полная CI-матрица — C27 | C03 |
| `Scripts/check_api.py` | `Scripts/check_api.py` | правка: multi-target SDK extraction, review notes | C04 |
| `Sources/TrellisRender/DebugOverlayRenderer.swift` | `Sources/WeaveUI/DebugOverlay.swift`, `Sources/AppKitAdapter/DebugOverlay.swift`, `Sources/UIKitAdapter/DebugOverlay.swift` | заново: CALayer-overlay вместо view с `draw(_:)`, без `DebugOverlayEntry`; подписи с `NodeID` и размером, цвет по Arrangement | C25 |
| `Sources/TrellisCore/StateSubject.swift`, `Sources/TrellisRender/StateBinding.swift` | `Node.bind(id:_:update:)` + `Flux` (не переносились) | заново: latest-value subject без внешней зависимости, владелец подписки — bridge | C29 |
| `Bench/`, `Scripts/bench.py` | отсутствует | заново: consumer-пакет с fixtures C31 (+ `wrappers-*` для C30) и скрипт запуска/сохранения измерений | C31, C30 |
| `Scripts/check_screenshots.py` | отсутствует | заново: экспорт сцен Playground-macOS и побайтное сравнение с `docs/validation/screenshots/macOS`, `--update --review-note`; H10 исправляет путь после удаления устаревших корневых дубликатов (#32) | C24, H10 |
| `api/` (`*.json`) | отсутствует | заново: baseline символов модулей | C04 |
| `Sources/TrellisCore/Log.swift` | `Sources/Weave/Log.swift` | правка: 11 областей, строковый формат, pure helpers | C05 |
| `Tests/TrellisCoreTests/LogTests.swift` | `Tests/WeaveTests/LogTests.swift` | правка: проверка pure functions и изоляции | C05 |
| `Scripts/check_log_env.py` | отсутствует | заново: запуск реального процесса со stdout под TRELLIS_LOG | C05 |
| `Sources/TrellisCore/Layout/` | `Sources/Weave/Layout.swift`, `LayoutResult.swift` | правка: декомпозиция типов геометрии, constraints, roundings, LayoutResult; LayoutContext заново | C06 |
| `Tests/TrellisCoreTests/Layout/` | `Tests/WeaveTests/LayoutTests.swift` | правка: тесты геометрии, constraints, контекста отмены | C06 |
| `LICENSE` | отсутствует | заново: лицензия MIT | C06 |
| `Sources/TrellisCore/Layout/LayoutStyle.swift` | `Sources/WeaveUI/Layout.swift` | правка: mutable-поля, нормализация в `didSet`, явный `init()`, D04 base/effective | C07 |
| `Sources/TrellisCore/Layout/LayoutTransform.swift` | `Sources/WeaveUI/Layout.swift` | правка: выделен platform-neutral transform | C07 |
| `Sources/TrellisCore/Events/Event.swift`, `EventDispatcher.swift`; хуки `handleCapture`/`handleEvent`/`handleBubble` в `Node.swift` | `Sources/WeaveUI/Events.swift` (`EventType`, `EventPhase`, `PointerData`, `Event`, `EventResult`, `EventDispatcher`), `Node.swift:259-269` | правка: только pointer-события, без `windowID`/`UUID`; маршрут — `[NodeID]` из `HitTestSnapshot`, не live `Node`, с проверкой перед каждым callback (D28) и `routeBroken` в результате; `PointerCaptureStore`/`HitTester` не переносятся (D27, H02b) | H03 |
| `Tests/TrellisCoreTests/Events/EventDispatcherTests.swift` | `Tests/WeaveBootstrapTests/EventTests.swift` | правка: порядок фаз и `stopPropagation` — по духу; вместо «ancestry snapshot доставляет после removal» — обратное ожидание D28 (доставка прекращается, `routeBroken`); reparent, nested dispatch, unresolvable route заново | H03 |
| `Sources/TrellisCore/Gestures/GestureRecognizer.swift`, `GestureArena.swift`; `addGestureRecognizer`/`removeGestureRecognizer` в `Node.swift`; arena в `PointerSessions` | `Sources/WeaveUI/Gestures.swift` (`GestureState`, `GestureResult`, `GestureConfiguration`, `GestureRecognizer`, `TapRecognizer`, `PanRecognizer`, `GestureArena`) | правка: только Tap и Pan (D23), без clock/max duration (D31), пороги 10/10; arena — per-session, собирается с маршрута (target → предки, D29), winner только на `.began` (G06), `cancel()` сбрасывает напрямую (D21); `DoubleTap`/`LongPress`/`Pinch`/`Rotation`/capture в arena не переносятся | H05 |
| `Tests/TrellisCoreTests/Gestures/GestureTests.swift` | `Tests/WeaveBootstrapTests/GestureTests.swift` (пороги/арбитраж — по духу) | заново: случаи h01-contract §4, пороги `<`/`==`/`>`, G06, cancel через arena при нерезолвимом маршруте | H05 |
| `Tests/TrellisRenderTests/PointerLoadAndLifecycleTests.swift` | нет прямого аналога | заново: H10-нагрузка 128 controls/1024 последовательных pointer ID; повторные attach/detach активного Pan с suspend/resume и resize; dispose из каждой pointer-фазы; нулевые session/per-session arena и weak release bridge/root/control | H10 |
| `Sources/TrellisCore/Controls/ControlNode.swift`; `HitTestSnapshot.contains(_:node:)` в `HitTest.swift`; `Event.snapshot` в `Event.swift` | `Sources/WeaveUI/Controls.swift` (`ControlNode<Interaction>`, `isPressed`, up-inside tracking) | правка: без `Interaction`/`ActionPipe`/`InteractiveNode`/`ControlInputTarget` (D22, G07) — один `@MainActor () -> Void`; up-inside — committed-геометрия последнего снимка на момент события (D34), не просто deepest-hit; `isEnabled`/`isLoading` не переносятся | H06, [ADR 0011](adr/0011-event-init-gains-snapshot-parameter.md) |
| `Tests/TrellisCoreTests/Controls/ControlNodeTests.swift` | нет прямого аналога (Weave не тестировал up-inside через committed snapshot отдельно от live tree) | заново: случаи h01-contract §5 1–7, реентерабельность activation (dispose/cancelAll) проверена тестом, не только рассуждением | H06 |
| `Sources/TrellisUIKit/TrellisHostView.swift` (touch overrides), `Sources/TrellisAppKit/TrellisHostView.swift` (mouse overrides) | нет — `UIKitAdapter.swift`/`AppKitAdapter.swift` намеренно не источник (G01: собственный `HitTester`/`EventDispatcher`/`GestureArena` там не используется даже самим Weave, дублирующие ручные state machines, переносить нечего) | заново, поверх уже существующего `TrellisHostView` (C17/C18): `UITouch`/`NSEvent` → `PointerData` → `bridge.send(_:_:)`, никакой собственной state machine | H07, H08 |
| `Tests/TrellisRenderTests/AppKitPointerInputTests.swift` | нет прямого аналога | заново: реальные `NSEvent` через `TrellisHostView` до активации `ControlNode` — `NSEvent` конструируем публичным API, в отличие от `UITouch` | H08 |
| `Playground/Shared/Scenarios/S21_TapCounter.swift`; `Playground/Playground.xcodeproj/project.pbxproj` (S21 file refs) | нет прямого аналога | заново: единственная сцена, доказывающая snapshot → hit-test → dispatch → арбитр → control end-to-end; три сигнала без текста (N01 вне рамок); ADR 0012 расширяет `ControlNode.handleEvent`/`handleBubble` до `open` для этого переопределения | H09, [ADR 0012](adr/0012-controlnode-hooks-become-open.md) |
| `Sources/TrellisCore/Semantics/FocusProperties.swift`, `AccessibilityProperties.swift`, `SemanticSnapshot.swift`; `focus`/`accessibility`/`semanticsRevision` в `Node.swift`; `isEnabled` в `ControlNode.swift`; `visibleBounds(of:)` в `HitTest.swift` | `Sources/WeaveUI/Focus.swift` (`FocusDirection`, `FocusableSpec`), `Accessibility.swift` (`AccessibilityRole`, `AccessibilityChildrenPolicy`, `AccessibilityAction`, `AccessibilityProperties`), `Node.swift:87-105` (`accessibility`, `focusEligibility`, `accessibilityRevision`), `Controls.swift:101` (`isEnabled`) | правка: `forward`/`backward` → `next`/`previous` (tree order, не nearest-neighbour — #33); один источник enabled/selected/value без дублирования traits/state (W07); `NodeSemantics.isHidden` и `.hide` слиты в `childrenPolicy`; `SemanticSnapshot` заново — committed geometry + metadata с `traversalIndex`, без `Node` (D36); `AccessibilityElementSnapshot`/`AccessibilitySnapshot` не переносятся | A03 |
| `Sources/TrellisCore/Focus/FocusEngine.swift`; `focusIn/focusOut/keyDown/keyUp`, `FocusData`, `KeyData`, `KeyboardKey`, `Event.pointer: PointerData?` в `Events/Event.swift` | `Sources/WeaveUI/Focus.swift` (`FocusTree`, `FocusChange`, `FocusTrace`), `Events.swift` (`focusIn`/`focusOut` cases) | правка: без Flux `Pipe` и strong `focusedNode` (#34) — identity + borrowed root, транзакция D39 с очередью; `.next`/`.previous` — tree order, стрелки — `primary + 0.5·secondary` без priority-epsilon (#33); scope как ID с restoration; `register`/`unregister` не переносятся — источник кандидатов `SemanticSnapshot` | A04, A05, [ADR 0013](adr/0013-event-pointer-becomes-optional.md) |
| `Tests/TrellisCoreTests/Focus/FocusEngineTests.swift` | `Tests/WeaveBootstrapTests/FocusTests.swift` (directional move, override, hidden, modal — по духу) | заново: случаи a01 §4–§5, реентрантность (dispose/reset/deferred/loop), fallback по прежнему порядку | A04, A05 |
| `Sources/TrellisCore/Semantics/AccessibilityTree.swift` | `Sources/WeaveUI/Accessibility.swift` (`AccessibilityTree`, `AccessibilityElementSnapshot`, `AccessibilitySnapshot`) | правка: builder по `SemanticSnapshot` (не по live `Node`), итеративный; `.combine`/`.ignoreSelf` с реальной семантикой (#35), labelled group для `.contain`+`isElement`+дети; `AccessibilityBridge` protocol не переносится — адаптеры подписываются на `NodeHostBridge.onAccessibilityTreeChanged` | A06 |
| `Tests/TrellisCoreTests/Semantics/AccessibilityTreeTests.swift` | `Tests/WeaveBootstrapTests/AccessibilityTests.swift` (reading order, hide, modal — по духу) | заново: четыре политики на одном fixture с видимыми детьми, disabled control, ties, wrappers, zero-size parent, nested policies, clipped subtree | A06 |
| `Sources/TrellisUIKit/NativeProxies.swift`; key/press overrides и focus API в обоих `TrellisHostView.swift` | нет — `UIKitAdapter.swift:66-68` (host как tvOS focus target) и `AppKitAdapter.swift` не источник: там нет focus items без UIView и нет key → engine пути | заново: `TrellisNodeProxy: UIAccessibilityElement, UIFocusItem` по прототипу A02, `NativeProxyCoordinator` с pending token (D44/D45); `NSEvent`/`UIPress` → `KeyData` → `bridge.send(_:key:)`, непотреблённое — `super` | A08 |
| `Tests/TrellisRenderTests/AppKitKeyboardInputTests.swift`, `UIKitKeyboardAndFocusProxyTests.swift` | нет прямого аналога | заново: реальные `NSEvent` key events и responder chain; press mapping и native handshake на iOS/tvOS Simulator | A08 |
| accessibility-часть `Sources/TrellisUIKit/NativeProxies.swift` и `TrellisHostView.swift` (container, notifications) | `Sources/UIKitAdapter/UIKitAdapter.swift:1249-1261` (`UIKitAccessibilityBridge`: только snapshot + `layoutChanged`) | заново: реальные `UIAccessibilityElement` proxies с traits/frames/actions/custom actions и container-иерархией, уведомления по diff (D47), действия через live guard bridge (D43) | A09 |
| `Tests/TrellisRenderTests/UIKitAccessibilityTests.swift` | нет | заново: native enumeration, actions, reuse/notifications, modal, frames — на iOS/tvOS Simulator | A09 |
| `Sources/TrellisAppKit/AccessibilityElements.swift`; accessibility overrides в `TrellisAppKit/TrellisHostView.swift` | `Sources/AppKitAdapter/AppKitAdapter.swift` (`AppKitAccessibilityBridge`: только snapshot + notification) | заново: реальные `NSAccessibilityElement` с parent/children, role mapping с fallback header → staticText, screen frames через flipped host, `.layoutChanged` на host/`.valueChanged` на элементах (D47), epoch guard старых handlers | A10 |
| `Tests/TrellisRenderTests/AppKitAccessibilityTests.swift` | нет | заново: native enumeration, actions, reuse/notifications, два окна, перенос окна | A10 |
| `Playground/Shared/Scenarios/S22_FocusGrid.swift`, `S23_Semantics.swift`, `Playground/Shared/AccessibilityDump.swift`; `--scene`/`--dump-accessibility`/`--drive-focus` в apps; `project.pbxproj` (S22/S23/dump refs) | нет прямого аналога | заново: сцены focus grid (ring/counter/disabled/remove/modal) и semantics (четыре политики, selectable, adjustable); evidence-хуки для native AX dump и automated keyboard drive; tvOS-app отдаёт стрелки/Select host, Play/Pause переключает сцены | A11 |
| `Sources/TrellisCore/VisualStyle.swift` | `Sources/WeaveUI/VisualStyle.swift` | правка: верхний style mutable, без `StyleBuildable`/Draft | C07 |
| `Sources/TrellisCore/ThemeColor.swift` | `Sources/WeaveUI/Theme.swift` | часть: platform-neutral RGBA token и минимальный `Theme`/`ThemeColors`; C16 добавляет neutral `defaultValue`, без palette/store | C07, C16 |
| `Sources/TrellisCore/Layout/SizeValue.swift` | `Sources/WeaveUI/Layout.swift` | правка: integer/float literals означают points; fraction остаётся явной | C07 |
| `Tests/TrellisCoreTests/Layout/LayoutStyleTests.swift`, `LayoutTransformTests.swift`, `VisualStyleTests.swift` | `Tests/WeaveBootstrapTests/LayoutTests.swift` | правка: layout-ожидания дополнены defaults, mutable writes, NaN/infinity и повторной нормализацией; visual-тесты заново | C07 |
| `Sources/TrellisCore/Node.swift` | `Sources/Weave/Node.swift` | правка: MainActor open class, без Flux/state/events/compose/backing/scroll; каскадный dispose, Log.on на отказы | C08 |
| `Tests/TrellisCoreTests/NodeTests.swift` | `Tests/WeaveTests/NodeTests.swift` | правка: lifecycle, cycles, reparent, diagnostics, consumer | C08 |
| `Sources/TrellisCore/Invalidation.swift` | `Sources/Weave/Invalidation.swift` | правка: DirtyReasons, InvalidationTransaction, geometry revision climbing | C09 |
| `Sources/TrellisCore/Animation.swift`; animation-intent части `Node.swift`/`RenderCoordinator.swift` | `Sources/WeaveUI/Animation.swift`, `Sources/WeaveAdapters/RenderCoordinator.swift` | правка: value timing без spring/delay/completion; ambient `AnimationContext` не перенесён — локальный scope collector корня; metadata вынесена из `HostRenderRequest`, retry merge по epoch/sequence | M03 |
| `Tests/TrellisCoreTests/InvalidationTests.swift` | `Tests/WeaveTests/InvalidationTests.swift` | правка: coalescing ping, revisions, batch mutations | C09 |
| `Sources/TrellisCore/Environment.swift` | `Sources/Weave/Environment.swift`, `Sources/WeaveUI/Theme.swift` | правка: EnvironmentKey/Values/Scope, safe area insets через DirectionalEdgeInsets; `ThemeKey` добавлен, когда C16 получил потребителя `Fill.theme` | C10, C16 |
| `Sources/TrellisCore/Layout/LayoutSnapshot.swift` | `Sources/Weave/LayoutSnapshot.swift` | правка: LayoutInputSnapshot, safeArea, Sendable tree snapshot | C10, C12 |
| `Tests/TrellisCoreTests/EnvironmentTests.swift`, `NodeSnapshotTests.swift`, `LayoutSnapshotTests.swift` | `Tests/WeaveTests/EnvironmentTests.swift` | правка: sparse values, propagation, constraints | C10 |
| `Sources/TrellisCore/Layout/LayoutResult.swift` | `Sources/Weave/LayoutResult.swift` | правка: indexed O(1) lookup, duplicate detection, revisions | C11, C12 |
| `Tests/TrellisCoreTests/Layout/LayoutResultTests.swift` | `Tests/WeaveTests/LayoutResultTests.swift` | правка: index lookup, duplicateIdentities, isWellFormed | C11 |
| `Sources/TrellisCore/Layout/FlexboxMeasure.swift` | `Sources/Weave/FlexSolver.swift` | правка: переименование в FlexboxEngine по D11, throws LayoutCancellationError, checkpoints по D09/D10 | C12 |
| `Sources/TrellisCore/Layout/FlexboxPlacement.swift` | `Sources/Weave/FlexSolver.swift` | правка: размещение FlexboxEngine, rounded(to:) из C06, Log.on trace | C12 |
| `Tests/TrellisCoreTests/Layout/Flexbox*Tests.swift` | `Tests/WeaveTests/FlexSolver*Tests.swift` | правка: портированы все suites FlexSolver, tests отмены, maxWidth тест | C12 |
| `docs/adr/0003-c12-flexbox-port-api-changes.md` | отсутствует | заново: ADR для аддитивных изменений LayoutResult/LayoutInputSnapshot | C12 |
| `Sources/TrellisCore/Layout/LayoutScheduler.swift` | `Sources/WeaveUI/LayoutEngine.swift` | правка: переименован в LayoutScheduler; internal LayoutEngine отделяет математику; один worker + latest pending и cooperative cancellation | C13 |
| `Tests/TrellisCoreTests/Layout/LayoutSchedulerTests.swift` | `Tests/WeaveBootstrapTests/LayoutEngineTests.swift` | правка: управляемый worker-gate доказывает один worker и A→B→C latest semantics без sleep; добавлены cancel/dispose и failure | C13 |
| `Sources/TrellisRender/RenderCoordinator.swift` | `Sources/WeaveAdapters/RenderCoordinator.swift` | правка: только coordinator/HostRenderRequest; без display/raster/animation; flush держит latest host state до свободного worker-slot, commit валидирует полный result; guard retry ограничен бюджетом | C14, C15 |
| `Tests/TrellisRenderTests/RenderCoordinatorTests.swift` | `Tests/AppKitAdapterTests/RenderCoordinatorTests.swift` | правка: platform-neutral tests normal/replaceRoot/post-commit/retry-recovery/burst cases без NSView и display pipeline | C14, C15 |
| `Sources/TrellisRender/LayerRenderer.swift` | `Sources/UIKitAdapter/UIKitLayerRenderer.swift`, `Sources/AppKitAdapter/AppKitLayerRenderer.swift` | правка: одна QuartzCore-копия geometry/reparent/order/cleanup; удалены Text/Image/Video, swipe, scroll-offset, artifact и animation ветки | C16 |
| `Sources/TrellisRender/VisualStyleRenderer.swift` | `Sources/WeaveAdapters/VisualStyleRenderer.swift` | правка: background/corner/border/shadow и semantic theme resolution без platform adapter | C16 |
| `Tests/TrellisRenderTests/LayerRendererTests.swift` | отсутствует | заново: голый CALayer покрывает parent-local geometry, identity, reparent/reorder, paint-only, scale и ownership cleanup | C16 |
| `Sources/TrellisRender/NodeHostBridge.swift` | `Sources/UIKitAdapter/UIKitAdapter.swift`, `Sources/AppKitAdapter/AppKitAdapter.swift` | правка: platform-neutral owner root/coordinator/renderer; atomic initial state, weak callback, single-host root ownership и detach cleanup | C17 |
| `Tests/TrellisRenderTests/NodeHostBridgeTests.swift` | отсутствует | заново: end-to-end голый CALayer путь, initial/coalesced host state, ownership/replacement/detach и suspend/resume | C17 |
| `Sources/TrellisUIKit/TrellisHostView.swift` | `Sources/UIKitAdapter/UIKitAdapter.swift` | правка: UIView обвязка NodeHostBridge, initial state, scene-filtered lifecycle, physical safe-area → logical edges; удалён ложный C02 registry | C18 |
| `Sources/TrellisAppKit/TrellisHostView.swift` | `Sources/AppKitAdapter/AppKitAdapter.swift` | правка: NSView bridge, wantsLayer/flipped, backing scale, window-filtered lifecycle и logical safe-area | C18 |
| `Tests/TrellisRenderTests/AppKitHostViewTests.swift` | отсутствует | заново: macOS NSView layer-backed/flipped асимметричная CALayer hierarchy | C18 |
| `docs/adr/0005-c18-host-bridge-api.md` | отсутствует | заново: breaking removal C02 layerRegistry и attach/detach API | C18 |
| `Playground/` | отсутствует | заново: multi-platform Xcode project (iOS/tvOS/macOS), shared scenarios S01–S15, fixedInput/nativeBounds modes | C19 |

Существующая `.swift-format` из C01 сохранена без изменений; C03 подключает
её к обязательному lint по Package.swift/Sources/Tests. Swift-файлы C02 и
их незакоммиченные изменения не менялись при реализации C03.

Правило: строка добавляется **в том же коммите**, в котором появляется файл.
Отдельного «прохода по документации» в конце не будет — он всегда делается
неточно.

## 3. Лицензии

### 3.1 Weave — источник переноса

**В репозитории Weave нет файла лицензии и нет копирайт-заголовков в исходниках**
(проверено: `ls Weave/` не содержит LICENSE/COPYING/NOTICE; `grep -rl
"Copyright\|SPDX\|Licensed under" Weave/Sources --include="*.swift"` не даёт
совпадений).

Это означает «все права защищены» по умолчанию. Для переноса препятствием не
является: Weave и Trellis принадлежат одному автору. Обязательств по notices
перенос не создаёт.

**Но это открытый вопрос для Trellis**, и его надо закрыть до первой публикации
пакета, а не после:

- [x] Выбрать лицензию Trellis и положить `LICENSE` в корень. → Выбрана лицензия MIT (`LICENSE`).
- [ ] Решить, нужны ли per-file заголовки (Weave обходится без них; если Trellis
      публикуется — обычно достаточно корневого `LICENSE`).
- [ ] Задним числом решить судьбу лицензии самого Weave, если он останется
      публичным репозиторием.

Публикация в C01 не требуется, поэтому пункт не блокирует работу — но и не
исчезает сам.

### 3.2 Texture — только справочник

`old/Texture` — Apache License 2.0, copyright Facebook, Inc. (до 2017-04-13) и
Pinterest, Inc. (после).

**Код Texture в Trellis не переносится.** Texture используется как источник
поведенческих решений и как объект сравнения — что именно оттуда взято как
*идея*, зафиксировано в `docs/weave-analysis.md`, разделы 5.1 и 5.2:

- модель «стиль как набор напрямую присваиваемых свойств» (`ASLayoutElementStyle`);
- guard «сеттер не будит layout, если значение не изменилось»
  (`ASLayoutElement.mm:244`);
- точка расширения «подкласс описывает раскладку детей»
  (`-layoutSpecThatFits:`), реализуемая в Trellis принципиально иначе — на
  MainActor до сборки снимка, а не в фоне под мьютексом.

Имена сознательно разведены (`arrangeSubnodes` вместо `layoutSpecThatFits`,
`Arrangement` вместо `LayoutSpec`) — см. таблицу переименований в §2.6
исторического черновика.

Правило на будущее: **ни одна строка из `old/Texture` не копируется в
`Trellis/Sources`.** Если понадобится алгоритм оттуда — сначала решение о
лицензии и notices, отдельной задачей, а не по ходу переноса.

### 3.3 flux — теперь SPM-зависимость `TrellisFlux` (R02)

`old/flux` (публичный `https://github.com/resoul/flux.git`) — MIT, copyright
resoul. Первого этапа (C01–C31) это не касалось: внешних зависимостей не было
(`Node.bind`, `Pipe`, `ActionPipe`, `NodeState` не переносились). С R02 (план 6,
P6.1) Flux — настоящая SPM-зависимость `TrellisFlux`, не перенос кода: пакет
подключён по `exact: "1.2.1"` (`Package.swift`), исходники Flux остаются в его
собственном репозитории и не копируются в `Trellis/Sources`. LICENSE Flux не
переносится в Trellis — он остаётся в дереве зависимости, которое SPM
разрешает отдельно; для дистрибуции с зависимостями см. обычную практику SPM
(`swift package show-dependencies`), отдельного шага в Trellis не вводится.

## 4. Происхождение солвера — закрыто

`Weave/Sources/WeaveUI/FlexSolver.swift` и `LayoutResult.swift` реализуют
раскладку по спецификации W3C Flexbox. Копирайт-заголовков в файлах нет.

**Автор подтвердил (2026-09-10): код написан им, а не адаптирован из Yoga,
Texture или другой реализации.** Спецификация W3C общедоступна, самостоятельная
реализация по ней обязательств не создаёт. Notices не требуются, перенос
ничем не ограничен.

Оба файла переносятся с правками, зафиксированными в
`docs/weave-analysis.md`: словарь placements вместо линейного поиска (3.1),
разделение measure/placement по файлам, `throws`/`LayoutContext`/checkpoints
(3.13, D09/D10). Геометрические ожидания завершившихся расчётов сохраняются;
имя типа меняется на `FlexboxEngine` — см. [decisions.md](decisions.md), D11.

## 5. Структура репозитория

Решение записано в [decisions.md](decisions.md), раздел «Репозиторий».
Коротко: `Trellis/` — самостоятельный git-репозиторий рядом с `Weave/`,
общего родительского репозитория не заводится.

## 6. Расхождения для будущего переноса focus/accessibility

Зафиксировано 2026-09-11 при подготовке
[implementation-plan-3.md](implementation-plan-3.md), без изменения Weave и
без переноса файлов. Это результаты чтения, не отчёт о выполненных тестах.

- `WeaveUI/Focus.swift`: последовательную навигацию и tie-break переписать
  (W02, [defects.md #33](defects.md), A04); strong focusedNode и потерю
  previous/focusOut при unregister устранить identity-based переходом
  (W03, #34, A04–A05). Flux output не переносить.
- `WeaveUI/Accessibility.swift`: определить и реализовать различающиеся
  combine/ignoreSelf/contain (W05, #35, A06); не переносить дублирование
  value/selected/disabled из нескольких полей без единого источника.
- `UIKitAdapter/UIKitAdapter.swift` и `AppKitAdapter/AppKitAdapter.swift`:
  accessibility bridge хранит snapshot и уведомляет ОС; создание native
  elements и action routing реализуются заново в A09/A10, а не объявляются
  перенесённой готовой функциональностью.

Фактические строки происхождения целевых файлов будут добавлены в §2 вместе
с реализацией соответствующих карточек; этот список их не заменяет.

## 7. Расхождения для будущего переноса текста (N01)

Зафиксировано 2026-09-12 при подготовке
[implementation-plan-4.md](implementation-plan-4.md), без изменения Weave и
без переноса файлов. Результаты чтения, не отчёт о выполненных тестах.

- `WeaveUI/Text.swift`: value-типы (`TextStyle`, `TextTruncation`, `TextLayoutInput`,
  `TextMetrics`) переносимы; `TextLayoutBackendRegistry` (глобальный реестр) и
  `TextNode.setLayoutInputs` с хранимым constraint (W04/W05) не переносятся —
  измеритель приходит через environment и вызывается solver'ом (D49/D51);
  `renderedText` не переносится (#37); fallback-модель — только для тестов (#40).
- `WeaveAdapters/CoreTextRasterRenderer.swift`: растеризация зрелая, переносится в
  `TrellisRender`; измерение переписывается по `CTLine` (#36, #38), locale и
  `.exact`/`.atMost` (#39); системный шрифт — `CTFontCreateUIFontForLanguage`, не
  `Helvetica`.
- `WeaveAdapters/DisplayPipeline.swift`: `DisplayScheduler`/`DisplayTransaction`
  переносятся; валидация artifact — по committed snapshot, не `findNode` (W06);
  `CGImage` в `Sendable` artifact заменяется на `Data`-bitmap (W07/D54).
- `WeaveAdapters/RenderCoordinator.swift` display-часть: `scheduleDisplayPasses` по
  всему дереву на каждый commit не переносится — только для нод с изменившимся
  `(contentRevision, geometryGeneration, scale)` (D52).

Фактические строки происхождения целевых файлов добавляются в §2 вместе с
реализацией соответствующих карточек.

## 8. Расхождения для будущего переноса анимации коммита

Зафиксировано 2026-09-12 при подготовке
[implementation-plan-5.md](implementation-plan-5.md), без изменения Weave и
без переноса файлов.

- `WeaveUI/Animation.swift`: `Animation`/`AnimationCurve` (без `.spring`, #41) и
  `Duration.timeInterval` переносимы; `AnimationContext` (ambient global) не
  переносится — анимация живёт в pending window корня (D62); `Transition`,
  `TransitionSession` (таймерный completion, W04) не переносятся — N07.
- `WeaveAdapters/RenderCoordinator.swift`: перенос анимации в `HostRenderRequest`
  и её сохранение при retry — переносится по духу (D62); правило смешения в окне
  формулируется заново (W03/D63).
- `AppKitAdapter/AppKitLayerRenderer.swift:33-52, 115-140`: transaction-level
  actions и snap растровых слоёв — в единый `LayerRenderer` (D64/D65) без
  проверки типов нод Core; paint-only путь получает анимацию (W06).
- `WeaveUI/Theme.swift:125`: `reduceMotion` — вместо поля темы environment-ключ,
  читаемый хостами из системы (D67).

## R01 — отдельный аудит Flux (2026-09-14)

Источник: `../old/flux`, MIT © 2026 resoul, remote
`https://github.com/resoul/flux.git`, release 1.2.0, revision
`7e98033b26e793e36f3902fdc073f5d26969f6c6`. Remote tag сверён через
`git ls-remote`. Checkout чистый; Flux и Weave не изменялись.

| Файлы Trellis | Источник | Характер | Карточка |
|---|---|---|---|
| `Scripts/check_flux_foundation.py`, `docs/validation/r01-flux/Hooks.swift`, `docs/validation/r01-flux/FoundationAudit.swift` | отсутствует; Flux API и исходники исследованы | написаны заново: runner/scheduling hooks/characterization tests; временный git archive сохраняет LICENSE; runtime Flux не переносился в Trellis | R01 |

Результаты, instrumentation и открытые дефекты —
[R01](validation/r01-flux-foundation.md). Подключение и выбор исправленного pin — R02.

## R02 — TrellisFlux и pinned Flux 1.2.1 (2026-09-14)

Дефекты #56–#59 исправлены во внешнем репозитории Flux (не в этом дереве):
commit [`e99f664`](https://github.com/resoul/flux/commit/e99f664), release
[1.2.1](https://github.com/resoul/flux/releases/tag/1.2.1). Trellis подключает
Flux как обычную SPM-зависимость (`Package.swift`, `exact: "1.2.1"`) — исходники
Flux не копируются в этот репозиторий.

| Файлы Trellis | Источник | Характер | Карточка |
|---|---|---|---|
| `Sources/TrellisFlux/TrellisFlux.swift` | отсутствует | написано заново: module-graph boundary, `@_exported import Flux` | R02 |

## R03 — `FluxStateBinding` (2026-09-14)

| Файлы Trellis | Источник | Характер | Карточка |
|---|---|---|---|
| `Sources/TrellisFlux/FluxStateBinding.swift` | отсутствует; построено поверх `Sources/TrellisRender/StateBinding.swift` (D14, C29) | написано заново: pump `Flux<Value>` → `StateSubject`, без изменений в TrellisRender | R03 |

## R04 — `EffectOwner` (2026-09-14)

| Файлы Trellis | Источник | Характер | Карточка |
|---|---|---|---|
| `Sources/TrellisFlux/EffectOwner.swift` | отсутствует | написано заново: keyed effect ownership поверх обычного `Task`, без зависимости от Flux/сети | R04 |

## R05 — Внешний consumer, `hostBridge` (2026-09-14)

| Файлы Trellis | Источник | Характер | Карточка |
|---|---|---|---|
| `Sources/TrellisAppKit/TrellisHostView.swift`, `Sources/TrellisUIKit/TrellisHostView.swift` (`hostBridge`) | отсутствует | написано заново: геттер существующего внутреннего моста, без новых зависимостей | R05 |
| `Playground/Shared/Scenarios/S32_FluxFilterFeed.swift` | отсутствует | написано заново: внешний consumer поверх R02–R04 | R05 |
| `Tests/TrellisFluxTests/ExternalConsumerFeedTests.swift` | отсутствует | написано заново: та же форма, что S32, но автоматический тест с реальным временем | R05 |
