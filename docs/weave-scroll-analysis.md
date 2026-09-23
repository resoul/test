# Weave → Trellis: Scroll и Collections — дополнение к weave-analysis.md

Дополнение к [weave-analysis.md](weave-analysis.md), заказанное
[implementation-plan-6.md](implementation-plan-6.md) §3.1 для карточки R06
(и потребляемое R10 для §P6.4/P6.9/P6.11). weave-analysis.md §4 (`Sources/WeaveUI`
→ `Sources/TrellisCore`) на дату этапа 1 отметил `Scroll.swift`, `Collections.swift`
как «**НЕ БРАТЬ** — этап 3+»; этот документ — тот самый разбор, отложенный туда.
Как и исторический анализ, документ не заменяется текущей архитектурой Trellis;
статус написан на дату разбора ниже.

Прочитан **весь** код обоих файлов и проводка их вызовов в обоих платформенных
адаптерах, а не выборочные фрагменты. Weave не изменяется этим разбором.

## 1. Источник и охват

- Repository: `/Users/resoul/projects/v2/Weave`, revision `17da6266` (2026-09-09,
  тот же checkout, что использовал исторический weave-analysis.md).
  `Sources/WeaveUI/Scroll.swift` и `Sources/WeaveUI/Collections.swift` не менялись
  с коммита `eb7f054` («weave release candidate»).
- Лицензия: в репозитории `Weave` нет файла `LICENSE`; репозиторий принадлежит
  тому же владельцу, что и `Trellis` и `../old/flux` (см. R01/R02) — тот же режим,
  без отдельного provenance-риска по авторству.
- Плановый файл `ScrollContentView.swift` (упомянутый в implementation-plan-6.md §3
  как отдельный источник) **не существует** в этом checkout — по коду и `git log`
  весь контракт viewport/scroll живёт в одном `Scroll.swift` (582 строки); нет
  файла с таким именем ни в `WeaveUI`, ни где-либо ещё в дереве. План 6 будет
  ссылаться на `Scroll.swift` за обе роли (core state + adapter-facing протокол
  `EdgePullContainer`).
- Разобранные тесты: `Tests/WeaveBootstrapTests/ScrollTests.swift` (76 строк, 2
  `@Test`), `Tests/WeaveBootstrapTests/CollectionsTests.swift` (наличие проверено,
  подробный список кейсов не потребовался — ни один из них не покрывает нативную
  прокрутку, см. §4).
- Проводка адаптеров разобрана по `grep`+чтению обоих файлов целиком:
  `Sources/UIKitAdapter/UIKitAdapter.swift`, `Sources/UIKitAdapter/UIKitLayerRenderer.swift`,
  `Sources/AppKitAdapter/AppKitAdapter.swift`, `Sources/AppKitAdapter/AppKitLayerRenderer.swift`.

## 2. `Scroll.swift` — символы и контракт

Один файл, платформо-нейтральный (`import Foundation` only), 582 строки.
Публичные типы, в порядке объявления:

| Символ | Роль |
|---|---|
| `ScrollAxis` | `.vertical`/`.horizontal`/`.both` |
| `ScrollAlignment` | `.nearest`/`.start`/`.center`/`.end` для reveal |
| `ScrollState` | offset/contentSize/viewportSize/isScrolling/revision — Sendable snapshot |
| `ScrollCommand` | `.by`/`.to`/`.reveal`/`.cancel` |
| `ScrollContentEdge`, `EdgePullBehavior`, `EdgePullConfiguration`, `EdgePullIndicator`, `EdgePullState`, `EdgePullRequest` | pull-to-refresh/edge-load контракт, elastic vs action |
| `EdgePullContainer` (протокол, `@MainActor`) | адаптерная граница для edge pull — `beginEdgePull`/`updateEdgePull`/`finishEdgePull`/`cancelEdgePull` |
| `VisibilityContext`, `ViewportDemandPriority`, `ViewportDemand` | видимость/приоритет подготовки по item ID, bounded generation |
| `ScrollArbitration`, `ScrollGestureRequest` | арбитраж вложенного скролла: `.claim`/`.deferToChild`/`.deferToParent` |
| `ScrollNode` (класс, `@MainActor`, `open class ... : Node, EdgePullContainer`) | сам контейнер |

`ScrollNode` — единственный держатель состояния: `state: ScrollState`,
4 `ActionPipe` (`stateChanges`, `visibilityChanges`, `demandRequests`,
`edgePullRequests`), приватные `visibleIDs`/`visibilityRevision`/`edgePull*`.
Все публичные мутирующие методы (`scroll(_:)`, `moveBy`, `reveal`,
`scrollToLeadingOffset`, `updateViewport`, `updateVisibleFrames`, `arbitrate`,
`cancelScroll`, `beginEdgePull`/`updateEdgePull`/`finishEdgePull`/`cancelEdgePull`)
проходят через один приватный `commit(offset:viewportSize:contentSize:isScrolling:)`,
который: клэмпит offset в `[0, contentSize - viewportSize]` по обеим осям
независимо, инкрементирует `revision` на **каждый** вызов (включая чистый
offset-тик), шлёт `ScrollState` в `stateChanges`, дергает
`rootNode.onScrollStateChanged?(self)` (host callback, не Flux) и — только если
`viewportSize`/`contentSize` реально изменились — зовёт `setNeedsLayout()`.
Это уже даёт нужный контракт «offset-тик не запускает layout»: `setNeedsLayout()`
вызывается по геометрии контейнера, не по каждому scroll-commit — совпадает с
требованием P6.3 «Изменение только offset не запускает полный layout/raster».

Видимость (`updateVisibleFrames`) — синхронный проход по `subnodes` с
`intersectionRatio` (AABB intersection / area), `entered`/`left` колбэки на
детях с генерацией, инвалидируемой на каждый вызов; `demandRequests` шлёт
только `.visible` приоритет отсюда — `.near`/`.prefetched` в этом файле никто
не производит (это делает `VirtualizedView.updateRenderedWindow` в
Collections.swift, §3).

Edge pull — отдельная state machine (`idle → pulling → armed → active →
settling`/`cancelled`), с resistance/threshold/maximumDistance по
`EdgePullConfiguration`; `action`-режим шлёт ровно один `EdgePullRequest` на
release после threshold, `elastic`-режим никогда не шлёт запрос. Раздельные
`startEdgePull`/`endEdgePull` на обеих осевых границах.

`arbitrate(_:)` — чистая функция без побочных эффектов: сравнивает `deltaX/Y`
с `nestedThreshold` (default 2pt), учитывает `targetsControl` (двойной порог,
чтобы жест на контроле внутри скролла не перехватывался слишком рано), и
возвращает `.claim`/`.deferToChild`/`.deferToParent` в зависимости от
`canScrollHorizontally`/`canScrollVertically` (есть ли ещё куда двигаться).
Это единственное место во всём Weave, где формализован «relay vs claim» вопрос,
который implementation-plan-6.md §1.1.1 поднимает через Telegram/TabBarPager —
но здесь он решает только *одноуровневую* пару родитель/потомок, синхронно и
без knowledge о native gesture recognizer state machine (см. §4).

## 3. `Collections.swift` — символы и контракт

Один файл, зависит от `Flux` (`import Flux`) — **единственная точка во всей
проанализированной части WeaveUI**, где реактивный рантайм связан прямо в
базовый тип (`CollectionDataSource.snapshots: Flux<...>`). 1190 строк.

| Символ | Роль |
|---|---|
| `ItemContext`, `CollectionItem`, `CollectionSection`, `CollectionSnapshot` | Sendable identity/snapshot модель, `flattened` для плоского обхода |
| `SwipeActionStyle`, `SwipeEdge`, `SwipeAction`, `SwipeActionsConfiguration`, `SwipeActionInvocation`, `SwipeRevealState`, `SwipeRevealUpdate`, `SwipeRevealContainer` (протокол) | P6.6 swipe-actions контракт целиком уже здесь, включая full-swipe/threshold/velocity |
| `CollectionDataSource` (протокол, требует `Flux<CollectionSnapshot<...>>`) | единственная точка входа данных |
| `VirtualizationWindow` | visible+overscan range, две статические `compute` перегрузки (uniform estimate vs известные `itemLengths`) |
| `CellReusePool`, `ReusableNode`, `KeyedItemStateStore`, `ItemDemand` | reuse-пул по `reuseID` (не по item ID), keyed-state с demand-токеном (тот же паттерн владения, что уже принят в `EffectOwner`, R04) |
| `SelectionMode`, `CollectionContentState`, `CollectionContextMenu*` | вспомогательные enum/struct контракты |
| `GridLayout`, `GridTrack` | `.fixed`/`.adaptive`/`.masonry`/`.custom` — 4 policy, `columnCount(availableWidth:)` вычисляет детерминированно |
| `VirtualizedView<Item, ItemID>` (`open class ... : ScrollNode, SwipeRevealContainer`) | основной виртуализированный контейнер, наследует `ScrollNode` напрямую |
| `ListView`, `GridView`, `CollectionView` | тонкие финальные подклассы `VirtualizedView`, различаются только `axis`/`layout` по умолчанию |

`VirtualizedView` наследует `ScrollNode`, а не композирует его — то есть
данные/виртуализация/actions/reveal и viewport/offset/edge-pull живут в одной
цепочке классов. Именно это архитектурное решение implementation-plan-6.md §1.2
и §P6.4 явно предлагают **не** повторять («Общие state, lifecycle, scroll
mechanics, IDs и data transactions не дублируются тремя независимыми
реализациями», но также «ListNode/GridNode/TableNode используют общую основу» —
не «есть ScrollNode»). У наследования есть конкретная цена, видимая в самом
файле: `ListView`/`GridView`/`CollectionView` не могут быть использованы как
*страница внутри* другого скролла без создания второго вложенного native
scroll surface, потому что виртуализация неотделима от роли самого ScrollNode.
Для `TabbedScrollNode`/pager (P6.5), где строки должны прокручиваться *внутри*
уже существующего общего viewport, эта связка требует пересмотра — состав
(`ListNode` использует отдельный `ScrollNode` внутри общего, либо виртуализация
работает без собственного скролла и адресуется в координаты внешнего) должен
быть решён в R10, а не унаследован автоматически.

Идентичность и snapshot: `updateItems`/`updateSnapshot` перестраивают
`itemIDs`/`itemsByKey` с first-wins de-dup по дублирующимся ID (совпадает с
P6.4 «duplicate-key policy»), затем зовут `updateRenderedWindow()`.
`itemsByKey` ключуется по `String(reflecting: id)`, не по самому `ItemID` —
см. §4 (риск, не дефект).

Материализация — `updateRenderedWindow()`: считает `VirtualizationWindow` из
измеренных (`measuredLengths`) + оценочных (`estimatedItemLength`) длин с
`overscanFactor`, строит список `NodeDescriptor` (rendered range + опциональный
leading spacer + опциональные секционные хедеры) и применяет их через
`NodeReconciliationController.apply(to:descriptors:generation:make:recycle:)`.
Reuse — по `reuseID` строки типа (`"VirtualizedCell"`), не по типу элемента;
`configureReusedCell` — единственная точка, где reuse может провалиться и
откатиться на свежий `cell(...)`. `didApplyLayoutResult` — единственное место,
где реальные измеренные длины (`child.calculatedFrame`) попадают в
`measuredLengths`, что делает измерение синхронным с layout-коммитом (нет
отдельного measurement pass до commit, как того явно требует P6.9 «Sendable
model → … → worker layout/raster → … → commit»).

Swipe actions (P6.6) — `beginSwipeReveal`/`updateSwipeReveal`/`finishSwipeReveal`/
`cancelSwipeReveal`/`closeSwipeReveal`/`invokeSwipeAction` на `VirtualizedView`
через `SwipeRevealContainer`. Единственно открытая строка — ровно одна
(`swipeRevealItemID`), full-swipe threshold — `max(width, rowWidth * 0.7)`,
velocity threshold — `500`pt/s жёстко зашит (не параметр). Никакой политики
`.automatic`/`.disabled`/`.enabled` (P6.6) в источнике нет — vertical/horizontal
owner-конфликт (строка vs pager) вообще не встаёт, потому что в Weave нет
композиции «TableView внутри чего-то ещё, что тоже хочет горизонтальный жест».

## 4. Проверенная проводка UIKit/AppKit — главная находка

**В Weave нет ни одного использования `UIScrollView` или `NSScrollView`.**
Проверено `grep -rn "UIScrollView\|NSScrollView" Sources/` по всему пакету —
ноль совпадений. Вся «прокрутка» — это:

1. `UIKitAdapter.swift` вешает **один `UIPanGestureRecognizer`** на корневой
   host view. На `.changed` находит ближайший `ScrollNode` в дереве
   (`findScrollNode(in:)`, рекурсивный поиск по первому найденному — не через
   `arbitrate`/D18-style «ближайший предок в точке», а по первому попавшемуся
   в порядке обхода) и напрямую зовёт `scroll.moveBy(x: dx, y: dy)`.
2. Момент/деселерация — ручной `Task` (`startScrollDeceleration`), фиксированное
   трение (`velocity *= 0.75/кадр`-подобная эвристика, порог остановки `abs(velocity)
   < 8`), не системная `UIScrollView` decay-кривая, не `UIScrollViewDecelerationRate`.
3. Клип и позиционирование — `UIKitLayerRenderer.applyScrollOffset(node:)`
   пишет `layer.bounds.origin = CGPoint(x: offset.x, y: offset.y)` напрямую
   на `CALayer` контейнера внутри одной `CATransaction` с отключёнными неявными
   анимациями. Никакого второго "content" layer/view, никакого native
   `contentInset`/`contentOffset` вообще не существует.
4. Edge pull — `applyEdgePull` анимирует `transform.translation` через
   `CABasicAnimation` вручную; нет `UIRefreshControl`, нет native rubber-band.
5. Indicators — не реализованы (нет `showsVerticalScrollIndicator` аналога
   нигде в дереве).
6. AppKit — тот же паттерн: `scrollWheel(with:)` переопределён на host view,
   даёт `deltaX/deltaY` в тот же `findScrollNode`/`moveBy` путь. Нет `NSScrollView`,
   нет `NSScroller`, нет `magnification`/trackpad momentum phase
   (`NSEvent.momentumPhase`) — проверено, в файле не используется.
7. AX/keyboard/remote scroll actions — не реализованы; `UIAccessibilityScrollView`
   /аналог не встречается.

Итог для R06: **из Weave нечего «извлечь» на уровне native scroll mechanics**,
потому что там его нет — весь опыт «инерции» синтетический. Это прямо
подтверждает наблюдение из implementation-plan-6.md §2 («Фоновый solver один не
является обещанием плавности») с другой стороны: Weave подделывает
пользовательское ощущение полностью в userspace, без единого реального
`UIScrollView`/`NSScrollView`, и P6.3's требование «нативная механика в
adapters» (drag/wheel/momentum/deceleration/bounce/indicators от системы) —
это не перенос существующего кода, а первая реализация с нуля. R06's чек-лист
«прототип на UIKit и AppKit» должен начинаться от системного `UIScrollView`/
`NSScrollView`, не от рефакторинга `findScrollNode`+`moveBy`.

Единственное, что реально переносимо в архитектурном смысле —
**контракт** (`ScrollState`/`ScrollCommand`/`ScrollAxis`/`ScrollAlignment`/
`VisibilityContext`/`ViewportDemand`/`ScrollArbitration`), не проводка.
`arbitrate(_:)` тоже не переносится буквально: он не знает о состоянии реального
`UIPanGestureRecognizer`/`UIScrollView` delegate (`scrollViewWillBeginDragging`,
`gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`), а R08/R09 явно
требуют реального input-арбитража на этом уровне.

## 5. Известные дефекты (зарегистрированы в defects.md)

Подтверждены чтением кода (не экспериментом на устройстве — Weave не
собирался и не запускался в рамках этого разбора):

- **#63** — отсутствие native scroll view backing целиком (§4) — не баг в
  привычном смысле («что-то не работает, как задумано»), а подтверждённый
  архитектурный пробел, прямо влияющий на решение P6.3 «доказать … через
  живые native scroll views»: этого доказательства для Weave никогда не
  существовало, поэтому его нельзя «унаследовать вместе с уверенностью».
- **#64** — `VirtualizedView.updateItems` восстанавливает anchor-offset по
  `Double(newIndex) * max(0, estimatedItemLength)` (Collections.swift:579),
  игнорируя `measuredLengths` уже известных элементов — в отличие от
  `contentOffset(before:)` (Collections.swift:1089-1096), которая для той же
  цели (позиция до индекса) корректно суммирует `measuredLengths[key] ??
  estimatedItemLength`. Для списка с переменной высотой строк (ровно целевой
  сценарий P6.4/R11: «изменение высоты текста … сохраняют» anchor) новый
  snapshot с уже измеренными разными по высоте элементами перед anchor даёт
  неверный `delta`, то есть якорь **не** сохраняется корректно — именно то
  поведение, которое P6.4/R11 требуют явно проверить property-тестами.
  Не исправлено в Weave (правки там не вносятся, см. AGENTS.md «Перенос из
  Weave»); Trellis обязан реализовать anchor-restore по измеренным длинам с
  первого среза R11, не копируя эту формулу.

Непроверенный риск, не дефект (не подтверждён числами/профилированием):
`itemsByKey`/`headerByKey`/`measuredLengths`/`materializedNode(for:)` ключуются
через `String(reflecting: id)` вместо прямого `[ItemID: …]` словаря — на каждый
lookup аллоцируется строка через `String(reflecting:)`. На типичных `ItemID`
(строки/UUID/Int) это, вероятно, заметная, но не катастрофическая накладная
стоимость на большом списке; не измерено. P6.9's «Измерение»/R06's
performance harness должны включить сравнение с прямым `Dictionary<ItemID, _>`
как альтернативой, а не считать `String(reflecting:)`-ключ нормой по
умолчанию для Trellis.

## 6. Переносимые тесты

`ScrollTests.swift` (2 `@Test`) покрывает: (1) content-bounds clamp по обеим
осям + direction commands (`by`/`to`) — прямое утверждение на `ScrollState`
после серии команд, без адаптера; (2) visibility hooks (`entered`/`left`)
генерация-bounded на повторных/сдвинутых `updateVisibleFrames`. Оба —
чистые MainActor unit-тесты на голом `ScrollNode` без CALayer/UIKit; их форма
(ожидания на `ScrollState`/`entered`/`left` count) переносима как есть в
контракт-тесты `ScrollNode`-аналога R07, ни один тест не проверяет что-либо
за пределами уже описанного здесь контракта (ни momentum, ни native
gesture — согласуется с §4: их не с чем было тестировать).

`CollectionsTests.swift` существует (файл присутствует), но ни один его
сценарий не затрагивает native-специфичное поведение — он тестирует ту же
чистую MainActor-модель (snapshot/window/reuse/swipe state machine) через
`VirtualizedView`, без адаптера. Детальный построчный разбор не требуется для
R06 (он не про native scroll); R10/R12a должны прочитать его перед реализацией
`ListNode`'s virtualization contract tests, поскольку набор кейсов (anchor,
duplicate ID, reuse miss, swipe threshold) — прямой кандидат на повторную
формулировку как Sendable/property-тесты Trellis, с учётом дефекта #64 выше
(тест на anchor restore с переменной высотой должен явно проверить случай,
который #64 не покрывает).

## 7. Намеренные отличия Trellis от Weave (зафиксировать до переноса контракта)

Эти отличия — не пересмотр принятых D-решений (их пока нет для scroll, кроме
D18), а вывод из §3–§4 для авторов P6.3/P6.4 при их формализации в R06/R07/R10:

1. **Native backing обязателен с первого прототипа**, не добавляется поверх
   готового offset-контракта: `UIScrollView`/`NSScrollView` должны существовать
   до того, как `ScrollState`/`ScrollCommand` фиксируются, иначе есть риск
   повторить Weave — контракт, спроектированный для ручного `moveBy`, плохо
   ложится на delegate-driven `scrollViewDidScroll`/`willEndDragging
   withVelocity:targetContentOffset:` модель, где Trellis не инициирует
   momentum сам, а только *наблюдает* и синхронизирует geometry (P6.3: «Logical
   offset отделён от временного overscroll», «Geometry viewport обновляется
   синхронно с native offset»).
2. **Виртуализация не наследует ScrollNode**, а адресует его (owns-a, не
   is-a) — иначе `ListNode`-как-страница-внутри-pager (§1.1 плана) не может
   переиспользовать один `TabbedScrollNode`-owned native scroll surface без
   создания второго. Решение состава (общий viewport, чьи координаты readonly
   для страницы) — открытый пункт R10, не решённый этим разбором.
2а. Разделение data/measurement/scroll должно быть явным начиная с первого
    среза: reuse — по типу элемента (не по фиксированной строке
    `"VirtualizedCell"` для всех), state — по `(dataKey, itemID)` (P6.9), а не
    по `reuseID`.
3. **`arbitrate(_:)`-подобная функция нужна, но должна знать реальный native
   gesture/delegate state**, не только `deltaX/deltaY` — как минимум
   `UIGestureRecognizerDelegate.gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`
   / `NSGestureRecognizerDelegate` эквивалент, поскольку в Weave такого
   согласования никогда не было (один жест на весь host).
4. **Anchor restore обязан использовать измеренные длины**, не
   `estimatedItemLength`, с первого среза (закрывает #64, не переоткрывает его).
5. **`CollectionDataSource` не завязан на Flux в основании** — в Trellis это
   уже решено иначе (P6.11: DataSource/ItemProvider/Delegate платформенно
   нейтральны в Core, `TrellisFlux` даёт опциональное подключение поверх, см.
   R02–R04 module graph) — Weave здесь не образец, а пример того самого
   смешения, которого P6.11 явно избегает.
6. **D18 остаётся в силе**: когда `ScrollNode`-аналог появится, попадание в
   него по hit-test — «ближайший предок в точке», не первый найденный обходом
   дерева, как делает Weave's `findScrollNode(in:)` (простой pre-order поиск,
   не учитывает несколько ScrollNode на разных ветках/глубинах).

## 8. Не закрыто этим документом

- Собственно чтение `PeerInfoPaneNode.swift`/`Panes/` (implementation-plan-6.md
  §1.1.1, заявлено как «следующие источники для проверки») — не выполнено
  здесь; относится к R13/R14, не к базовому scroll-контракту. Выполнено позже
  отдельным документом: [telegram-peerinfo-analysis.md](telegram-peerinfo-analysis.md).
  `../old/Texture/Source/Details/ASLayoutRangeType.h` и `ASBatchFetching.mm`
  уже разобраны в плане §P6.8, не дублируются.
- Numeric performance baseline (R06 §6.1 harness) — отдельный, ещё не
  начатый пункт этой карточки; данный документ не измеряет ничего, только
  читает исходники.
- `TabBarPagerController.swift`/`PagerTabStripViewController.swift` (relay vs
  native-coordinated сравнение из implementation-plan-6.md §3) — не входят в
  Scroll/Collections анализ по названию карточки-заказчика (§3.1 плана
  ограничивает разбор Weave `Scroll.swift`/`ScrollContentView.swift`/
  `Collections.swift`); сравнение relay/coordinated остаётся отдельным пунктом
  чек-листа R06.

## 9. Дополнение R10: `CollectionsTests.swift` построчно (2026-09-23)

Прочитаны все 8 `@Test` (156 строк). Все работают на MainActor-модели `VirtualizedView`
без адаптера: окно с overscan на 10 000 элементах, стабильные ID при повторном
`updateItems`, first-wins для дублей и ограниченный selection, секции с header и
`updateMeasuredItem`, минимум одна колонка у adaptive grid, reuse/context menu со сбросом
focus при исчезновении ID, окно при переменных высотах, захват измеренной высоты из
`applyRecursively`. Ни один тест не проверяет anchor при переменных высотах, поэтому
дефект #64 ими не ловится. Переформулировка на типы Trellis и что отложено —
[validation/r10-data-contract.md](validation/r10-data-contract.md), решения —
[ADR 0030](adr/0030-collection-data-contract.md). Код Weave не переносится: реализация
Trellis написана заново по контракту; строка «заново» добавлена в source-provenance.md.
