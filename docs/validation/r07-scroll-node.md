# R07 — ScrollNode и viewport pipeline

Дата: 2026-09-16. Карточка [implementation-plan-6.md](../implementation-plan-6.md)
§5, R07. Зависимость: R06.

## Спецификация на реализованном контракте

Реализует [r06-scroll-api-sketch.md](r06-scroll-api-sketch.md) (P6.3 контракт),
[scroll-configuration.md](../scroll-configuration.md) (`ScrollConfiguration`) и
архитектуру из [r06-scroll-arbitration-comparison.md](../r06-scroll-arbitration-comparison.md)
(одна `UIScrollView`/`NSScrollView` на узел, не relay). Полное обоснование
каждого отклонения от sketch — в [ADR 0026](../adr/0026-scroll-node-viewport.md).
Коротко: `ScrollNode` (`TrellisCore`) — открытый класс-контейнер, `.scroll`
overflow по умолчанию, держит `configuration: ScrollConfiguration` и последнее
опубликованное `state: ScrollState`. `NativeScrollBacking`/
`NativeScrollBackingDelegate`/`ScrollCommandIssuing` (`TrellisRender`) —
адаптерная граница, симметричная существующей `TextRenderer` (D51).
`NodeHostBridge` реализует и `ScrollCommandIssuing`, и
`NativeScrollBackingDelegate`; хранит pending-completion таблицу, per-node
phase/revision. `UIScrollViewBacking`/`NSScrollViewBacking` — конкретные
backing'и в `TrellisUIKit`/`TrellisAppKit`, каждый создаёт настоящий native
scroll view как прямой subview host-view, позиционированный в host-absolute
координатах через `setFrame(_:)`.

## Design-решения

### Offset-aware hit-test — D18 нейтрально к глубине вложенности

`HitTest.swift`'s `hit(_:at:)`/`contains(_:node:)` применяют offset
`.scroll`-узла (из `HitTestSnapshot.scrollOffsets`) на своём собственном
уровне рекурсии, до спуска к детям — не через отдельный «find nearest scroll
ancestor» проход. Значит вложенные `ScrollNode` с разными offset'ами
композируются автоматически, без специального кода для глубины.
`test_hitTest_d18NearestAncestorRoutingForNestedScrollNodes`,
`test_hitTest_scrollNodeOffsetCombinesWithAncestorTransform`
(`Tests/TrellisRenderTests/ScrollNodeHitTestTests.swift`).

### `HitTestSnapshot.withScrollOffsets(_:)` — offset-only без пересбора снимка

`scrollOffsets` — хранимое поле, не пересчитываемое из дерева; на каждый
native offset-тик `NodeHostBridge.scrollBacking(for:didChangeOffset:phase:)`
делает `hitTestSnapshot.withScrollOffsets(merged)` — копия структуры с тем же
`records`, только новой таблицей offset'ов. `capture(_:parent:into:)` (полный
обход дерева) не вызывается. Это конкретный смысл «offset-only путь» из
чек-листа: `test_hitTest_offsetOnlyTickDoesNotRequestANewLayoutSnapshot`
проверяет и `layoutSnapshotCount`, и `committedCount` неизменными после трёх
native offset-тиков подряд, при этом `hitTestSnapshot.scrollOffsets`
корректно обновлён.

### `ScrollCommandIssuing` — resolution order буквально по sketch §7/§9

`NodeHostBridge.scroll(_:on:completion:)`: supersede pending → notAttached
(нет backing'а) → cancelledByUserInput (уже `isUserDriven`) → синхронный
`.completed` без native-вызова, если target offset уже равен текущему
(scenario 6) → иначе native `scroll(to:animated:completion:)` с pending slot.
Каждый из 8 сценариев `r06-scroll-api-sketch.md` §10, применимых к
geometry/commands (не к реальному touch-вводу — это R08), покрыт тестом:

| # | Сценарий | Тест |
|---|---|---|
| 1 | ScrollNode вложен на глубине N | `test_scrollNode_embedsARealUIScrollViewAsADirectSubviewOfTheHost`, AppKit-аналог |
| 2 | Drag во время programmatic-анимации | `test_scrollCommand_userInputInterruptsAPendingAnimatedCommand` |
| 3 | Два `scroll(...)` подряд | `test_scrollCommand_secondCommandSupersedesTheFirstSynchronously` |
| 4 | Insets меняются во время `.decelerating` | не покрыт — см. «Открытые пункты» |
| 5 | `flexGrow`/`.fraction` вдоль scroll-оси | частично: `flexGrow` больше не растягивает ребёнка до viewport'а (`test_flexboxEngine_scrollOverflowMainAxisChildDoesNotGrowToFillContainer`); `.fraction`-размер вдоль scroll-оси по-прежнему резолвится против реального `availableMain` в `measure()`'s `bases`-проходе (не задет этой правкой — она меняет только `resolveLines`'s grow/shrink delta, не basis-вычисление), то есть диагностика `Log.on(.measure, …)` для `.fraction` вдоль scroll-оси не добавлена — см. «Открытые пункты» |
| 6 | `reveal` уже видимой ноды | `test_scrollCommand_revealAlreadyVisibleCompletesSynchronouslyWithoutMovement` |
| 7 | `detach()` во время pending completion | `test_scrollCommand_pendingCompletionResolvesNotAttachedOnDetach` |
| 8 | hit-test сразу после programmatic scroll, до коммита `ScrollState` | `test_hitTest_pointInsideScrollNodeViewportHitsTheChildAtCurrentOffset` (читает `backing.contentOffset` напрямую через `HitTestSnapshot.scrollOffsets`, не устаревший `ScrollState`) |

### `setFrame(_:)` вместо прямой записи в `containerLayer`

Найдено при написании `AppKitScrollNodeEmbeddingTests.swift`: `UIView`/`NSView`'s
`frame` — независимая от `CALayer`'s `bounds`/`position` бухгалтерия;
нативный hit-testing (touch/mouse) читает `frame`, не слой напрямую. Первая
версия `LayerRenderer.updateScrollBackedNode` писала `containerLayer.bounds`/
`.position`, что визуально выглядело верно, но `NSScrollView.frame` не
обновлялся при resize — `test_scrollNode_resizingTheHostUpdatesTheNativeViewportSize`
поймал расхождение (см. `docs/defects.md` #66, #67 — оба зарегистрированы и
исправлены до конца этой карточки). Решение: `NativeScrollBacking.setFrame(_:)`
— новый protocol requirement, адаптер реализует через `scrollView.frame = ...`.

### Content union — прямые дети, не рекурсивно

`LayerRenderer.scrollContentSize(of:viewportFrame:)` — максимум по committed
frame'ам прямых детей `ScrollNode`. Этого достаточно для формы «одна
прокручиваемая колонка», которую R07's тесты проверяют, и не предвосхищает
виртуализацию (P6.4/R10, sketch §11) — материализация только прямых детей, не
рекурсивное поддерево, остаётся такой же формой, когда P6.4 представит
materialized window.

### `.unspecified`-constraint вдоль scroll-оси — закрыто (было открытым пунктом)

`r06-scroll-api-sketch.md` §2 специфицировал: продольная (прокручиваемая) ось
`ScrollNode` — `.unspecified` на измерении контента, тот же max-content basis,
что ADR 0009 уже использует для auto-sized контента. Реализовано в
`FlexboxEngine.resolveLines` (`Sources/TrellisCore/Layout/FlexboxMeasure.swift`):
`overflow == .scroll` на контейнере делает `scrollableMain` (внутренняя замена
`availableMain` для расчёта grow/shrink delta и wrap line-breaking внутри
`resolveLines`) равным `nil`, то есть `delta == 0` для каждой линии — дети
сохраняют свой natural (max-content) main size вместо сжатия/растяжения
default `flexGrow`/`flexShrink`. Cross-ось (`availableCross`) не тронута —
поперечное `alignItems: .stretch` работает как обычно. Контейнер собственный
измеренный размер (`input.style.width`/`height`) тоже не тронут — меняется
только распределение среди детей, не размер самого `ScrollNode`.

Область действия — любой `overflow == .scroll` контейнер, не только класс
`ScrollNode`: единственный сигнал, доступный чистому value-снимку
`LayoutInputSnapshot` в `TrellisCore` (никакой информации о классе `Node` там
нет), — это `style.visual.overflow`, который `ScrollNode.init` уже
устанавливает в `.scroll` по умолчанию. Регрессия для НЕ-scroll контейнеров
исключена явными тестами
(`test_flexboxEngine_nonScrollOverflowStillShrinksToFitContainer_regression`,
`test_flexboxEngine_defaultOverflowVisibleStillShrinksAndGrowsAsToday_regression`) —
`.hidden`/`.visible` контейнеры продолжают сжимать/растягивать детей как
раньше. Все `flexShrink = 0` обходные пути, которые `ScrollNodeHitTestTests.swift`/
`AppKitScrollNodeEmbeddingTests.swift`/`UIKitScrollNodeEmbeddingTests.swift`
использовали для «длинного контента», убраны — тесты проходят на реальном
`ScrollState.contentSize`, вычисленном из natural child size, без единой
ручной поправки.

Тесты (`Tests/TrellisCoreTests/Layout/FlexboxAlgorithmTests.swift`, если не
указано иное):

| Тест | Что проверяет |
|---|---|
| `test_flexboxEngine_scrollOverflowMainAxisChildKeepsNaturalSizeInsteadOfShrinking` | Одиночный ребёнок (900) в scroll-контейнере (200) не сжимается |
| `test_flexboxEngine_scrollOverflowMainAxisMultipleChildrenAllKeepNaturalSize` | Два ребёнка (300+300) в scroll-контейнере (200) — оба сохраняют natural size |
| `test_flexboxEngine_scrollOverflowMainAxisChildDoesNotGrowToFillContainer` | Короткий ребёнок (50) с `flexGrow: 1` не растягивается до viewport'а (200) |
| `test_flexboxEngine_scrollOverflowCrossAxisIsStillBoundByTheContainer` | Поперечная ось (`layoutContainer`, placement) по-прежнему `alignItems: .stretch` |
| `test_flexboxEngine_nonScrollOverflowStillShrinksToFitContainer_regression` | `.hidden` контейнер продолжает сжимать (регрессия) |
| `test_flexboxEngine_defaultOverflowVisibleStillShrinksAndGrowsAsToday_regression` | Default `.visible` — и shrink, и grow работают как раньше (регрессия) |
| `test_flexboxEngine_scrollOverflowRowDirectionAlsoKeepsNaturalWidth` | Ось следует за `flexDirection`, не хардкод "вертикаль" (row-scroll) |
| `test_layoutContainer_scrollOverflowStacksChildrenPastTheContainersOwnFrame` (`FlexboxPlacementTests.swift`) | На уровне итогового placement, не только measurement: второй ребёнок размещается за пределами committed frame контейнера — именно то, что делает контент прокручиваемым |

Реальный effect через полный pipeline, без `flexShrink` workaround:
`test_scrollNode_contentSizeForLongContentIsTheChildUnionBeyondTheViewport`
(`ScrollNodeHitTestTests.swift`, fake backing) и
`test_scrollNode_embedsARealUIScrollViewAsADirectSubviewOfTheHost`/AppKit-аналог
(реальный `NSScrollView.contentSize`/`documentView.frame`) — все прошли без
единого `flexShrink = 0` на детях после этой правки.

### `NativeScrollBacking` — flat top-level subview, не вложенный `CALayer`

Sketch §4 предполагал вставку backing'а в тот же sublayer-слот, что обычный
слой узла. Реализация: адаптер добавляет native view прямым subview host-view,
позиционированным в host-absolute координатах (committed `frame` уже
root-absolute). Верно для позиции независимо от глубины; **не** применяет
clip/transform предков ScrollNode композиционно к самому native view — открытый
пункт, не скрытый (см. ниже).

## Найденное при написании тестов/реализации (не гипотеза)

- **Дефект #66** (`docs/defects.md`): обобщённая по-commit запись

### `NativeScrollBacking` — flat top-level subview, не вложенный `CALayer`

Sketch §4 предполагал вставку backing'а в тот же sublayer-слот, что обычный
слой узла. Реализация: адаптер добавляет native view прямым subview host-view,
позиционированным в host-absolute координатах (committed `frame` уже
root-absolute). Верно для позиции независимо от глубины; **не** применяет
clip/transform предков ScrollNode композиционно к самому native view — открытый
пункт, не скрытый (см. ниже).

## Найденное при написании тестов/реализации (не гипотеза)

- **Дефект #66** (`docs/defects.md`): обобщённая по-commit запись
  `layer.bounds = CGRect(x:0,y:0,...)` обнуляла бы `contentOffset` (который
  физически хранится в `bounds.origin` на `UIScrollView`/`NSScrollView`) на
  каждом несвязанном коммите — тот же класс бага, что дефект #63 нашёл в
  Weave. Найден инспекцией кода до прогона тестов, исправлен тем же
  коммитом, затем полностью заменён решением дефекта #67.
- **Дефект #67** (`docs/defects.md`): прямая запись в `containerLayer`
  оставляла `NSScrollView.frame`/`UIScrollView.frame` устаревшими —
  реальный, пойманный тестом баг (`test_scrollNode_resizingTheHostUpdatesTheNativeViewportSize`),
  не гипотетический. Исправлен добавлением `setFrame(_:)` в протокол.
- Тестовая инфраструктура (не дефект продукта, тот же класс проблемы, что R04
  зафиксировала для `ControllableRequests`): `NodeHostBridge(hostLayer: CALayer())`
  с временным литералом ломает второй и последующие коммиты, потому что
  `hostLayer` — `weak`; исправлено удержанием host layer внутри
  `FakeScrollBackingRegistry`, тем же способом, каким существующие тесты уже
  держат `host` локальной переменной (`NodeHostBridgeTests.swift`).

## Тесты

`Tests/TrellisCoreTests/Layout/FlexboxAlgorithmTests.swift` (+7) и
`Tests/TrellisCoreTests/Layout/FlexboxPlacementTests.swift` (+1) — `.unspecified`-constraint
вдоль scroll-оси, таблица тестов и регрессионное покрытие в design-разделе
выше «`.unspecified`-constraint вдоль scroll-оси — закрыто».

`Tests/TrellisCoreTests/ScrollStateTests.swift` — 21 тест: clamp (обе оси
независимо, отрицательный offset, пустой/короткий контент, идемпотентность),
конверсия viewport↔content (round-trip), `visibleContentFrame` — чистая
геометрия, `revealOffset` для всех 4 alignment (включая nearest-no-op и
minimal-move в обе стороны), clamp результата reveal, direction-agnostic
формула (закрывает «incl RTL» — обоснование в тесте), `ScrollConfiguration`
default'ы, `ScrollNode` default overflow/state/publish, `ScrollCommandToken`/
`ScrollCommandOutcome` equality.

`Tests/TrellisRenderTests/ScrollNodeHitTestTests.swift` — 16 тестов (фейковый
`NativeScrollBacking`, без реального UIKit/AppKit): materialization/registry
wiring (4), offset-aware hit-test + D18 (3), `ScrollCommandIssuing` — все
терминальные исходы (7), offset-only path без layout snapshot (1),
reveal-partially-visible с точным числовым результатом (1).

`Tests/TrellisRenderTests/AppKitScrollNodeEmbeddingTests.swift` — 6 тестов,
реальный `NSScrollView` через `TrellisHostView`: nested embedding,
empty/short content, resize, `reveal` через реальный `NSScrollView`, content
insets. Прогнаны и зелёные в этой сессии (macOS доступен).

`Tests/TrellisRenderTests/UIKitScrollNodeEmbeddingTests.swift` — 6 тестов,
зеркало AppKit-набора для `UIScrollView`. Компилируется (`#if canImport(UIKit)`
компилирует пусто на macOS, ошибок сборки под iOS SDK нет по чтению кода), но
**не прогнан** в этой сессии — нет iOS Simulator/SDK (см. «Проверки»).

## Проверки

| Проверка | Результат |
|---|---|
| `swift build` (весь пакет, macOS) | чисто |
| `swift test` (весь пакет, дважды подряд, после `.unspecified`-фикса) | 782/782 тестов зелёные оба раза (293 TrellisRenderTests + 28 TrellisFluxTests + 461 TrellisCoreTests; было 774 — 8 новых flex-теста: 7 в `FlexboxAlgorithmTests.swift` + 1 в `FlexboxPlacementTests.swift`, `ScrollNodeHitTestTests.swift`'s 16 тестов не изменились в числе, только избавились от `flexShrink = 0`) |
| `python3 Scripts/check_policy.py` | 0 diagnostics |
| `python3 Scripts/check_api.py --update --review-note docs/adr/0026-scroll-node-viewport.md` | **не выполнено** — см. ниже (повторная попытка после `.unspecified`-фикса, тот же результат) |
| `python3 Scripts/check_all.py --matrix` | **не выполнено** — см. ниже |

**`check_api.py`, честно:** `build_macos_modules` ожидает продукты сборки в
`.build/arm64-apple-macosx/debug/Modules` (конвенция более старого SwiftPM
layout); в этой сессии (`swift-driver version 1.168.6`, Apple Swift 6.4,
только Command Line Tools без полного Xcode) `swift build` кладёт продукты в
`.build/out/...` независимо от того, как их запускает check_api.py (напрямую
через `xcrun --sdk macosx swift build`, без явного `--build-path`) — путь,
которого сам check_api.py не ищет. Это несоответствие окружения/тулчейна, не
следствие правок R07: `swift build`/`swift test` работают штатно тем же
самым способом что и раньше в этом репозитории. Чинить `Scripts/check_api.py`
под новый layout — вне периметра файлов этой карточки и рискует сломать
конвенцию для других карточек без отдельного обсуждения. **API baseline
(`api/TrellisCore.json`, `api/TrellisRender.json`, `api/TrellisAppKit.json`,
`api/TrellisUIKit.json`) не обновлён этой сессией** — открытый пункт, не
скрытый.

**`check_all.py --matrix`, честно:** требует реальный iOS/tvOS Simulator
через `xcodebuild` — `xcrun --sdk iphonesimulator --show-sdk-path` возвращает
«SDK cannot be located» в этом окружении (только Command Line Tools
установлены, `/Applications/Xcode.app` не сконфигурирован как active
developer directory). Недоступно, не пропущено молча — то же самое для
`UIKitScrollNodeEmbeddingTests.swift`'s реального прогона.

## Открытые пункты

Явная граница из плана (не пробел этой карточки, вынесено намеренно):

- **R08** — реальный touch/trackpad/wheel input (iPadOS hover/pointer, tvOS
  focus, AX actions, resize во время активного жеста, cancel-by-user-input
  живьём). Зависимость на этой карточке.
- **R09** — арбитраж вложенного скролла (direction lock между parent/child
  ScrollNode). `test_hitTest_d18NearestAncestorRoutingForNestedScrollNodes`
  проверяет geometry-композицию двух вложенных ScrollNode, не арбитраж
  жеста между ними — они программно управляются тестом, не борются за один
  реальный жест.
- **P6.7/R10+** — `edgeLoad`, per-item visibility/demand, виртуализация.
- **R15** — числовые бюджеты.

Найденные этой карточкой, не предусмотренные исходным планом:

- **`.unspecified`-constraint вдоль scroll-оси — закрыто** (было открытым
  пунктом до 2026-09-16): реализовано в `FlexboxEngine.resolveLines`
  (`Sources/TrellisCore/Layout/FlexboxMeasure.swift`), см. design-раздел выше
  «`.unspecified`-constraint вдоль scroll-оси — закрыто». `ScrollState.contentSize`
  теперь реально превышает `viewportSize` для контента длиннее viewport'а без
  единого `flexShrink = 0` на детях.
- **`.fraction`-размер вдоль scroll-оси без диагностики** — оставшаяся часть
  сценария 5: `.fraction` (не `flexGrow`) вдоль scroll-оси по-прежнему
  резолвится против реального `availableMain` в `measure()`'s basis-проходе
  (`bases` в `FlexboxMeasure.swift`), не в `resolveLines`, которую эта правка
  меняла — то есть значение не «0 с диагностикой», как sketch §2 описывал для
  этого случая, а обычное процентное значение от реального viewport'а.
  Не покрыто тестом; требует отдельной правки basis-вычисления и
  `Log.on(.measure, …)`, не сделанной здесь, чтобы не расширять периметр
  правки, о которой попросили, за пределы delta/grow-shrink механики.
- **Сценарий 4** (`contentInsets` меняется во время `.decelerating`, clamp-with-anchor) —
  не тестирован: требует реального momentum в полёте, которого fake backing
  не моделирует, а реальный embedding-тест не может детерминированно поймать
  «во время deceleration» без реального run loop/времени. Кандидат для R08.
- **Clip/transform предков ScrollNode не применяется к native view
  композиционно** — backing позиционируется в host-absolute координатах
  (верно для позиции независимо от глубины), но если предок ScrollNode сам
  клипует (`overflow: .hidden`) или трансформирован, native scroll view не
  наследует этот clip/transform визуально. Не покрыто тестом; открытый архитектурный
  пункт для любой карточки, которой это понадобится (вероятно R09/R13/R14 —
  `TabbedScrollNode` композиция).
- **AppKit's `ScrollPhase` не различает `.decelerating` от `.dragging`** —
  AppKit не даёт отдельного колбэка для trackpad-momentum после отпускания;
  `NSScrollViewBacking` репортит весь live-scroll период (drag + momentum)
  как `.dragging`. Задокументировано в самом файле; уточнить в R08, если
  окажется важным для UI, реагирующего на фазу.
- **`ScrollCommand` без `.cancel`** — Weave's исходный контракт имел
  `.cancel` как отдельный кейс команды; sketch §7 не специфицировал его явно
  (только outcomes). Не добавлен — намеренное упрощение периметра, не
  найденный пробел; арбитраж/отмена вложенного скролла (где `.cancel` мог бы
  быть нужен) — явно R09.
- **API baseline не обновлён** (`api/*.json`) — см. «Проверки».
- **`check_all.py --matrix`/UIKit-набор не прогнаны на Simulator** — см.
  «Проверки»; iOS SDK недоступен в этой сессии.
