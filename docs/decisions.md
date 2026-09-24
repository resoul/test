# Принятые решения Trellis

Дата: 2026-09-10. Здесь фиксируются согласованные контракты. Это документация проектирования; Swift-пакет ещё не реализован. Полный план: [implementation-plan.md](implementation-plan.md).

## D01 — Подключение

В первом этапе используются отдельные импорты TrellisCore и TrellisUIKit/TrellisAppKit. Facade `import Trellis` не нужен.

## D02 — Модель нод и NodeID — принято

`@MainActor open class Node`. Сильные children, weak parent — как в Weave, менять нечего. `open` обязателен: `arrangeSubnodes()` объявляется в теле класса и должен переопределяться подклассом.

### NodeID

```swift
public struct NodeID: Sendable, Hashable, CustomStringConvertible { … }
```

- Генерация принадлежит MainActor. Уникальность — между всеми живыми деревьями, включая разные хосты в одном процессе.
- ID сохраняется при reparent и при detach/attach. Это свойство проверяется тестом, а не подразумевается.
- Публичного создания из произвольного числа нет. Для фикстур — internal-доступ.
- `CustomStringConvertible` вместо публичного `.rawValue`: `"\(node.id)"` работает, внутреннее число остаётся скрытым.
- Это **runtime identity**. Не ключ модели, не идентификатор для сохранения между запусками, не значение для сравнения между разными прогонами.

### Перенос сквозной

Замена `typealias ElementID = UInt64` на `NodeID` затрагивает не только `Node`. В Weave слой раскладки этим `typealias` не пользуется вообще — там сырой `UInt64`:

```swift
Node.id                        : NodeID
LayoutInputSnapshot.identity   : NodeID
LayoutPlacement.identity       : NodeID
LayoutResult.treeIdentity      : NodeID
placement(for identity: NodeID)
```

Причина: в `LayoutResult.init` сейчас три подряд `UInt64` без дефолтов (`treeIdentity`, `environmentRevision`, `contentRevision`), и они же сравниваются в guard'ах актуальности `handleLayoutResult`. Перепутать два из них компилятор не мешает, а проявится это не исключением, а кадром, который иногда не применяется.

### Что `NodeID` не решает

Он разводит identity и ревизии, но **не разводит ревизии между собой**: `environmentRevision` и `contentRevision` остаются двумя `UInt64` рядом, и перепутать их по-прежнему можно.

Закрывается это тем же приёмом — отдельными типами ревизий. Решение отложено до C06, где эти типы фактически пишутся: там оно стоит несколько строк, позже — сквозная правка тех же пяти файлов. Пункт зафиксирован здесь, чтобы к нему вернулись осознанно, а не обнаружили заново.

## D03 — Arrangement без constraint

`arrangeSubnodes()` выполняется на MainActor до снимка и описывает структуру/правила, без обещания окончательной ширины контейнера. Responsive-ветвление по собственной измеренной ширине требует будущего отдельного контракта. LayoutContext в сигнатуру Arrangement не возвращается.

## D09 — Отмена вычисления

Внутренний контракт solver: `throws -> LayoutResult`. Успешный результат полный; отмена прекращает вычисление и не создаёт результата для commit. Пустой или частичный LayoutResult не является сигналом отмены.

Scheduler перехватывает отмену, освобождает worker slot после фактического выхода solver и запускает только актуальное pending-состояние. На хост допускается максимум один исполняющийся solver. Generation/revision guards остаются независимо от отмены.

Начальные checkpoints: вход layoutContainer на каждом уровне и границы flex-линий в measure. Это стартовая гранулярность, а не обещание достаточной отзывчивости для любой ширины линии. В C31 измеряется задержка отмены; редкие дополнительные проверки внутри долгих циклов добавляются по результатам. Проверка на каждом ребёнке не является требованием.

## D10 — LayoutContext принадлежит движку раскладки

Имя `LayoutContext` обозначает immutable Sendable-контекст исполнения движка раскладки (D11), включая проверку отмены. Это не прежний LayoutSpecContext из исторического черновика и не контекст Arrangement. Он не содержит живых Node/платформенных объектов. Данные геометрии остаются в явно определённых входах движка.

Математические синхронные тесты используют контекст без отмены; scheduler предоставляет контекст отмены текущей Task. Карточка-владелец типа и его internal-контракта — C06; C12 использует его и определяет checkpoints, C13 подключает отмену текущей Task. Имя и назначение закреплены сейчас. Не объявлять public extensibility API только ради этого типа.

## D11 — Имена движков раскладки — принято

| Роль | Имя |
|---|---|
| Планировщик: владеет worker, отменой, актуальностью результата (MainActor) | `LayoutScheduler` |
| Протокол чистой математики раскладки (internal) | `LayoutEngine` |
| Реализация flexbox | `FlexboxEngine` |
| Реализация grid (этап 2+) | `GridEngine` |
| Иммутабельный выход прохода | `LayoutResult` |
| Контекст исполнения движка, включая проверку отмены | `LayoutContext` (D10) |

Файлы: `FlexboxMeasure.swift` (measure снизу вверх) и `FlexboxPlacement.swift` (placement сверху вниз).

Обоснование: каждое имя называет свою роль, и весь набор согласован — `FlexboxEngine: LayoutEngine`, `GridEngine: LayoutEngine`. `Flexbox` — из спецификации, узнаваемо без пояснений; суффикс `Engine` отделяет реализацию математики от планировщика и даёт естественную пару для второго движка.

Отменяются прежние варианты: `FlexLayoutSolver` из плана, `FlexLayout` (одноимённая сторонняя библиотека), голый `Flexbox` (не даёт пары второму движку), протокол `LayoutSolver` из D08.

Смешение словарей `Engine` и `Solver` не допускается: раз реализации называются `*Engine`, протокол называется `LayoutEngine`, а не `LayoutSolver`.

**Про повторное использование имени `LayoutEngine`.** В Weave так назывался планировщик (`@MainActor final class LayoutEngine` с `request`/`cancel`/`dispose`). В Trellis это имя означает **протокол математики**, а планировщик называется `LayoutScheduler`. Двусмысленности, из-за которой имена разводились, больше нет: планировщик получил собственное имя. Расхождение с Weave зафиксировано здесь намеренно, чтобы оно обнаруживалось при чтении, а не при отладке.

`Grid` остаётся свободным для контейнера `Arrangement` в DSL — движок называется `GridEngine`, коллизии нет.

## Ранний запуск — приёмки существующих карточек

Первый запуск — минимальные приёмки C05–C20 после каркаса и C03, без отдельного milestone. Нужны один UIKit-host, одно физическое устройство, S01/S10, root safe area, strong root, один solver/pending latest, stale guards и request trace schedule/commit/layer/host.

Срез не ограничивается iOS: LayerTreeTests C17 выполняются через `swift test` на macOS и проверяют общий путь Node → snapshot → solver → coordinator → renderer → CALayer без NSView и симулятора. iOS-приложение проверяет тот же renderer на физическом устройстве. AppKit-host и его нативное поведение проверяются позже в полной C18.

Lifecycle-машина Node, раздельные dirty-причины, AppKit, API baseline и полная матрица могут быть закончены после этого запуска. Teardown host/worker/callbacks обязателен сразу. Полные приёмки карточек сохраняются. Реактивный путь C29 входит в первый этап, ранние замеры C31 следуют за рабочим срезом.

## Репозиторий — принято (C01)

`Trellis/` — самостоятельный git-репозиторий рядом с `Weave/`. Общий родительский репозиторий не заводится: каталог `/Users/resoul/projects/v2` остаётся рабочим пространством, в котором `Weave` уже живёт собственным репозиторием, а `old/` содержит справочные checkout'ы. Trellis повторяет ту же схему.

Обоснование: Trellis — отдельный продукт с собственными версиями и тегами SPM, и он не должен делить историю ни с Weave, ни со справочниками. Remote и публикация в первом этапе не требуются и не настраиваются. Решение обратимо в обе стороны, пока нет remote.

Источник переноса, состояние checkout Weave и лицензии зафиксированы в [source-provenance.md](source-provenance.md).

## D04. Владение стилем — принято (C07)

`Node.style` и `Node.appearance` хранят пользовательские базовые значения.
Arrangement resolver не меняет их: он создаёт отдельные effective-копии только
для `LayoutInputSnapshot` и накладывает на них явно заданные модификаторы.
Удаление модификатора поэтому восстанавливает базовое значение автоматически,
а не оставляет результат предыдущего resolve.

Base style — mutable value type с нормализацией в сеттерах. Effective style —
immutable копия внутри Sendable snapshot; публичного второго свойства на `Node`
нет. До появления resolver в C21/C23 кодовая граница выражена отсутствием API,
которое могло бы записать effective value обратно в базу.

## D05 — Владение деревом Arrangement — принято (C21)

Ненулевой `Arrangement` управляет полным списком layout-детей своего
владельца. Ручная мутация управляемого списка диагностируется, а не тихо
принимается. Возврат к `nil` возвращает владельца в ручной режим: снимает все
managed-связи и disposes только implicit wrapper-ноды (D06) — пользовательские
Leaf-ноды никогда не disposed резолвером, только отсоединяются
(`removeFromSupernode`) и остаются под владением вызывающего кода. Пустой
контейнер (`Row {}`) — отдельный случай от `nil`: список становится пустым, но
владелец остаётся под управлением resolver'а. Полный разбор снятия одного
слота и целого дерева — [c21-arrangement-contract.md](validation/c21-arrangement-contract.md#пример-b--удаление-части-содержимого).

## D06 — Identity wrappers — принято (C21)

Implicit wrapper-нода, создаваемая для вложенного контейнера (`Row`/`Column`/
`Overlay`, не `Leaf`), идентифицируется ключом `(ownerID, structuralPath,
containerKind)`, где `structuralPath` — последовательность индексов детей
внутри builder-дерева того же resolve. Стабильность обещана только при
неизменной структуре **и** неизменном `containerKind` на данном пути: смена
типа контейнера на этом пути (например, `Column` → голый `Leaf`) — это конец
жизни старого wrapper'а и появление нового слота, а не обновление на месте, ключ
не «оживляет» disposed wrapper. Leaf сохраняет identity при перемещении между
слотами того же owner. Устойчивость wrapper'ов при вставке элемента перед ними
не обещана без отдельного keyed API (`Arrangement` без явных ключей).

## D12 — Композиция effective style: контейнер, база, placement — принято (после C24)

Уточнение D04 по итогам S16–S19 (2026-09-11,
[analysis-arrangement-effective-style.md](analysis-arrangement-effective-style.md),
коммиты `51959b5`/`5c98eee`). Effective style любой ноды под управлением
Arrangement — **производная** от трёх источников и никогда не хранится как
результат прошлого resolve:

1. **База** — `node.style`, целиком. Всё, что DSL не описывает (`width`,
   `height`, `min/max`, `margin`, `alignSelf`, `flexGrow`, `positionType`,
   `offsets`, `flexWrap`, `alignContent`, `crossGap`, `visual`, …), приходит
   отсюда. Корневой контейнер описывает **self**, поэтому для владельца база —
   его собственный `style` (`width: 360` и `alignSelf: .center` из `init`
   подкласса живут); для implicit wrapper'а — пустой `LayoutStyle()`.
2. **Собственный корневой контейнер** (`arrangementContainerStyle`): поля
   контейнера — `flexDirection`, `gap`, `justifyContent`, `alignItems`,
   `padding` — **всегда** берутся из `Row`/`Column`/`Overlay`, в том числе
   их значения по умолчанию. «Не указан» и «ноль» — одно и то же; базовый
   `padding` владельца под управлением не участвует. Хочешь отступ — пиши
   `Column(padding:)`. Затем модификаторы, написанные на корневом контейнере
   (`Column {…}.grow(1)` — на self).
3. **Placement родителя** (`arrangementPlacement`): модификаторы item'а
   (`Leaf(x).grow(1)`, `.size`, `.align`, `.margin`, `.offset`) и
   `positionType = .absolute` для детей `Overlay` — накладываются
   **последними**: владелец решает, где стоят его items, ровно как он
   переопределяет их базовый `style`.

Порядок фиксирован: `base ⊕ container ⊕ rootModifiers ⊕ placement ⊕ absolute`.
Оба источника хранятся на `Node` как исходные данные (не вычисленные стили), и
у каждого ровно один писатель: placement пишет только resolve родителя,
container style — только собственный resolve. Поэтому нода может быть
одновременно item'ом родителя и владельцем собственного Arrangement
(S19: `Leaf(tile).grow(1)` + `Column` внутри плитки), и ни один из двух resolve
не стирает решение другого; порядок их вызова не влияет на результат.
Следствия: правка `style` под управлением сразу отражается в effective;
`Leaf`, покинувший все слоты владельца, теряет placement и возвращается к
базе; root-`Leaf`/`nil` у владельца снимают только его container style.

Не принято (сознательно): `Optional`-семантика для `padding`/`spacing`/
`justify`/`align` в DSL с наследованием из базы — два источника для одного
поля и изменение публичного API C22. Если понадобится — отдельное решение.

## D13 — Автоматический resolve Arrangement при подготовке snapshot — принято (C32)

Согласовано 2026-09-11 по итогам S19 (владелец внутри владельца требовал
ручного `tile1/2/3.resolveArrangement()` в правильном порядке). Реализация —
отдельная карточка C32.

- **Где.** В подготовке snapshot на MainActor — `RenderCoordinator.flush()` перед
  `makeLayoutInputSnapshot` (уточнено при реализации: bridge сам snapshot не делает,
  точка та же уровнем ниже) — pre-order обходом дерева: владелец с признаком
  «arrangement dirty» резолвится, затем его дети (порядок C21: owner → его
  дети, не более одного `arrangeSubnodes()` на живую ноду за проход). Это
  снимает ручной вызов для вложенных владельцев и гарантирует, что placement
  родителя уже выставлен, когда ребёнок резолвит свой контейнер (D12 делает
  порядок безразличным для результата, но не для числа проходов).
- **Что делает владельца грязным.** (а) Первая подготовка snapshot после
  attach — все ноды с `arrangeSubnodes() != nil`; (б) явный публичный
  `markArrangementDirty()` из подкласса после изменения его данных — аналог
  `setNeedsLayout`, единственный способ сказать «моё описание изменилось»;
  (в) структурные изменения под владельцем, сделанные не им, — **не**
  триггер: ручная мутация managed-списка по-прежнему диагностируется (D05).
- **Роль `.arrangement` в `DirtyReasons`.** Только причина запроса flush
  (C09), не место выполнения resolve: resolve делается в bridge, в той же
  точке «перед snapshot», где D03 обещает выполнение `arrangeSubnodes()`.
  Не внутри `InvalidationTransaction` commit — resolve сам открывает
  транзакцию для своих мутаций (C23), вкладывать его в чужую нельзя.
- **Что остаётся.** Публичный синхронный `resolveArrangement()` сохраняется:
  тесты эквивалентности S10/S15 и код, которому нужен результат немедленно,
  зовут его напрямую; автоматический путь — надстройка, а не замена.
  Повторный автоматический resolve неизменного дерева обязан быть no-op по
  ревизиям (приёмка C23) — иначе каждый flush будет порождать следующий.

Смена environment (safe area, direction) resolve не вызывает — D03 «без constraint»;
подтверждено тестом `unchangedTreeAndEnvironmentChangesNeverReResolve` (C32).

## D14 — Контракт источника состояния и владелец подписки — принято (C29)

Источник отображаемого состояния в этапе 1 — `StateSubject<Value: Sendable & Equatable>`
с latest-value семантикой: одно текущее значение, равное — no-op, без очереди. Он
MainActor-изолирован: продюсер делает hop, мутации `Node` не покидают MainActor, lock'ов
и `@unchecked Sendable` нет.

Владелец подписки — mounted session, то есть `NodeHostBridge` (и `TrellisHostView`,
который теперь держит один bridge на всю жизнь): `bindState(subject, update:)`. Доставка
следует монтированию — идёт пока root attached и не suspended; `current` отдаётся на
attach синхронно (первый commit уже с состоянием); burst синхронных `send` → один
отложенный `update` с последним значением; `detach` останавливает, `attach`
восстанавливает latest, `suspend` держит latest до `resume`, `cancel` — конец без
поздних мутаций.

`update(model)` — метод конкретной пользовательской ноды, не protocol на `Node`: она
сравнивает с показанным и трогает только изменившееся (`style` / `appearance` /
`markArrangementDirty()`), ключуя детей по стабильному идентификатору модели, чтобы
identity нод и слоёв переживала перестановки. Адаптеры других state-механизмов
подключаются, держа `StateSubject` и зовя `send`. Не для событий и действий.

## D15 — Служебные контейнеры без CALayer: не включать по умолчанию — принято (C30)

Эксперимент C30 ([c30-layout-only-wrappers.md](validation/c30-layout-only-wrappers.md))
показал, что implicit wrapper'ы Arrangement можно рендерить без слоя корректно
(геометрия, порядок, reparent, overlay, эффекты принуждают слой), с выигрышем −37 % слоёв,
~2 KB/слой и 7–9 % времени полного обновления. Базовая модель этапа 1 остаётся «слой на
каждую ноду»: выигрыш умеренный, а расхождение дерева слоёв с деревом нод усложняет
hit-testing, анимации и групповые эффекты этапа 2, которые лучше проектировать с реальным
контентом. `LayerRenderer.skipsLayoutOnlyWrappers` остаётся публичным опциональным
режимом (по умолчанию `false`) для замеров C26 на устройстве; пересмотреть, если число
слоёв окажется узким местом там.

## D16–D34 — Hit-testing и события: контракт этапа 2 — принято (H01)

Согласованы 2026-09-11 при обсуждении [implementation-plan-2.md](implementation-plan-2.md)
§3; полные формулировки, находки-обоснования (G01–G08, T01–T04) и примеры с ожидаемым
результатом — там и в [h01-contract.md](validation/h01-contract.md). Здесь — то, что
код обязан соблюдать; **записанные** ограничения (D18, D24, D26, часть D30/D32) не
блокируют H02 и пересматриваются отдельными карточками после H09.

- **D16.** Чистая математика (снимок, hit-test, dispatcher, session, арбитр) —
  `TrellisCore`, только Foundation. Формирование/хранение снимка и резолв `NodeID` в
  живую ноду — `NodeHostBridge`. Адаптеры `UITouch`/`NSEvent` → `PointerData` —
  тонкие, в `TrellisUIKit`/`TrellisAppKit`.
- **D17.** Обход от корня к переднему потомку с накопленным affine-преобразованием;
  клип только от `overflow == .hidden`/`.scroll` предков по их локальным bounds; дети
  неклипующего узла обходятся и вне его bounds; `opacity == 0` исключает поддерево,
  `0 < opacity ≤ 1` — нет. **Pivot трансформа — центр frame** ([ADR 0010](adr/0010-transform-pivot-is-frame-center.md),
  #30). AABB — только оптимизация по transformed bounding box, только после замера.
- **D18 — принято (R07).** `ScrollNode` построен ([ADR 0026](adr/0026-scroll-node-viewport.md)).
  Маршрутизация — по ближайшему предку в точке, не по первому в дереве (G02):
  `HitTest.swift`'s обход применяет offset каждого `.scroll`-предка на своём
  уровне рекурсии по мере спуска (`hit(_:at:)`/`contains(_:node:)`), а не
  ищет «тот самый» `ScrollNode` где-то в дереве заранее — в отличие от
  Weave's `findScrollNode(in:)`, простого pre-order поиска первого совпадения
  (`docs/weave-scroll-analysis.md` §7 (6)). Offset для каждого узла берётся из
  `HitTestSnapshot.scrollOffsets[NodeID]`, заполняемого на коммите из
  `NativeScrollBacking.contentOffset` (native — источник истины) и обновляемого
  дёшево через `withScrollOffsets(_:)` на каждый offset-only native-тик, без
  повторного обхода дерева. Проверено
  `test_hitTest_d18NearestAncestorRoutingForNestedScrollNodes`
  (`Tests/TrellisRenderTests/ScrollNodeHitTestTests.swift`): два вложенных
  `ScrollNode` с независимыми offset'ами резолвятся корректно раздельно.
- **D19.** Arrangement-обёртка (`isArrangementWrapper`) никогда не target; её дети
  участвуют; флаг — в снимке.
- **D20.** Three-phase `Event`/`EventDispatcher` по образцу Weave, ключ — `NodeID`.
  `stopPropagation()` прекращает callbacks после текущего, не отменяет выполненные side
  effects, не равен `preventDefault()`.
- **D21.** Render `generation`/revision — не guard сессии. Сессия: pointer key, маршрут
  `[NodeID]` из снимка на down, root ID, mount epoch. Перед доставкой: `!isDisposed` по
  маршруту, тот же mount epoch, parent каждого узла маршрута — предыдущий узел
  (reparent рвёт сессию). Нарушение — внутренний cancel без activation.
- **D22.** Control: `@MainActor () -> Void`, без Flux; pressed-состояние на типе control;
  up-inside — по последнему committed снимку геометрии control (D34).
- **D23.** Только Tap и Pan.
- **D24** (записано). tvOS — сборка и рендер, без интерактивного сценария.
- **D25.** Immutable `HitTestSnapshot` (`TrellisCore`), формируется в commit-точке
  `LayerRenderer` и хранится на `NodeHostBridge`: root identity, mount epoch, по
  `NodeID` — parent, ordered children, committed frame, committed
  `LayoutVisualProperties`, `isArrangementWrapper`. Hit-test — только по снимку; до
  первого commit, после detach и без снимка — `nil`.
- **D26** (записано). Общего hit-test behavior (`enabled`/`transparentSelf`/
  `disabledSubtree`) в этапе нет: обёртки прозрачны, остальное участвует.
- **D27.** Implicit capture down-target на всю сессию: move/up/cancel идут по маршруту,
  зафиксированному на down. Отдельного `PointerCaptureStore` нет.
- **D28.** Маршрут dispatch фиксируется как `[NodeID]` до первого callback; перед каждым
  callback резолв в том же mount; отсутствующая/disposed нода пропускается; удаление
  target прекращает target/bubble; сессия после этого отменяется; вложенный dispatch
  получает свой маршрут. Живые `Node`-ссылки на время dispatch не удерживаются.
- **D29.** capture → target → bubble → (если default не предотвращён) recognizers
  маршрута: target раньше предков, внутри ноды — порядок регистрации, tie-break —
  более ранний. Победа Tap на control — activation ровно один раз; `preventDefault()`
  снимает и arena, и activation.
- **D30.** `PointerData.point` — host bounds, origin сверху слева, points; `pointerID`
  стабилен на сессию, namespace — bridge/mount; non-finite отклоняются. Single-touch:
  лишние touches получают cancel (мультитач — записано). Не-primary кнопки мыши
  игнорируются. Без kind/buttons/modifiers/timestamp/pressure.
- **D31.** Tap slop 10 pt, Pan threshold 10 pt, без max Tap duration; пороги в
  configuration value, тесты `<`/`==`/`>`. Pan: start, current, translation, delta;
  `.began`/`.changed`/`.ended`/`.cancelled`. Resize не отменяет; detach/suspend/
  pointer cancel/arbitration loss → `.cancelled` ровно один раз.
- **D32.** Siblings: `zIndex` убыв., при равенстве — `subnodes` в обратном порядке;
  `zIndex` сравнивается только между siblings одного родителя. Интерактивность
  поддерживается только при `skipsLayoutOnlyWrappers == false` (записано).
- **D33.** Half-open bounds (`min` включён, `max` исключён); zero-sized frame не хит.
- **D34.** Commit между down и up: маршрут остаётся с down, геометрия up-inside — из
  последнего committed снимка.

## D35–D48 — Focus engine и accessibility: контракт этапа 3 — принято (A01)

Согласованы 2026-09-11 по [implementation-plan-3.md](implementation-plan-3.md) §3;
API sketch, таблица владения, миграция событий, mapping ролей и ожидаемые переходы —
в [a01-focus-accessibility-contract.md](validation/a01-focus-accessibility-contract.md).
Здесь — то, что код обязан соблюдать. Уточнения к формулировкам плана выделены
словом «уточнено». Ограничение D24 снимается **только** для нового tvOS focus/remote
пути (A08/A11); историческая приёмка H09 (tvOS — «ничего не сломалось») не
пересматривается. `skipsLayoutOnlyWrappers == true` остаётся без интерактивного пути
(D32) — focus/accessibility в этом режиме не публикуются.

- **D35. Владение.** `FocusEngine`, `SemanticSnapshot`, `AccessibilityTree` и все
  value-типы — `TrellisCore`, только Foundation. `NodeHostBridge` владеет engine,
  актуальным снимком и modal scope; engine хранит `NodeID`, mount epoch и значения —
  ни `Node`, ни host, ни closures нод. Живой `Node` engine получает только как
  borrowed-аргумент вызова (`root:`), как `PointerSessions`. Native focus/AX-объекты
  принадлежат `TrellisHostView` и резолвят `NodeID` через bridge.
- **D36. Согласованное состояние.** `SemanticSnapshot` несёт `mountEpoch`,
  `geometryGeneration` (generation коммита, из которого взята геометрия) и собственный
  `revision`. Геометрия и порядок — только из последнего commit (`HitTestSnapshot`,
  D25). Metadata-only publish строит новый снимок по **тем же** committed ID с
  актуальной metadata; узел, появившийся в живом дереве после commit, не публикуется
  до следующего commit. Перед любым callback/action — live guard: root тот же,
  маршрут цел (D28), нода не disposed, control enabled.
- **D37. Eligibility.** `Node.focus.isFocusable` по умолчанию `false`; `ControlNode`
  по умолчанию `true`. Кандидат focus: committed frame, непустая видимая область
  (D46), `opacity > 0` по всей цепочке, `isEnabled`, членство в текущем scope, не
  Arrangement wrapper. `accessibility.childrenPolicy == .hide` не отключает
  keyboard focus; disabled control остаётся элементом AX (читается как disabled), но
  не активируется ни одним источником.
- **D38. Обход.** `.next` (Tab) — committed pre-order по focusable-кандидатам,
  `.previous` (Shift-Tab) — обратный; порядок создания `NodeID` и `zIndex` не
  участвуют. Стрелки — физические направления в host space; RTL не меняет смысл
  `.left`/`.right`. Валидный explicit override (`focus.preferredNext[direction]`)
  раньше геометрического поиска; неизвестный, self, не-eligible или out-of-scope
  target игнорируется, поиск идёт дальше. Без кандидата — `.unchanged` (host отдаёт
  событие системе). Без текущего focus `.next`/стрелка выбирают начальный элемент,
  `.previous` — последний; начальный элемент — по `priority` убыв., затем traversal
  index (уточнено: priority только здесь и в fallback, никогда в directional score).
  Directional score: центры видимых AABB, строго положительная проекция на ось
  направления, `primary + 0.5 * secondary`, tie — меньший traversal index. Wrap
  выключен вне modal; внутри modal `.next`/`.previous` циклические, стрелки без wrap.
- **D39. Переход.** `FocusEngine.focusedID: NodeID?`, `FocusChange(previous, next,
  reason)`, `transitionRevision`. Порядок: `focusOut` → повторная валидация `next` по
  live guard → `focusIn` → `onFocusChange`. Тот же ID — no-op без событий. Запрос из
  callback не рекурсирует: ставится в очередь, выполняется после завершения текущего
  перехода с повторной валидацией; глубина очереди ограничена (8), дальнейшие
  запросы отбрасываются с диагностикой. События переходов — не отображаемое state.
- **D40. Scope/lifecycle.** Одна modal scope на bridge, без стека: `scopeID` и
  `restorationID` (focus до открытия). Открытие — одна транзакция: focus ограничен
  поддеревом scope, AX tree строится от scope. Закрытие восстанавливает
  `restorationID`, если он eligible, иначе первый доступный (D38). Пустая modal
  scope — `focusedID == nil`, focus не выпускается в фон. `detach()`/замена root
  очищают focus, scope, очередь и pending native request. `suspend()` отменяет
  начатый press-cycle и сохраняет только restoration ID; `resume()` не активирует
  control и проверяет restoration по первому актуальному снимку.
- **D41. Metadata/инвалидация.** `Node.focus: FocusProperties` и
  `Node.accessibility: AccessibilityProperties` — value-типы с no-op equality в
  `didSet`; `DirtyReasons.semantics` — отдельная причина, `semanticsRevision` — отдельная
  ревизия ноды (без подъёма по предкам, как `appearanceRevision`). Один coalesced
  flush на burst; при чистой geometry/structure — без layout snapshot и без solver
  (semantic-only fast path). Semantic-only ping во время активного solve не отменяет
  solver; commit читает актуальную metadata. `ControlNode.isEnabled` — единственный
  источник enabled для focus eligibility, всех источников activation и AX state.
- **D42. Семантическое дерево.** Независимо от focusable и hit-target. `.contain` —
  узел-контейнер своих element-потомков; с `isElement == true` без element-потомков
  — leaf; с `isElement == true` **и** element-потомками — группа с label (уточнено:
  не второй leaf, см. §3.2 контракта). `.ignoreSelf` — контейнерная связь
  сохраняется, собственный endpoint отсутствует независимо от `isElement`. `.hide` —
  поддерево исключено. `.combine` — один leaf без отдельных детей: label — явный
  label родителя, иначе непустые labels потомков в reading order через `", "`;
  value/hint/role/state/actions — только родителя. Reading order: `sortPriority`
  убыв. среди siblings, tie — committed порядок; не-finite priority — 0. Arrangement
  wrapper прозрачен. Modal scope ограничивает дерево поддеревом scope.
- **D43. Действия.** `ControlNode.activate(source:)` — единственная default
  activation: `.pointer` (winning Tap, up-inside), `.keyboard` (Return/Space
  key-up после принятого key-down на этом же control), `.remote` (Select на tvOS),
  `.accessibility` (AX activate). Capture/target/bubble и `preventDefault()`
  выполняются до default action. `performAccessibilityAction` возвращает `true`
  только при фактической обработке; unknown/stale/disabled/hidden — `false`.
  Custom action — `AccessibilityCustomAction(id:name:)`: стабильный `id`,
  локализуемое `name`.
- **D44. Системный focus (tvOS).** Выбрано по A02: native proxy — `UIAccessibilityElement`,
  дополнительно реализующий `UIFocusItem`, один объект на committed `NodeID`, без
  UIView. Host — `UIFocusItemContainer` (`focusItems(in:)`) только при
  `userInterfaceIdiom == .tv`. Engine на tvOS не объявляет переход завершённым до
  `didUpdateFocus` proxy; запрос engine → `preferredFocusEnvironments` +
  `setNeedsFocusUpdate()` с pending token; native callback с другим item побеждает.
  Стрелки на tvOS — системный focus engine; `Select` — `.remote` press-cycle через
  общий A07 путь.
- **D45. Два вида focus.** Keyboard/remote focus и VoiceOver cursor независимы: AX
  activate не переносит keyboard focus. Зеркалирование только наблюдённого native
  перехода с `reason: .native` и token guard; commit не принуждает VoiceOver вернуться
  к `focusedID`.
- **D46. Геометрия.** Видимая область — AABB polygon после transform по цепочке
  (ADR 0010), пересечённый с clip-предками (`overflow != .visible`) и host bounds;
  полностью отсечённый или zero-size — не кандидат. Native AX frame — screen-space
  bounding box видимой области; host → window → screen только в адаптере. Порядок AX
  ≠ paint order.
- **D47. Уведомления.** Native элементы переиспользуются по `(mountEpoch, NodeID)`.
  Адаптер сначала целиком заменяет published tree/properties, затем уведомляет
  (`layoutChanged`/`screenChanged` только для modal, `NSAccessibility.post`).
  Одинаковый снимок (equal `AccessibilityTree`) не уведомляет. Изменение value не
  меняет identity элемента.
- **D48. Совместимость.** `EventType` получает `.focusIn/.focusOut/.keyDown/.keyUp`,
  `EventPayload` — `.focus(FocusData)`/`.key(KeyData)`; `Event.pointer` становится
  `PointerData?` ([ADR 0013](adr/0013-event-pointer-becomes-optional.md)).
  `ControlNode.track` и внешний consumer мигрируют в A07; baseline обновляется
  отдельной командой с review note.

### Уточнение D37/D38/D44 — R08, 2026-09-22

Согласовано пользователем: [ADR 0028](adr/0028-scroll-focus-reveal.md).
Offscreen committed элементы допускаются только в поиск цели раскрытия через
ScrollNode. Eligibility не расширяется: сначала native scroll, затем повторная
проверка видимости и запрос focus. На tvOS новую identity подтверждает исключительно
native callback; видимые направления остаются у системного engine. AX page actions
пользуются тем же scroll command pipeline независимо от keyboard focus.

## C21 — Завершить контракт Arrangement до кодирования resolver — принято

Полный контракт (корневые формы `.nil`/Leaf/container/empty, Overlay lowering
на существующий `positionType == .absolute`, диагностика duplicate/self/cycle/
foreign-mounted Leaf с полным откатом proposal, порядок recursive resolve
сверху вниз с не более одного вызова `arrangeSubnodes()` на живую ноду за
проход) зафиксирован в
[c21-arrangement-contract.md](validation/c21-arrangement-contract.md) вместе с
двумя обязательными примерами (статическая карточка; удаление и смена типа
части содержимого). D03/D04 подтверждены без изменений; D05/D06 приняты выше.
Ничего не реализовано этой карточкой — `Arrangement`/`Leaf`/`Row`/`Column`/
`Overlay`/resolver остаются задачами C22/C23.

## D49–D60 — Текст и измерение содержимого: контракт этапа 4 — принято (T01)

Согласованы 2026-09-12 по [implementation-plan-4.md](implementation-plan-4.md) §3;
API sketch, ownership/cancellation-таблица и восемь обязательных примеров — в
[t01-text-contract.md](validation/t01-text-contract.md). Источник Weave и
находки W01–W10 разобраны в implementation-plan-4.md §2.1; дефекты #36–#40
остаются открытыми для T03/T05, закрываются переносом. Раскладка изменений на
`LayoutContentMetrics`/`LayoutInputSnapshot`/`DirtyReasons` — [ADR
0014](adr/0014-content-measurer-and-display-dirty-reason.md). Открытое
предложение §3.3 (атрибутированная модель против `String` + один `TextStyle`)
решено здесь в пользу атрибутированной модели — см. D55.

- **D49. Измерение в solver.** `LayoutContentMetrics` получает `measurer: (any
  ContentMeasurer)?`; протокол несёт `identity: ObjectIdentifier`, `revision:
  UInt64` и `func measure(_ constraint: SizeConstraint, context: LayoutContext)
  throws -> LayoutContentMetrics`. Равные `(identity, revision)` обязаны
  означать одинаковый результат при одинаковом `constraint`; тип, порождающий
  `identity` заново на каждый snapshot, нарушает контракт кэша, а не просто
  снижает hit rate. Solver вызывает измеритель в трёх точках §3.1
  implementation-plan-4.md (базовый размер, финальная ширина многострочного
  текста, cross-size при `stretch`), результат — в существующий
  `FlexMeasureCache` по `LayoutMeasureCacheKey`. Узел без измерителя ведёт себя
  как сейчас: `layoutContentMetrics(for:)` вызывается один раз при snapshot.
  Измеритель не хранит и не читает `Node`.
  **Уточнено по реализации T12** ([дефект #46](defects.md),
  [t12-scenes-references-docs.md](validation/t12-scenes-references-docs.md)):
  «базовый размер» (§3.1's первая из трёх точек) обязан подставлять лефа
  собственный resolved `style.width`/`style.height` вместо входящего от
  родителя constraint'а, когда лефу есть что подставить — было не так:
  `measuredContent` всегда мерился против constraint'а родителя
  (`.unspecified` на главной оси во время basis-прохода, ADR 0009),
  игнорируя, что у самого лефа уже есть явный размер. Для лефа без измерителя
  это не имело значения; для content-зависимого (`TextNode`) это означало,
  что явная ширина никогда не ограничивала перенос строк — леф с
  `style.width` в row-контейнере измерял высоту так, будто ширина была
  неограниченной, и (поскольку basis тогда уже равен resolved-размеру, расти/
  сжиматься не нужно) второй, точный проход измерения никогда не срабатывал
  тоже.
- **D50. Границы модулей.** `TextStyle`, `TextTruncation`, `TextLayoutInput`,
  `TextMetrics`, `ContentMeasurer`, `TextNode`, portable fallback-измеритель —
  `TrellisCore` (только Foundation). CoreText-измеритель и растеризатор —
  `TrellisRender`; `import CoreText` разрешается policy как нейтральный для
  всех целевых платформ, наравне с `CoreGraphics`/`QuartzCore`. Хосты
  (`UIKitAdapter`/`AppKitAdapter`) только выставляют environment при `attach`,
  реализацию измерения/растра не содержат.
- **D51. Источник измерителя — уточнено по реализации T04.** `EnvironmentKey`
  `TextRendererKey` со значением `any TextRenderer`. Хост ставит CoreText-реализацию
  при `attach` (T09); headless `TrellisCore` без хоста — `PortableTextMeasurer`,
  явно помеченная детерминированная модель (не типографика, W03/#40). Никакого
  глобального реестра (в отличие от Weave `TextLayoutBackendRegistry`, W05).
  `LocaleKey` (`localeIdentifier`) — тоже `EnvironmentKey`.
  Три уточнения, обнаруженные при реализации (T04,
  [t04-text-node.md](validation/t04-text-node.md) §2), не дожидались отдельного
  решения, потому что без них набросок T01 попросту не работал бы: (1)
  `TextRenderer.measure` получает параметр `constraint: SizeConstraint` — без него
  измеритель не мог бы знать, при какой ширине его вызвал solver, что противоречило
  бы самому смыслу D49; (2) `scale` убран из `TextLayoutInput` — измерение и перенос
  строк в points, не зависят от плотности пикселей; `scale` остаётся отдельным
  параметром `rasterize` (T05/T06), как и было в наброске для этого метода; (3)
  `TextRenderer` в T04 несёт только `measure` — `rasterize(...) -> DisplayArtifact`
  добавляется как протокольное требование в T05/T06, когда `DisplayArtifact`
  (T06) уже существует, а не стаббируется заранее. «Смонтированный хост без
  backend — ошибка конфигурации» из первоначального наброска не реализовано в T04:
  различить «headless» от «хост забыл выставить `TextRendererKey`» невозможно, читая
  только environment (оба видят `nil`), а строить отдельный сигнал «хост подключён»
  T04 не просили — оба случая используют `PortableTextMeasurer` до T09, когда
  реальный сигнал появится, если понадобится.
  **Уточнено по реализации T05** ([t05-coretext-measurement.md](validation/t05-coretext-measurement.md)):
  `CoreTextRenderer` — первый и единственный реальный конформер `TextRenderer`
  до T09; `rasterize` по-прежнему не добавлен (T06 ещё не существует), так что
  расширение протокола откладывается ещё на одну карточку без нарушения контракта.
  `TextStyle.lineHeight > 0` передаётся в CoreText как `CTParagraphStyle`
  min/max line height (а не как множитель после факта) — origins/`CTLine` уже
  учитывают форсированный интервал, поэтому и высота, и baseline остаются
  внутренне согласованными с тем, что видит paragraph style. Truncation-стиль
  (`clip`/`tail`) не меняет измеренный размер (D56) — влияет только на T06's
  будущую отрисовку последней строки.
  **Уточнено по реализации T09** ([t09-host-text-environment.md](validation/t09-host-text-environment.md),
  [ADR 0015](adr/0015-node-host-bridge-attach-gains-text-environment.md)):
  оба хоста (`TrellisUIKit`/`TrellisAppKit`) ставят `CoreTextRenderer()` и
  `Locale.current.identifier` на корень внутри `NodeHostBridge.attach(...)` —
  новые именованные параметры с default `nil`, не отдельный вызов после
  attach (второй flush на каждый attach иначе). Локаль переустанавливается
  при `NSLocale.currentLocaleDidChangeNotification` через новый
  `NodeHostBridge.updateLocaleIdentifier(_:)`, тем же путём, что
  `updateLayoutDirection`/`updateSafeArea` уже используют для своих
  событий — без equality-проверки перед записью (`EnvironmentScope.set`
  всегда поднимает revision), тот же принцип, что уже принят для
  direction/safe-area.
- **D52. Инвалидация.** `TextNode.text`/`textStyle`/`maxLines`/`truncation` —
  no-op equality в `didSet` (по образцу существующих полей `Node`). Изменение
  любого поля, влияющего на intrinsic-размер или перенос строк, поднимает
  `structureRevision`/`contentRevision` узла и запрашивает geometry flush;
  изменение, влияющее только на цвет (run-level `color`, `TextStyle.color`),
  поднимает новый `semantics`-независимый канал `displayRevision` и запрашивает
  только `DirtyReasons.display` — без solve. Ключ измерения (§D49) не включает
  paint-only revision. Display key (§D53) включает `nodeID`, `contentRevision`,
  `displayRevision`, финальный локальный размер, `scale` и разрешённый список
  typography/theme входов; изменение position или общего generation коммита без
  изменения этих полей не требует нового bitmap.
- **D53. Display pipeline.** `DisplayScheduler`/`DisplayTransaction`/
  `DisplayArtifact` переносятся из Weave (W06) в `TrellisRender` с приоритетами
  и `maxConcurrency`. Валидность artifact проверяется по отдельной committed
  display-таблице, ключ — `(NodeID, mountEpoch, display key)`, независимой от
  `HitTestSnapshot` (в отличие от Weave, где `DisplayTransaction` искал ноду по
  живому дереву, W06) — тот же принцип, что уже применяют `SemanticSnapshot` и
  `PointerSessions` для `mountEpoch`. `RenderCoordinator.onPostCommit` планирует
  display pass только для нод, чей текущий committed key не совпадает с нужным.
  Overflow планировщика не теряет актуальную видимую работу: она
  перепланируется, как только освобождается слот, а не отбрасывается молча.
  Suspend отменяет очередь; resume планирует недостающие актуальные artifacts,
  не воспроизводя устаревшие запросы.
  **Уточнено по реализации T06** ([t06-display-pipeline.md](validation/t06-display-pipeline.md)):
  отдельного типа `DisplayTransaction` нет — его роль (какой ключ сейчас в
  полёте у ноды, какой уже закоммичен) целиком берут на себя `DisplayScheduler`'s
  собственные `activeJobs`/`pendingByNode`/committed-таблица, без промежуточного
  объекта-транзакции; добавление его сейчас было бы обёрткой без собственного
  поведения. Валидность по `mountEpoch` не хранится внутри `DisplayKey` — вместо
  этого `NodeHostBridge` создаёт новый `DisplayScheduler` на каждый `attach` и
  вызывает `dispose()` в `detachCurrentRoot()`, тем же способом, каким уже
  живёт `RenderCoordinator`; тогда `mountEpoch` вообще не нужен как отдельное
  поле — предыдущий mount физически не может закоммитить в текущий, потому что
  его `DisplayScheduler` больше не существует. `DisplayKey` использует
  `environmentRevision` (узел's `EnvironmentSnapshot.revision`) как
  «typography/theme входы» из D52 — единственный вход, который не отражается
  ни в `contentRevision`, ни в `displayRevision`. `RenderCoordinator.onPostCommit`
  и (для paint-only смены цвета) `onDisplayOnly` оба запускают один и тот же
  full-tree scan за `TextNode`; ни один из колбэков не несёт origin-ноду, так
  что сравнение ревизий по всему дереву — тот же принцип, что уже применяет
  `LayerRenderer.applyAppearance(root:)` для paint-only. `CALayer.contents` не
  трогается этой карточкой — `DisplayScheduler.artifact(for:)` только хранит
  committed bitmap; применение к внутреннему raster layer — T07.
  **T07** ([t07-text-raster-layer.md](validation/t07-text-raster-layer.md))
  реализует это применение и полный контракт D65 (implementation-plan-5.md):
  `LayerRenderer` держит `rasterLayers: [NodeID: CALayer]` отдельно от
  `LayerRegistry` (внешний слой — единственный, кого видят hit-test/focus/AX);
  растровый слой — sublayer внешнего, `anchorPoint = (0,0)`,
  `contentsGravity = .topLeft`, `masksToBounds = true`, никогда не участвует в
  `orderOwnedChildren`/`paintedDescendantLayers` (не зарегистрирован там). D65
  различает resize (старый bitmap остаётся, обрезанный, до готовности нового)
  и смену текста/стиля/темы/locale (старое содержимое убирается немедленно —
  временная пустота допустима, показывать прежнее как актуальное нельзя):
  `DisplayKey.hasEqualContent(to:)` различает эти два случая по
  `contentRevision`/`displayRevision`/`environmentRevision`, игнорируя
  `size`/`scale`; `NodeHostBridge.scanForDisplayWork` вызывает
  `LayerRenderer.clearDisplayContent(for:)` только когда контент разошёлся.
  Этого разделения не было в первой версии карточки (замечено при ревью,
  добавлено до коммита) — без него смена текста показывала бы старую строку
  как актуальную, пока не придёт новый растр, класс дефекта, который T02's
  прототип уже проверял
  (`t02_textChangeDropsStaleContentsInsteadOfShowingOldTextAsCurrent`).
- **D54. Sendable-артефакт — обновлено по результату T02.** Compile-probe
  (`Task.detached` с захватом значения, не только `struct: Sendable`) на
  закреплённом SDK (Xcode 26.6/Swift 6.3.3/SDK 26.5, strict concurrency,
  без `@unchecked Sendable`/`nonisolated(unsafe)`/`@preconcurrency` — запрет
  AGENTS) показала: `CGImage` и `CGColorSpace` — `Sendable` без обходов;
  `CTFont` и `CGDataProvider` — нет (`#SendingClosureRisksDataRace`, T02,
  [t02-raster-prototype.md](validation/t02-raster-prototype.md) §3). Это меняет
  предпочтение, записанное T01: `DisplayArtifact` (T06) несёт `CGImage`
  напрямую, без обязательной `Data`-копии на каждый растр — измеренная стоимость
  такой копии на 1000 строк (~8–14 ms сверх ~73–87 ms самой растеризации,
  T02 §3.1) реальна и её незачем платить, если пересечение границы изоляции
  безопасно на этом SDK. `Data`-вариант остаётся резервным путём, если T06
  обнаружит регрессию Sendable-конформанса на другом закреплённом SDK
  (проверка воспроизводима, не разовая констатация). Число копий, владение
  буфером и стоимость на MainActor при коммите в `CALayer.contents` измеряются
  T06/T11, не предполагаются заранее.
- **D55. Typography и модель текста (снимает открытый вопрос §3.3).** Один
  `AttributedString` (Foundation) с собственным Trellis `AttributeScope`
  (`fontName`, `pointSize`, `weight`, `color: ThemeColor`, `lineHeight`) —
  единый документ, а не пара независимых `text`/`attributedText` полей (что
  повторило бы класс дефекта W07). `TextNode(text: String)` — convenience
  initializer поверх этого же документа, автору не нужно собирать runs для
  обычной строки. `TextStyle` — базовый (paragraph-level) стиль узла:
  `fontName` (`"system"` резолвится через `CTFontCreateUIFontForLanguage`, не
  `"Helvetica"`, снимает W02-класс дефект для системного шрифта), `pointSize`,
  `weight`, `lineHeight` (`0` — natural), `alignment`
  (`leading`/`center`/`trailing`, физика зависит от `direction`), `color:
  ThemeColor?` (`nil` → `theme.foreground`). Runs переопределяют только
  поддержанные для первой версии поля (шрифт/размер/вес/цвет); paragraph-
  параметры (`lineHeight`/`alignment`/`maxLines`/`truncation`) остаются общими
  для узла — смешение paragraph rules внутри одной строки не вводится
  незаметно. Метрики строк — из `CTLine` (`ascent`/`descent`/`leading`),
  baseline первой строки — реальный ascent, не константа `lineHeight * 0.8`
  (снимает #38). Только Foundation-ключи Trellis в `TrellisCore`; перевод в
  `kCTFont…`/`kCTForegroundColor…` — исключительно в `TrellisRender`.
  Неизвестные атрибуты не получают обещанной семантики; ссылки не становятся
  кликабельными spans без отдельного расширения.
- **D56. Truncation и лимиты.** `maxLines` и высота bounds — два независимых
  ограничителя; `didTruncate` истинен, если сработал любой из них (снимает
  W09/`didTruncate` всегда `false` при `maxLines == nil`). `.exact` ширина
  измерения равна ширине constraint; `.atMost` — `min(natural, max)` (снимает
  #39, где Weave обрабатывал оба одинаково). Пустая строка — одна строка
  высотой `lineHeight`. Детерминизм — обязательный тест: одна и та же
  `TextLayoutInput` даёт тот же `TextMetrics` при 100 последовательных вызовах
  с worker-потока.
  **Уточнено по реализации T12** ([дефект #47](defects.md),
  [t12-scenes-references-docs.md](validation/t12-scenes-references-docs.md)):
  «одна и та же логика переноса для measure и raster» (§3.2
  implementation-plan-4.md) не означает, что коробка высотой ровно в то
  число, которое `measure()` вернул для одной строки, гарантированно
  вмещает эту строку при повторном прогоне через `CTFramesetterCreateFrame`
  в `rasterize()` — на некоторых размерах шрифта `CTFrameGetLines` на
  коробке именно такой высоты возвращал ноль строк вместо одной.
  `rasterize()` теперь строит свой `CGPath` на 1pt выше `request.size.height`
  для этого internal-вызова — не меняя ни то, что репортит `measure()`, ни
  фактический размер битмапы.
  **Уточнено по реализации M08** ([дефект #50](defects.md),
  [m08-close-result-a.md](validation/m08-close-result-a.md)): T12's 1pt-запас
  чинил только однострочный случай — коробка ровно в высоту `maxLines: 2`
  строк иногда всё равно возвращала из `CTFrameGetLines` только одну строку,
  без фиксированного запаса, достаточного для любого N. `rasterize()` больше
  не читает число видимых строк из тесной коробки вообще: unbounded-height
  `probeFrame` (как уже безопасно делает `measure()`) даёт полный список
  строк, `maxLines`/cumulative-height лимитер считается явно в Swift (с
  допуском на float-шум между независимо построенными `CTFrame`), а
  отдельная щедро-высокая `fittingFrame` даёт только числено пригодные
  origins для рисования, сдвинутые обратно в маленькую координатную систему
  битмапы.
- **D57. Accessibility.** `TextNode` при создании и на каждое изменение текста
  выставляет `accessibility.isElement = true`, `label = <plain characters
  документа>`, `role = .text` — но только если автор не задал `label`/`role`
  явно на этом узле (автор побеждает, тот же принцип, что D41/D42 для
  `ControlNode`). Не focusable по умолчанию (D37 не меняется). Без rotors и
  live regions в этой части.
  **Уточнено по реализации T08** ([t08-text-accessibility.md](validation/t08-text-accessibility.md)):
  «автор побеждает» отслеживается тремя приватными теневыми полями на самой
  `TextNode` (`lastAutoIsElement`/`lastAutoLabel`/`lastAutoRole`), а не флагом на
  `AccessibilityProperties` — этот тип общий для всех `Node` и не должен нести
  понятие «автоматическое vs. авторское» ради одного подкласса. Первая версия
  синхронизации безусловно перезаписывала теневое поле после каждого вызова,
  из-за чего авторский override, случайно совпавший с текущим теневым значением
  (после первого же авторского изменения `isElement` — булево поле, всего два
  состояния), «забывался» уже на второй смене текста — найдено регрессионным
  тестом на вторую смену текста до коммита карточки, исправлено: теневое поле
  обновляется только внутри ветки, которая реально написала автоматическое
  значение, и остаётся замороженным, если сработал override.
- **D58. Отмена и владение.** Display-задачи принадлежат `NodeHostBridge`
  через `DisplayTransaction`, не отдельной ноде — тот же принцип, что
  `PointerSessions`/`FocusEngine` (D35): engine хранит `NodeID` и revision,
  никогда closure или живой `Node`. `detach`/`replaceRoot` отменяют всю
  очередь; поздних коммитов в `CALayer` после этого не бывает. `dispose()`
  текстовой ноды отменяет её задачу в scheduler по `nodeID`. Измеритель,
  вызванный solver'ом, проверяет `LayoutContext.checkCancellation()` не реже
  одного раза на строку длинного абзаца.
  **Уточнено по реализации T10** ([t10-lifecycle-and-cancellation.md](validation/t10-lifecycle-and-cancellation.md),
  [дефект #44](defects.md)): `TextNode` не хранит ссылку на `DisplayScheduler`
  (он существует только на стороне `NodeHostBridge`, per-mount), поэтому
  «`dispose()` отменяет свою задачу» реализовано не как метод на `TextNode`, а
  как тот же tree-wide diff, которым `LayerRenderer.removeStaleLayers` уже
  находит более неактивные `NodeID` при каждом коммите — `onNodeRemoved`
  callback, который `NodeHostBridge.attach` подключает к
  `displayScheduler.cancel(nodeID:)`. Это ровно тот же приём, которым
  `scanForDisplayWork` уже находит новую работу (обход всего закоммиченного
  дерева, а не точечное отслеживание одной ноды) — обнаружение утраты, а не
  обретения, происходит тем же проходом. До этой правки удаление ноды
  структурной мутацией (без полного `detach()`) снимало её `CALayer`, но
  оставляло запись в `DisplayScheduler.committedTable`/`activeJobs` навсегда.
- **D59. Совместимость (source-breaking).** `LayoutContentMetrics` получает
  новое поле `measurer` — уже не auto-synthesized `Hashable` по всем
  stored properties (замыкание/протокольный тип не `Hashable`), поэтому
  `Hashable`/`Equatable` пишутся вручную по `(intrinsic, firstBaseline,
  measurer?.identity, measurer?.revision)`. Публичный `init` получает новый
  параметр со значением по умолчанию `nil` — источники не ломаются, mangled
  name меняется (как в ADR 0002/0011). `Node.layoutContentMetrics(for:)`
  остаётся источником `content` для узлов без измерителя. `DirtyReasons`
  получает новый бит `.display`. Подробности — [ADR
  0014](adr/0014-content-measurer-and-display-dirty-reason.md).
- **D60. Эталоны.** Текстовые Playground-сцены получают reference PNG на
  macOS с зафиксированным системным шрифтом и `toolchain.json` SDK pin (тот же
  механизм, что уже используют существующие screenshot-эталоны). Расхождение
  при смене SDK — обновление baseline командой `check_screenshots.py --update
  --review-note <документ>`, а не ослабление сравнения. Simulator-скриншоты
  iOS/tvOS — evidence в отчёте карточки, не CI gate (тот же статус, что и для
  существующих сцен A11/A12).

Совместно с [implementation-plan-5.md](implementation-plan-5.md) D65 (принято
той же карточкой T01/M01): растеризованный текст живёт во внутреннем raster
layer конкретной ноды, внешний node layer остаётся единственным носителем
NodeID/hit-test/AX/sibling order — общий контракт между T07 и M02/M06, не
второй renderer.

## D61–D69 — Простая запись анимации: контракт этапа 5 — принято (M01)

Согласованы 2026-09-12 по [implementation-plan-5.md](implementation-plan-5.md)
§3 после разбора примеров §1 той же карточкой M01
([m01-animation-contract.md](validation/m01-animation-contract.md)) — полный
текст решений (модель/границы D61, область/batching D62, таблица смешения
D63, commit/retry/token D64, текст-не-растягивается D65, retarget/token D66,
lifecycle/Reduce Motion D67, снимки/взаимодействие D68, проверка результата
D69) остаётся в плане 5 как источник; здесь фиксируется только факт приёмки
и единственная найденная при разборе примеров правка.

**Уточнение M01 к D67.** Правило «на suspend активное движение заканчивается
snap'ом; изменения во время suspend накапливают состояние, но анимацию не
сохраняют» явно распространяется на состояние **до первого `attach`**, не
только на `suspend()` после него — `.animate` на ещё не подключённом дереве
мутирует модель (состояние накапливается), но intent-запись не переживает
до первого commit после attach, который поэтому — snap. Не новая ветка
поведения, а закрытие пробела, оставленного текстом D67 как есть (bridge
физически не существует до `attach`, поэтому подхватить такую запись
всё равно некому) — подробности и почему это не покрывалось буквальным
текстом D67 — [m01-animation-contract.md §2.1](validation/m01-animation-contract.md).

D65 отдельно перекрёстно согласован с уже реализованным T07
([t07-text-raster-layer.md](validation/t07-text-raster-layer.md)) — см. также
пометку в конце блока D49–D60 выше; расхождений между текстом решения и
кодом не найдено.

**M06** ([m06-text-card-animation.md](validation/m06-text-card-animation.md)) подтвердил то же
самое ещё раз, но уже при активном M04-переходе, retarget'е (D66) и задержанном raster worker'е
одновременно: D65's raster layer и M04's `LayerAnimator` структурно не пересекаются в
`LayerRenderer.update(node:...)`, поэтому карточка не потребовала изменений в `Sources/` — только
4 новых детерминированных теста на реальном windowed `CALayer`.

**M07** ([m07-scene-readiness.md](validation/m07-scene-readiness.md)) подтвердил D68 (hit-test/
focus/AX/DebugOverlay читают committed target, не presentation) тем же способом — тестами при
активном переходе, без изменений кода — и реализовал D69: `NodeHostBridge.sceneReadiness`/
`waitUntilSceneReady(timeout:)`, три независимые оси (layout/display/animation) поверх новых
`RenderCoordinator.hasPendingLayoutWork`, `DisplayScheduler.pendingJobCount`,
`LayerAnimator.activeCount(mountEpoch:)`. Первая версия `hasPendingLayoutWork` ошибочно включала
`flushScheduled` (housekeeping-flush после каждого коммита давал ложный `false` даже для
тривиальной сцены) — найдено и исправлено первым же тестом, до коммита.

**M08** ([m08-close-result-a.md](validation/m08-close-result-a.md)) закрыл результат A: сцены
S27/S28, `TrellisAppKit`/`TrellisUIKit` получили тонкий passthrough того же D69 API
(`sceneReadiness`/`waitUntilSceneReady`), а `Playground/Shared/Scenario.swift`'s
`waitForRenderReady` — третье условие готовности (`displayReady`), закрывая шов, который T12
оставила для M07/M08. Bench-fixture `animated-text-list-1000` первой подтвердила вживую (не в
XCTest), что настоящий CA completion callback доставляется в обычном standalone-процессе —
частичное закрытие открытого пункта m02-animation-prototype.md §1.4.

**Уточнение M09 к D61** ([m09-spring-animation.md](validation/m09-spring-animation.md)):
`AnimationCurve` получает пятый случай, `.spring(response:dampingFraction:)` — тот же
двух-параметрический вид, что SwiftUI's собственный `.spring(response:dampingFraction:)`,
переводимый в `CASpringAnimation`'s `mass`/`stiffness`/`damping` только в `TrellisRender`
(`LayerAnimator`); `duration` читается из SDK's `settlingDuration`, не угадывается формулой в
модели. Один готовый пресет — `Animation.snappy` — подобран на сцене S27 (карточка теперь
использует его вместо `.smooth`, без изменения самого контракта области/смешения D62/D63).
Retarget (D66), Reduce Motion (D67) и адресный token cleanup (D64) не потребовали отдельного
кода для пружины — оба механизма читают `intent.animation.duration`/`.curve` только внутри
одной новой общей фабрики (`makeAnimation`), не в каждом из четырёх мест `reconcile*`
по отдельности. Закрывает дефект #41 (перенесённый `.spring` ранее молча мапился на
`.easeInEaseOut`).

**Уточнение M02 к D66/D67** ([m02-animation-prototype.md §1.4](validation/m02-animation-prototype.md)):
доставка самого completion-колбэка (`CATransaction.setCompletionBlock` и
`CAAnimationDelegate.animationDidStop` одинаково) не воспроизводится ни в
`swift test`, ни в `xcodebuild test` — колбэк надёжно приходит в обычном
процессе (голый `swift script.swift`), но не внутри XCTest-хостинга, даже
для простейшей неретаргетнутой анимации; при этом `presentation()`'s
значение посреди полёта читается корректно в том же процессе. Причина не
установлена. Контракт D66/D67 не меняется («способ безопасного хопа из CA
callback на MainActor» решён — обычное `@MainActor`-замыкание без unsafe
concurrency обходов компилируется и было бы вызвано тем же путём в реальном
приложении) — сужена только область автоматической проверки: логика
cleanup'а по token проверяется прямым вызовом, реальная сквозная доставка
колбэка остаётся evidence для Playground/M06+, не для модульных тестов на
этом toolchain.

**Реализовано M05** ([m05-reduce-motion-lifecycle.md](validation/m05-reduce-motion-lifecycle.md),
[ADR 0016](adr/0016-node-host-bridge-attach-gains-reduce-motion.md)): `ReduceMotionKey` —
обычный наследуемый environment-ключ (`TrellisCore`), тот же паттерн, что `LocaleKey`/
`TextRendererKey` (T09/ADR 0015). `NodeHostBridge.attach` получил `reduceMotion: Bool? = nil`,
и `updateReduceMotion(_:)` — новый метод, не часть общего `updateBridgeState`, потому что
несёт дополнительное побочное действие «включение посреди полёта» из D67, которого нет у
`updateSafeArea`/`updateLayoutDirection`/`updateLocaleIdentifier`. `LayerRenderer` резолвит
intent в `nil` (не в отдельный объект с `.animation = .none` — `AnimationIntent`'s memberwise
init оказался `internal`, не `package`, так что `TrellisRender` не может его сконструировать
сам; `nil` проходит через тот же snap-путь в `animator.reconcile`, что и настоящий `.none`).
`LayerAnimator.finishAllActive(mountEpoch:layerForNode:)` — новый метод, снимающий каждую
активную явную анимацию текущего mount epoch немедленно; вызывается и из
`NodeHostBridge.suspend()` (закрывает пробел, что suspend раньше останавливал только
intent-bookkeeping M03, но не уже добавленные `CABasicAnimation`), и из `updateReduceMotion`
при включении посреди полёта. Найден один реальный платформенный нюанс, не дефект контракта:
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` идёт через
`NSWorkspace.shared.notificationCenter`, не через `NotificationCenter.default`, в отличие от
всех остальных нотификаций в `TrellisAppKit`'s `TrellisHostView` — `deinit` расширен явным
`removeObserver` на этом отдельном центре.

## D70–D74 — Составной переход: контракт результата B — принято (M10)

Согласованы 2026-09-13 по [implementation-plan-5.md](implementation-plan-5.md) §6
после разбора против сценариев M10 и против реального кода
(`Sources/TrellisRender/LayerAnimator.swift`, `NodeHostBridge.swift`,
`LayerRenderer.swift`, `Display/DisplayScheduler.swift`) этой же карточкой
([m10-transition-contract.md](validation/m10-transition-contract.md)) — полный
текст решений (роли/дубликаты D70, владелец/подготовка/растровая политика D71,
открытие/закрытие/жест D72, взаимодействие/AX/остановка D73, критерий «сложное
стало легко» D74) остаётся в плане 5 как источник; здесь фиксируется факт
приёмки, снятая с них пометка «предложение» и найденные при разборе уточнения.

**Уточнение M10 к D70.** Роль — открытое, не закрытое перечислимое пространство
имён (строковый идентификатор, не замкнутый `enum`): второй сценарий D74
(карточка профиля) требует иного состава общих элементов без правок
coordinator/renderer, что закрытый `enum` ролей сделал бы невозможным.

**Уточнение M10 к D72 — таблица допустимых событий.** D72 сам откладывал эту
таблицу до M10 («Таблицу допустимых событий фиксирует M10»); она приведена
полностью в [m10-transition-contract.md §1.3](validation/m10-transition-contract.md)
— состояния `preparing → opening → presented → interactiveClosing → settling
→ presented/closed`, отмена подготовки, неинтерактивное закрытие, повторное
действие (retarget без второй копии слоёв), потеря source, resize host,
`detach`/`suspend`/Reduce Motion на каждом состоянии.

**Уточнение M10 к D73.** Modal scope для результата B переиспользует
`FocusEngine.setScope(_:)` (D40) буквально, без пересмотра D40 и без нового
API: `presented` открывает scope на корне destination, `settling → closed`
закрывает его — то же `restorationID`-поведение D40 уже даёт даром. Единственное
новое: момент вызова (после `opening`, не в момент `present()`), потому что
`preparing`/`opening` должны оставлять source доступным для отмены запроса
(D71). Скролл-арбитраж D73 сознательно не проверен этой карточкой (статическая
страница в прототипе) и остаётся открытым пунктом M13, как и предполагал текст
D73.

**Найдено при сверке с M01–M09's кодом (не пробел контракта, архитектурные
решения, обязательные для начала M11):** (а) session-геометрия overlay должна
идти отдельным, параллельным `LayerAnimator` explicit-animation путём — временные
слои session не регистрируются в существующем `LayerAnimator.active`
(`(mountEpoch, NodeID, property)`-адресация не подходит слоям без своего
`NodeID`); (б) `NodeHostBridge.sceneReadiness`/D69 обязаны учитывать активную
transition session отдельным источником — иначе `waitUntilSceneReady` вернёт
`true` во время `opening`/`interactiveClosing`, что противоречит D69 буквально.
Подробности и обоснование — [m10-transition-contract.md §3](validation/m10-transition-contract.md).

**Реализовано M11** ([m11-transition-session.md](validation/m11-transition-session.md),
[ADR 0017](adr/0017-node-host-bridge-gains-transition-session.md)): `Role` (`TrellisCore`) —
`String`-подложенный открытый value-тип, не `enum`, ровно как зафиксировала M10 §1.1.
`TrellisRender` получает `TransitionSession`/`TransitionSessionState`/`TransitionSettleTarget`/
`TransitionRoleEndpoints` (форма 1:1 с D71's settled-текстом) и `NodeHostBridge.transitionSession`/
`presentTransition(_:)`/`closeTransition()`. Оба архитектурных решения, которые M10 §3 оставила
M11: session-геометрия анимируется новым, параллельным `LayerAnimator` классом
(`TransitionAnimator`, module-internal), переиспользующим D66's retarget-от-presentation и
stale-token cleanup на грануляции **сессии**, не `(layer, property)`; `sceneReadiness`'s
`animationReady` получил второй, параллельный источник (`isTransitionSessionInFlight`) вместо
смешивания с `LayerAnimator.active` — выбран вариант «б» из двух, названных M10. D71's открытый
пункт (crop/fit для картинки) закрыт: не-текстовая роль читает `contentsGravity`/`contents`
ровно один раз на подготовке. D73's modal scope — `FocusEngine.setScope(_:)` буквально, на
границе `opening→presented`/`settling→closed`; одна логическая AX-репрезентация — через уже
существующий `AccessibilityChildrenPolicy.hide` (D42), не новый механизм. Таблица состояний
D72 реализована как есть (карточка не подключает `interactiveClosing` к живому жесту — M12);
`.expand`'s открытие/закрытие кнопкой проверено сквозь настоящий `NodeHostBridge` и реальный
`CoreTextRenderer` (7 новых тестов, `M11TransitionSessionTests.swift`, весь пакет — 676/676
зелёных). Ни один реальный дефект поведения не найден.

**Реализовано M12** ([m12-progress-and-gesture.md](validation/m12-progress-and-gesture.md),
[ADR 0018](adr/0018-transition-gesture-progress-api.md)): `TransitionAnimator` (M11) получает
manual-режим — `arm`/`freezeForGesture`/`scrub`/`endManual` — параллельный `play`'s
retarget-от-presentation, тем же `speed = 0` + `timeOffset` приёмом, что доказал прототип M10 §2,
перенесённым из исследовательского кода в production. `NodeHostBridge` получает
`beginTransitionGesture()`/`updateTransitionGesture(deltaProgress:)`/
`endTransitionGesture(velocity:preset:)`/`cancelTransitionGestureSystemInterrupted()` и
`TransitionGesturePreset` (пороги D72, по умолчанию progress 0.5/velocity 1.2 в согласованных
единицах — доля прогресса в секунду). Оба входа в `interactiveClosing` реализованы: жест,
захвативший ещё летящий `opening` (progress продолжает расти от текущего — вычисляется как доля
уже прошедшего реального времени, не сбрасывается), и свежий dismiss-жест из `presented`
(progress стартует с 0 по той же логике, что уже была у `closeTransition()`). Возврат к
автоматике — обычный повторный вызов `buildTransitionVisuals`/`TransitionAnimator.play`,
retarget-от-presentation уже даёт непрерывность бесплатно, отдельного механизма не потребовалось.
D72's таблица событий реализована буквально, включая её собственное предупреждение о том, что
слова «finish»/«cancel» именуются по итогу жеста закрытия, а не сами по себе (см. M10 §1.3) —
публичный API называет исходы `TransitionSettleTarget.presented`/`.closed`, не повторяя эти два
слова как словарь. Системная отмена жеста (`UIGestureRecognizer.state == .cancelled`,
right-click/Escape для `NSPanGestureRecognizer`) — задокументированное решение реализации (D72
не перечисляет это событие явно): всегда `.presented`, не часть пересмотра таблицы. `TrellisUIKit`/
`TrellisAppKit` получают узко ограниченный `TransitionGestureController`, привязывающий один
`UIPanGestureRecognizer`/`NSPanGestureRecognizer` к неподвижной host-overlay области (D73) и
транслирующий его собственные `translation`/`velocity` в вызовы `NodeHostBridge` — не полная
touch/pointer/tvOS-remote история (M13). 10 новых детерминированных тестов
(`M12TransitionGestureTests.swift`): scrub/reversal, идемпотентность повторного
`beginTransitionGesture()`, граничные пороги progress и velocity ровно на границе и чуть за ней,
системная отмена, оба направления входа в жест, полный цикл finish/cancel с настоящим текстом.
Честно зафиксировано: реальный `NSPanGestureRecognizer`, управляемый синтетическими `NSEvent`
(`NSWindow.sendEvent(_:)` и прямой вызов `NSView.mouseDown/mouseDragged/mouseUp`), не запускает
recognizer's action в headless `swift test`-процессе на этом toolchain (проверено, не
предположено) — тот же класс ограничения, что M02 §1.4 задокументировала для CA completion
callbacks, только для gesture recognizer state delivery, а не для анимации. Подробности —
[m12-progress-and-gesture.md](validation/m12-progress-and-gesture.md).

**Реализовано M13** ([m13-transition-lifecycle-and-platforms.md](validation/m13-transition-lifecycle-and-platforms.md),
[ADR 0019](adr/0019-trellis-host-view-transition-forwarding.md)): D73's полный проход — modal
scope/focus restoration/единственное AX-представление/блокировка background подтверждены и
через M12's новые gesture-состояния (`interactiveClosing` из обоих входов), не только через
M11's исходный кнопочный путь; suspend/detach проверены на каждой добавленной M12 фазе.
`NodeHostBridge` получает `reconcileTransitionGeometryIfNeeded()`, вызываемый на каждом реальном
commit (никогда per-frame): host resize mid-transition ретаргетит геометрию под новый layout без
переоткрытия сессии, а source, пропавший во время closing (M11 покрывала только `preparing`),
переключает роль на fade вместо полёта к устаревшему прямоугольнику (D72). `TrellisHostView`
(`TrellisUIKit`/`TrellisAppKit`) получает тонкий passthrough к
`presentTransition`/`closeTransition`/четырём gesture-методам — тот же D69-прецедент, что уже
установила M08 для `sceneReadiness`/`waitUntilSceneReady` — впервые делающий `NodeHostBridge`'s
transition/gesture API достижимым извне `TrellisRender`'s собственного test target. Реальный
`UIPanGestureRecognizer`/`NSPanGestureRecognizer` на новой Playground-сцене S29
(`Playground/Shared/Scenarios/S29_ExpandTransitionPlatforms.swift`), прогнанной на iPhone 17 Pro
Simulator, довёл открытие/закрытие `.expand` до конца — конкретный пробел, который M12's report
называл прямо. Этот прогон нашёл и закрыл два реальных дефекта, ни один из которых не ловился
детерминированными тестами (`docs/defects.md` #53/#54): скрытие source/destination прямой
записью `CALayer.opacity` тихо отменялось следующим paint-only commit'ом
(`LayerRenderer.setTransitionHidden`/`transitionHiddenNodeIDs` делают скрытие частью того же
вычисления, что и обычная presentation); слой, отданный обратно автоматическому воспроизведению
после жеста, оставался на `speed = 0` и никогда не завершал анимацию
(`TransitionAnimator.play` теперь безусловно нормализует `speed`/`timeOffset`/`beginTime`).
D25/D34/D40/D46 перечитаны целиком перед реализацией и подтверждены не изменёнными — ни один не
затронут этим diff'ом (подробное обоснование по каждому — отчёт §5). Скриншот-эталоны для S29 не
сняты — зафиксировано как честный пробел, не скрыто (отчёт §3.3).

**Реализовано M14** ([m14-close-result-b.md](validation/m14-close-result-b.md),
[ADR 0020](adr/0020-transition-role-interval.md)) — закрывает результат B целиком. D74's
критерий («две разные сцены используют один механизм... нет CALayer, координатной
арифметики, ручных таймеров, snapshot-копий или cleanup в consumer-коде... отличия второй
сцены задаются данными/композицией без правок coordinator/renderer») проверен буквально
двумя новыми Playground-сценами, написанными как внешний потребитель: S30 (редакционная
карточка → статья: большое изображение, существенный текст тела, роль без source
использует fade на полном диапазоне) и S31 (карточка профиля → профиль: круглая геометрия,
другое расположение элементов с каждой стороны, роль без source использует fade,
confined к `interval: 0.5...1`). Единственная правка `Sources/` — `TransitionRoleMapping`/
`TransitionRoleEndpoints` получили общее (не специфичное для S31) поле `interval:
ClosedRange<Double>?`, проведённое до `TransitionAnimator.Target.beginProgress`/
`endProgress`: реализует буквально пропущенную до сих пор половину D70's текста
(«собственные интервалы и кривые внутри него») через `CAKeyframeAnimation` на том же
`timeOffset`-домене, что и остальная сессия — не второй механизм тайминга. Найден и
исправлен один реальный дефект до коммита (`docs/defects.md` #55): дублирующий граничный
keyframe замораживал анимацию роли с `endProgress == 1` на стартовом значении. Своя
Bench-фикстура (`transition-open-close`) даёт первые числовые замеры результата B
(prepare/arm под миллисекунду, ноль утечек слоёв после `detach()`); честно
зафиксировано, что M10's собственный отчёт не оставил числового бюджета для сравнения,
вопреки тексту плана. Видео движения недоступно (в репозитории нет инструментария
захвата экрана) — заменено deterministic progress samples, зафиксировано как честная
оговорка, не как выполненное требование.

**R09 — ADR 0029** ([scroll-gesture-arbitration.md](adr/0029-scroll-gesture-arbitration.md))
фиксирует направление, единственного владельца delta, boundary/momentum handoff и приоритет
scroll над закрытием presented transition.

**R10 — ADR 0030** ([collection-data-contract.md](adr/0030-collection-data-contract.md))
фиксирует композицию контейнера со своим ScrollNode, `CollectionSnapshot` с first-wins для
дублей, `StateSubject` как DataSource, `ItemProvider`/dispatcher, окна материализации,
кэш измерений по `layoutRevision`, `PaginationGate` с trigger по умолчанию в две высоты
viewport, `CollectionLoader` для hooks и общий `MaterializationBudget` хоста.

**R11 — ADR 0031** ([collection-transactions.md](adr/0031-collection-transactions.md))
фиксирует якорь (верх элемента у верхнего края viewport, сосед по старому порядку, clamp),
`CollectionAdjustment`, подготовку на воркере с атомарным commit и отклонением устаревших
результатов, очередь с одной ожидающей позицией и ID-based `CollectionDelta`.

**R12a — ADR 0032** ([hosted-collection-containers.md](adr/0032-hosted-collection-containers.md))
фиксирует протоколы `HostedContainer`/`ContainerHost` (bridge находит контейнеры после
commit, связывает состояние через `bindState`, ведёт общий бюджет) и сдвиг native offset в том
же geometry commit, разрешённый во время жеста. Уточнение ADR 0026: направление `ScrollNode`
следует за осью, авторазмер viewport ограничен родителем (#84/#86).

**R12b — ADR 0033** ([grid-node.md](adr/0033-grid-node.md)) фиксирует ряды как прокручиваемую
единицу окна, `GridLayout` (fixed/adaptive колонки, measured/aspect высота), общий расчёт
геометрии и `CollectionNode` как единственный runtime для ListNode и GridNode.

**R12c — ADR 0034** ([table-node.md](adr/0034-table-node.md)) фиксирует строки таблицы с
контекстом секции через преобразование источника, заголовок секции в первой строке,
горизонтальный распознаватель, `RowSwipeController` (одна открытая строка, full swipe,
ошибка/повтор), политики swipe с `RowSwipeContextKey` и AX custom actions как путь без жеста.

**R12 — ADR 0035** ([collection-reveal-and-row-focus.md](adr/0035-collection-reveal-and-row-focus.md))
фиксирует `scrollTo(_:)` контейнеров с результатом completed/cancelled/notFound/notAttached
(повтор reveal после измерения, только последняя команда), `ContainerHost.scrollContainer`,
строку таблицы как `ControlNode` (фокус пульта/клавиатуры, активация = выбор) и закрытие
открытого swipe при вытеснении строки. Закрывает результат C вместе с исправлением #88.

**R13 — ADR 0036** ([pager-and-tabs.md](adr/0036-pager-and-tabs.md)) фиксирует решения
пользователя (собственный pan, смонтированы выбранная ±1), pager поверх собственного
горизонтального `ScrollNode` (нативная вложенность страниц, #91), `ScrollCommand.timed` для
общей кривой страниц и индикатора, один `PagerProgress`, `PageStateRestoring` для состояния
вытесненных страниц и `RowSwipeContextKey = false` для страниц.

**R14 — ADR 0037** ([tabbed-scroll-coordination.md](adr/0037-tabbed-scroll-coordination.md))
фиксирует решения пользователя (2026-09-23, вариант Telegram): внешний вертикальный `ScrollNode`
с шапкой и блоком «вкладки + pager» в высоту viewport ниже линии закрепления; прокрутка
страниц выключена до закрепления; при раскрытии шапки наверх возвращается только выбранная
страница; выбор глубокой страницы закрепляет вкладки. Уточнение ADR 0029: односторонняя передача
инерции внешний → выбранная страница только в точке закрепления, вторым этапом R14.

Прототип ([TransitionOverlayPrototypeTests.swift](../Tests/TrellisRenderTests/TransitionOverlayPrototypeTests.swift),
4 теста, только `QuartzCore`/`Foundation`+`AppKit`/`UIKit`, без `TrellisCore`/
`TrellisRender`) подтвердил реальным `CALayer`/`CABasicAnimation` (`speed = 0` +
`timeOffset`, тот же `WindowHost`-паттерн, что M02): общий progress на
нескольких слоях одной сессии, два endpoint-растра заголовка с crossfade без
повторной растеризации на кадр (D71), непрерывный (без скачка) разворот
направления посреди движения от текущего видимого положения (D72). Найден и
исправлен реальный баг прототипа до коммита: свежесозданное окно требует
одного прогревочного display pass, прежде чем `presentation()` надёжно
отражает уже записанный `timeOffset` — отдельный, более узкий случай того же
класса проблем, что M02 §2 нашла для `add(_:forKey:)` (прогрев процесса, не
прогрев конкретного окна). Подробности — [m10-transition-contract.md §2.3](validation/m10-transition-contract.md).

## Статус решений плана

| Решение | Статус | Что зависит |
|---|---|---|
| D02. Модель нод, NodeID | **принято** (см. выше) | C06, C08 |
| D08. Граница scheduler/движок | **исчерпано D11**: разделение и internal-протокол `LayoutEngine` зафиксированы там. Отдельного открытого пункта не осталось — «без публичного registry/kind до второго движка» следует из того, что Grid вне этапа 1 | C12, C13 |
| D07. Корень и хост | **принято в C17**: bridge сильно удерживает root до `detach`; один root принадлежит только одному bridge, второй `attach` отклоняется без мутации | C17 |
| D04. Владение стилем (base/effective) | **принято** (см. выше) | C07, C21, C23 |
| D05. Владение деревом Arrangement | **принято** (см. выше) | C21, C23 |
| D06. Identity wrappers | **принято** (см. выше) | C21, C23 |
| D12. Композиция effective style | **принято** (см. выше) | C23, C24, C29 |
| D13. Автоматический resolve Arrangement | **принято** (C32) | C32, C29 |
| D14. Источник состояния и владелец подписки | **принято** (C29) | C29, N04 |
| D15. Wrapper'ы без CALayer — не по умолчанию | **принято** (C30) | C26, этап 2 |
| D16–D34. Hit-testing и события | **принято** (H01, см. выше); D18/D24/D26 и части D30/D32 — записанные ограничения | H02–H11 |
| D35–D48. Focus engine и accessibility | **принято** (A01, см. выше); D24 снят только для нового tvOS пути | A02–A13 |
| D49–D60. Текст и измерение содержимого | **принято** (T01, см. выше); §3.3 решено в D55 | T02–T12 |
| D61–D69. Простая запись анимации | **принято** (M01, см. выше); уточнение M01 к D67 (suspended до первого attach) | M02–M09 |
| D70–D74. Составной переход (результат B) | **закрыто M14** (см. выше): D74's критерий проверен двумя внешне-написанными сценами (S30/S31); уточнения к D70 (открытые роли — M10; собственные интервалы/кривые внутри unified progress — `interval`, M14), D72 (таблица событий; жестовый finish/cancel реализован M12), D73 (момент открытия modal scope — M10; host resize/source-disappears/lifecycle — M13) | — |

Эксперимент C30 не означает утверждение обязательного удаления CALayer у layout-контейнеров. Согласование среза не утверждает все остальные детали API автоматически.
