# R06 — P6.3 как контракт: API sketch (предложение)

Фиксирует implementation-plan-6.md's P6.3 чек-лист R06: «constraints, coordinate
spaces, native backing ownership, clipping/z-order, insets, phases, command
acknowledgement и feedback suppression». Формат — как [t01-text-contract.md](t01-text-contract.md):
API sketch + таблица владения + таблица ожидаемых результатов, код здесь не
реализован. Это **предложение**, не D-решение (implementation-plan-6.md intro:
«Предложения P6 не становятся D-решениями автоматически») — конкретные типы
ниже требуют обсуждения перед переносом в decisions.md; используются для
специфицирования R07's реализации.

Опирается на: [weave-scroll-analysis.md](../weave-scroll-analysis.md) (что уже
формализовано в Weave), [scroll-configuration.md](../scroll-configuration.md)
(§1.2 конфигурация — не повторяется здесь), [r06-scroll-contract.md](r06-scroll-contract.md)
(native embedding прототип), D17/D18 ([decisions.md](../decisions.md)).

## 0. Что уже существует в коде и что это меняет

`OverflowPolicy.scroll` (`Sources/TrellisCore/Layout/LayoutStyle.swift`) уже
объявлен и уже участвует в hit-test clipping (D17, `Sources/TrellisCore/
HitTesting/HitTest.swift`) — но `LayerRenderer.applyPresentation`
(`Sources/TrellisRender/LayerRenderer.swift:671`) сегодня обрабатывает
`.scroll` **идентично** `.hidden` (`masksToBounds = true`, ничего больше).
Значит `.scroll` зарезервирован кодом, но не реализован: этот контракт
специфицирует, что должно произойти в той же точке `applyPresentation`,
когда `.scroll` перестаёт быть синонимом `.hidden`.

## 1. Coordinate spaces

Три пространства, одна пара конверсий — прямая проверка требования P6.3
(«одна проверяемая конверсия для hit testing, focus, AX, reveal и переходов»):

- **Host space** — существующее пространство `TrellisHostView`/committed frame
  (origin top-left, points), ничего нового.
- **Content space** — координаты детей ScrollNode ровно так, как их уже даёт
  `calculatedFrame` **сегодня**, без изменений: R06's прототип
  ([r06-scroll-contract.md](r06-scroll-contract.md)) показал, что
  `host.layer.bounds.origin` не меняется прокруткой — то есть content space
  **уже равно** обычному Trellis-координатному пространству committed frames.
  ScrollNode ничего не переопределяет здесь; оно лишь **не видно снаружи** за
  пределами viewport space.
- **Viewport space** — content space минус текущий `offset`: `viewportPoint =
  contentPoint - offset`. Единственная новая конверсия, обе стороны которой
  тривиальны и не должны дублироваться в трёх разных местах (hit-test,
  reveal, AX) отдельными формулами.

```swift
public struct ScrollState: Sendable, Hashable {
    public let offset: LayoutPoint          // content space, clamped
    public let contentSize: MeasuredSize    // content space extent
    public let viewportSize: MeasuredSize
    public let phase: ScrollPhase           // §4
    public let isUserDriven: Bool           // §7 — feedback suppression flag
    public let revision: UInt64

    public func viewportPoint(fromContent point: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: point.x - offset.x, y: point.y - offset.y)
    }
    public func contentPoint(fromViewport point: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: point.x + offset.x, y: point.y + offset.y)
    }
}
```

## 2. Constraints

Поперечная ось — definite constraint от viewport'а (обычный `.exact`, как
любой другой ограниченный размер сегодня). Продольная (прокручиваемая) ось —
`.unspecified` на измерении контента, тот же max-content basis, что ADR 0009
уже использует для auto-sized контента (`FlexboxMeasure`), не новый вид
constraint. Явное следствие: `flexGrow`/`.fraction` вдоль прокручиваемой оси
внутри ScrollNode's ребёнка не имеет базы для резолва (нет definite parent
size) — по аналогии с уже существующим правилом для `.unspecified` в
`FlexboxMeasure.availableSpace`, это **не ошибка**, а диагностируемый
edge-case: `.fraction` вдоль неограниченной оси резолвится в `0` с
диагностикой через `Log.on(.measure, …)`, а не отбрасывается молча (то самое
«явная поддержка/диагностика», которую implementation-plan-6.md §1.2 требует
для платформенных ограничений — здесь тот же принцип для layout-ограничений).

## 3. Native backing ownership

`ScrollNode` не хранит native scroll view — это делает **renderer**, не
`TrellisCore` (D16's слоение: чистая математика в Core, материализация в
Render/адаптерах). Параллельная структура к уже существующим
`rasterLayers`/`transitionRasterLayers` (T07/M11):

```swift
// TrellisRender (CoreGraphics/QuartzCore only) — платформо-нейтральная граница,
// реализуется TrellisUIKit/TrellisAppKit (тот же паттерн, что EdgePullContainer
// в Weave, SwipeRevealContainer, TransitionAnimator).
@MainActor
public protocol NativeScrollBacking: AnyObject {
    var viewportSize: MeasuredSize { get }
    var contentOffset: LayoutPoint { get set }   // §7: native — источник истины, пока isUserDriven
    func setContentSize(_ size: MeasuredSize)
    func setInsets(_ insets: DirectionalEdgeInsets)         // scroll-configuration.md §2.2, один раз
    func installContentLayer(_ layer: CALayer)              // ScrollNode's children живут здесь
    func removeContentLayer()
    func scroll(to offset: LayoutPoint, animated: Bool, completion: @escaping (Bool) -> Void)
    // Колбэки к владельцу — не входят в протокол (adapter держит weak back-reference
    // к LayerRenderer/NodeHostBridge и зовёт его напрямую, как EdgePullContainer уже делает).
}
```

`LayerRenderer` получает `scrollBackings: [NodeID: any NativeScrollBacking]`
(тот же lifecycle, что `rasterLayers`: создаётся при первом committed
`.scroll`-узле, снимается в `removeStaleLayers`/`unmount()`, T07-style). Фабрику
конкретного backing'а (`UIScrollView`/`NSScrollView`-обёртки) передаёт
адаптер через `NodeHostBridge.attach(...)` тем же путём, что `textRenderer`
(D51) — не глобальный реестр, не отдельный параметр на `ScrollNode`.

Одна нода — один backing — одно content-поддерево. Диспоз backing'а
(`removeContentLayer()` + adapter снимает native view) происходит там же, где
сегодня снимается обычный `CALayer` при исчезновении ноды из committed дерева
(`LayerRenderer.removeStaleLayers`, T10's `onNodeRemoved` hook) — не отдельный
путь очистки.

## 4. Clipping/z-order

`.scroll` перестаёт быть синонимом `.hidden` **только** в
`applyPresentation`'s renderer-ветке (§0): вместо `layer.masksToBounds =
true` на обычном `CALayer`, узел получает свой `NativeScrollBacking`, который
адаптер вставляет в дерево **в том же sublayer-слоте**, где обычный
clip-layer был бы — та же позиция среди siblings, тот же `zPosition`
(`node.style.visual.zIndex` по-прежнему применяется к самому backing'у, не
игнорируется). D17's обход и AABB-оптимизация не меняются: `.scroll` уже
сегодня участвует в clip-логике hit-test наравне с `.hidden`
(`HitTest.swift:46/120/157`) — этот sketch не трогает эту часть, только то,
что рисует renderer.

Дети ScrollNode — сублейеры content-layer'а, который держит backing, не
прямые сублейеры родителя ScrollNode в общем дереве. Z-order **внутри**
content-layer не отличается от обычного порядка (`orderOwnedChildren`,
существующий код) — единственное новое: сам content-layer управляется
native view, а не напрямую `LayerRenderer`.

## 5. Insets

`ScrollConfiguration.contentInsets`/`insetsSafeArea`
([scroll-configuration.md](../scroll-configuration.md) §2.2) передаются
backing'у через `setInsets(_:)` при каждом коммите, где они изменились — та
же `DirectionalEdgeInsets`, что `Node.setSafeAreaInsets` уже использует для
всего остального дерева, не отдельная left/right пара. Backing применяет их
как native contentInset-эквивалент (`UIScrollView.contentInset`/
`NSScrollView`'s content insets) — Trellis не вычисляет клиппинг вручную по
insets, native делает это как для любого своего content view.

## 6. Phases

```swift
public enum ScrollPhase: Sendable, Hashable {
    case idle
    case dragging          // user touch/trackpad actively moving offset
    case decelerating      // native momentum after release
    case settling          // programmatic scroll(animated: true) in flight
    case programmatic       // scroll(animated: false) — synchronous, phase visible for one revision only
}
```

Backing репортит переходы через существующий host callback pattern
(`rootNode.onScrollStateChanged?`-подобный, Weave's уже был такой хук) —
`NodeHostBridge` собирает их в `ScrollState.phase` на каждый коммит. `idle →
dragging` и `dragging → decelerating`/`idle` — целиком native (backing
слушает `UIScrollViewDelegate`/`NSScrollView` notification эквиваленты);
Trellis не инициирует и не может инициировать эти переходы сам — только
читает их.

## 7. Command acknowledgement

Weave's `scroll(_:) -> ScrollState` (weave-scroll-analysis.md §2) возвращает
**синхронно** — корректно для его синтетического, полностью Trellis-owned
offset, но не подходит native backing: `animated: true` завершается позже,
пользовательский ввод может прервать программную команду (P6.3: «отмена
programmatic scroll пользовательским вводом»). Явное подтверждение вместо
синхронного возврата:

```swift
public enum ScrollCommandOutcome: Sendable, Hashable {
    case completed(ScrollState)
    case supersededByLaterCommand
    case cancelledByUserInput
    case notAttached          // до первого коммита/после detach — тот же случай, что P6.9's notFound
}

public struct ScrollCommandToken: Sendable, Hashable { let id: UInt64 }

@MainActor
public protocol ScrollCommandIssuing: AnyObject {
    @discardableResult
    func scroll(
        _ command: ScrollCommand,
        completion: (@MainActor (ScrollCommandOutcome) -> Void)?
    ) -> ScrollCommandToken
}
```

Только последний выданный `ScrollCommandToken` может завершиться
`.completed` — более ранний либо получает `.supersededByLaterCommand`
(немедленно, синхронно с выдачей нового), либо `.cancelledByUserInput`, если
пользователь начал жест раньше завершения. Ни один command не остаётся без
терминального колбэка — то самое «ни один поздний callback не остаётся
подвешенным», что уже приняты D21/D34 для pointer-сессий, здесь тот же
принцип для scroll-команд.

## 8. Feedback suppression

Пока `ScrollState.isUserDriven == true` (жест/деселерация активны — `phase
∈ {.dragging, .decelerating}`), **native — источник истины**: Trellis читает
`backing.contentOffset` и публикует его в `ScrollState`, но никогда не
пишет `contentOffset` обратно тем же тиком (иначе — дребезг между двумя
владельцами одного числа, ровно то, чего P6.3 требует избежать: «Публикация
состояния потребителю может coalesce; begin/end/cancel не теряются»). Запись
в `backing.contentOffset` разрешена **только** из `ScrollCommand`-обработчика
(§7) и **только** когда `isUserDriven == false` — попытка выдать
program­матическую команду во время активного жеста немедленно возвращает
`.cancelledByUserInput`, не ставится в очередь поверх активного native input.

Публикация `stateChanges`-потока (Weave's `ActionPipe<ScrollState>`,
переносится как контракт без изменений по форме) coalesce'ится на кадр
commit'а — не на каждый native delegate callback: `UIScrollViewDelegate.
scrollViewDidScroll` может звать чаще, чем Trellis готова закоммитить новый
`ScrollState.revision`, и лишние промежуточные значения не обязаны быть
видны подписчику, только последнее актуальное на момент коммита.

## 9. Владение

| Объект | Владелец | Хранит | Точка отмены |
|---|---|---|---|
| `ScrollState`/`ScrollPhase`/`ScrollCommand`/`ScrollCommandOutcome` | value types, не владеются | — | не применимо |
| `NativeScrollBacking` реализация (`UIScrollView`/`NSScrollView` обёртка) | `TrellisUIKit`/`TrellisAppKit` адаптер | native view, content layer reference | снятие ноды из committed дерева (T07-style), `detach()`, `replaceRoot` |
| `LayerRenderer.scrollBackings[NodeID]` | `LayerRenderer` | ссылка на `any NativeScrollBacking` | `removeStaleLayers`, `unmount()` |
| `ScrollCommandToken`/pending completion | вызывающая сторона держит токен; `NodeHostBridge` держит completion closure до терминального исхода | closure | завершение (любой из 4 исходов §7), `detach()` — оставшиеся получают `.notAttached` |
| `stateChanges`/аналог `ActionPipe<ScrollState>` | `ScrollNode` (как в Weave) | bounded pipe | `dispose()` |

## 10. Ожидаемые результаты (сценарии для тестов R07)

| # | Сценарий | Ожидание | Закрывает |
|---|---|---|---|
| 1 | ScrollNode вложен на глубине 3 внутри обычного дерева (не единственный child host'а) | `NativeScrollBacking` вставлен в native view hierarchy на позиции ScrollNode's committed frame; z-order соседей ScrollNode не нарушен | §4 |
| 2 | Пользователь начинает drag во время активной программной анимации `scroll(.to(...), animated: true)` | Программная команда получает `.cancelledByUserInput` немедленно; жест продолжается нормально, offset не «прыгает» к недостигнутой цели | §7, P6.3 |
| 3 | Два `scroll(...)` подряд без ожидания завершения первого | Первый — `.supersededByLaterCommand` синхронно со вторым вызовом; второй — единственный, который может завершиться `.completed` | §7 |
| 4 | `contentInsets` меняется, пока `phase == .decelerating` | Momentum не сбрасывается (native продолжает деселерацию по старой физике), offset корректируется по clamp-with-anchor (scroll-configuration.md §4) на следующий коммит | §5, scroll-configuration.md §4 |
| 5 | Ребёнок ScrollNode с `flexGrow`/`.fraction` вдоль прокручиваемой оси | Резолвится в `0` с диагностикой `Log.on(.measure, …)`, не отбрасывается молча и не крашит solve | §2 |
| 6 | `reveal(frame:alignment:)` вызван на ноде, уже видимой в viewport | `.completed` без видимого движения offset (nearest-alignment уже на месте) — синхронный терминальный исход, не «no-op без колбэка» | §7, P6.9 |
| 7 | `detach()` вызван, пока `ScrollCommandOutcome` ещё не пришёл | Pending completion получает `.notAttached` до возврата из `detach()`, не после | §7, §9 |
| 8 | `hitTest`/`reveal`/AX-запрос на точку внутри viewport сразу после программного `scroll(.to(...))` (offset уже применён native, но `ScrollState.revision` ещё не закоммичен) | Использует `backing.contentOffset` (текущий native, не устаревший `ScrollState`) для конверсии — одна и та же конверсия §1, не два разных источника offset для разных подсистем | §1, P6.3 |

## 11. Открытые пункты (не решены этим документом)

- Арбитраж вложенного scroll (внешний ScrollNode vertical vs вложенный
  ScrollNode/список тоже vertical) — R09, использует `ScrollPhase`/
  `isUserDriven` отсюда как входные данные, но саму арбитражную функцию не
  специфицирует этот документ.
- Как именно `NativeScrollBacking`'s фабрика передаётся через
  `NodeHostBridge.attach(...)` (новый параметр vs environment key,
  D51-подобный) — реализационная деталь R07, не зафиксирована здесь.
- Виртуализация (P6.4/R10) — content-layer выше специфицирован как «дети
  ScrollNode», не как «materialized window»; когда появится виртуализация,
  content-layer держит только materialized поддиапазон, что не противоречит
  этому sketch (content space остаётся тем же самым пространством, только
  часть его временно не имеет committed layer).
- tvOS: `NativeScrollBacking` для tvOS — что именно это оборачивает (нет
  `UIScrollView` в привычном touch-driven смысле; focus-driven reveal —
  единственный реальный путь) не решено; scroll-configuration.md §3 уже
  отмечает «н/п» для tvOS-жеста, но не говорит, чем backing на tvOS является
  технически.
