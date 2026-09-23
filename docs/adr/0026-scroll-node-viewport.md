# ADR 0026 — `ScrollNode` и viewport pipeline

Дата: 2026-09-16. Карточка R07 (`docs/implementation-plan-6.md`, план 6).
Зависимость: R06. Ратифицирует контракт, предложенный
[r06-scroll-api-sketch.md](../validation/r06-scroll-api-sketch.md), с уточнениями,
найденными при реализации (§ ниже) — см.
[r07-scroll-node.md](../validation/r07-scroll-node.md) за полную evidence-запись.

## Изменение

Новые public типы, пять модулей:

```swift
// TrellisCore/Scroll/ScrollTypes.swift
public enum ScrollAxis: Sendable, Hashable { case vertical, horizontal, both }
public enum ScrollAlignment: Sendable, Hashable { case nearest, start, center, end }
public enum ScrollPhase: Sendable, Hashable { case idle, dragging, decelerating, settling, programmatic }

public struct ScrollState: Sendable, Hashable {
    public let offset: LayoutPoint
    public let contentSize: MeasuredSize
    public let viewportSize: MeasuredSize
    public let phase: ScrollPhase
    public let isUserDriven: Bool
    public let revision: UInt64
    public init(offset:contentSize:viewportSize:phase:isUserDriven:revision:)
    public static func clamp(_:contentSize:viewportSize:) -> LayoutPoint
    public var visibleContentFrame: LayoutFrame { get }
    public func viewportPoint(fromContent:) -> LayoutPoint
    public func contentPoint(fromViewport:) -> LayoutPoint
    public func revealOffset(for:alignment:) -> LayoutPoint
}

public enum ScrollCommand: Sendable, Hashable {
    case to(LayoutPoint, animated: Bool)
    case by(LayoutPoint, animated: Bool)
    case reveal(frame: LayoutFrame, alignment: ScrollAlignment, animated: Bool)
}
public enum ScrollCommandOutcome: Sendable, Hashable {
    case completed(ScrollState), supersededByLaterCommand, cancelledByUserInput, notAttached
}
public struct ScrollCommandToken: Sendable, Hashable { public let id: UInt64 }

public enum ScrollIndicatorPolicy: Sendable, Hashable { case automatic, hidden }
public enum ScrollBouncePolicy: Sendable, Hashable { case automatic, always, never }
public enum KeyboardDismissPolicy: Sendable, Hashable { case none, interactive, onDrag }
public struct ScrollConfiguration: Sendable, Hashable { /* axis, userInteractionEnabled,
    directionalLockEnabled, indicators, contentInsets, insetsSafeArea, bounce,
    keyboardDismissMode */ }

// TrellisCore/Scroll/ScrollNode.swift
@MainActor
open class ScrollNode: Node {
    public var configuration: ScrollConfiguration
    public private(set) var state: ScrollState
    public var onScrollStateChanged: (@MainActor (ScrollState) -> Void)?
    public func publish(_ newState: ScrollState)
}

// TrellisRender/Scroll/NativeScrollBacking.swift
@MainActor
public protocol NativeScrollBacking: AnyObject {
    var containerLayer: CALayer { get }
    func setFrame(_ frame: LayoutFrame)
    var viewportSize: MeasuredSize { get }
    var contentOffset: LayoutPoint { get set }
    func setContentSize(_ size: MeasuredSize)
    func setInsets(_ insets: DirectionalEdgeInsets)
    func installContentLayer(_ layer: CALayer)
    func removeContentLayer()
    func scroll(to offset: LayoutPoint, animated: Bool, completion: @escaping @MainActor (Bool) -> Void)
}
@MainActor
public protocol NativeScrollBackingDelegate: AnyObject {
    func scrollBacking(for node: NodeID, didChangeOffset offset: LayoutPoint, phase: ScrollPhase)
}
public typealias NativeScrollBackingFactory =
    @MainActor (_ node: NodeID, _ delegate: any NativeScrollBackingDelegate) -> any NativeScrollBacking

@MainActor
public protocol ScrollCommandIssuing: AnyObject {
    @discardableResult
    func scroll(_ command: ScrollCommand, on node: ScrollNode,
                completion: (@MainActor (ScrollCommandOutcome) -> Void)?) -> ScrollCommandToken
}
extension NodeHostBridge: ScrollCommandIssuing, NativeScrollBackingDelegate {}
```

`NodeHostBridge.attach(...)` gains one new optional parameter,
`scrollBackingFactory: NativeScrollBackingFactory? = nil` (D51's precedent —
`textRenderer` and `localeIdentifier` already thread through the same call).
`HitTestSnapshot` gains `public let scrollOffsets: [NodeID: LayoutPoint]`, an
`init(...scrollOffsets:)` default parameter, `withScrollOffsets(_:) ->
HitTestSnapshot`, and `liveNode(for:under:)`. `HitTest.swift`'s `.scroll`
branch is no longer a synonym for `.hidden`: it clips like `.hidden` still
does, but translates the point into content space by the node's own
`scrollOffsets` entry before recursing into children (D18). Two concrete
backings, gated behind their platform's `#if canImport`:
`Sources/TrellisUIKit/Scroll/UIScrollViewBacking.swift`,
`Sources/TrellisAppKit/Scroll/NSScrollViewBacking.swift` — neither exposes any
new public API of its own (both are `internal`, reached only through the
factory closure `TrellisHostView.attach(root:)` now wires automatically).

## Почему `containerLayer` и `setFrame(_:)`, которых sketch не специфицировал

`r06-scroll-api-sketch.md` §3 описывал только `installContentLayer(_:)` —
куда Trellis кладёт детей ScrollNode — не то, что `LayerRenderer` материализует
для самого узла. Реализация обнаружила, что это не деталь без последствий:

1. **`containerLayer`** нужен, чтобы `LayerRenderer.layer(for:)` (публичный
   lookup, которым уже пользуются hit-test/focus/AX-тесты) возвращал что-то
   осмысленное для `ScrollNode` — реальный слой native scroll view, а не
   лишний промежуточный `CALayer`, который бы не был тем, что фактически
   рисуется на экране.
2. **`setFrame(_:)`** — не косметика. Первая версия писала
   `containerLayer.bounds`/`.position` напрямую, тем же путём, что и любой
   обычный узел. Два реальных дефекта (docs/defects.md #66, #67) вышли из
   этого решения: (a) `bounds.origin` на `UIScrollView`/`NSScrollView` **есть**
   нативный content offset — обнуление на каждый коммит откатывало бы
   прокрутку к нулю на любом несвязанном resize/insets-коммите, ровно тот
   класс бага, что `docs/weave-scroll-analysis.md`'s дефект #63 уже
   зафиксировал для Weave; (b) `UIView`/`NSView`'s собственный `frame` —
   independent bookkeeping от `CALayer`'s `bounds`/`position`, и именно
   `frame`, не слой, читает нативный hit-testing (`UIScrollView`'s жесты,
   `NSView`'s мышь) — прямая запись в слой визуально выглядела правильно, но
   `test_scrollNode_resizingTheHostUpdatesTheNativeViewportSize()`
   (`AppKitScrollNodeEmbeddingTests.swift`) поймал реальное расхождение:
   `scroll.calculatedFrame` обновлялся, `NSScrollView.frame` — нет. Решение —
   `setFrame(_:)` как отдельный protocol requirement, который адаптер
   реализует через `scrollView.frame = ...`, а не через слой.

## Почему content union — по прямым детям, не рекурсивно, и почему это не полный P6.3

`LayerRenderer.scrollContentSize(of:viewportFrame:)` — максимум по committed
frame'ам **прямых** детей `ScrollNode`, не по всему поддереву. Этого
достаточно для R07's формы «одна прокручиваемая колонка простых узлов» и
соответствует акцептансу карточки («точная геометрия; на offset-only нет
полного solve/raster») — виртуализация (materialized window, P6.4/R10)
специфицирована в sketch's §11 как будущая работа, которую этот union не
предвосхищает и не блокирует.

## `.unspecified`-ось solver'а — реализовано отдельным изменением 2026-09-16

`r06-scroll-api-sketch.md` §2 специфицировал продольную ось ScrollNode как
`.unspecified`-constraint для детей (max-content basis, как ADR 0009 уже
делает для auto-sized контента). Первая версия этого ADR (2026-09-16, до
этого раздела) сознательно не реализовывала это — требовало правки в
`FlexboxEngine`, файла вне исходного R07 списка. Пользователь явно одобрил
закрытие этого пункта отдельным запросом в тот же день; реализовано в
`FlexboxEngine.resolveLines` (`Sources/TrellisCore/Layout/FlexboxMeasure.swift`):
контейнер с `style.visual.overflow == .scroll` подставляет `nil` вместо
`availableMain` при расчёте grow/shrink delta и wrap line-breaking внутри
`resolveLines` — итоговая delta всегда `0` для такого контейнера, то есть его
дети сохраняют natural (max-content) main size вместо сжатия/растяжения.
Cross-ось и собственный измеренный размер контейнера не тронуты. Область
действия — любой `.scroll`-overflow контейнер (единственный сигнал, доступный
чистому `LayoutInputSnapshot`, у которого нет понятия "это ScrollNode"), не
только класс `ScrollNode`; регрессия для `.hidden`/`.visible` контейнеров
исключена тестами (`test_flexboxEngine_nonScrollOverflowStillShrinksToFitContainer_regression`,
`test_flexboxEngine_defaultOverflowVisibleStillShrinksAndGrowsAsToday_regression`,
`Tests/TrellisCoreTests/Layout/FlexboxAlgorithmTests.swift`). Полная таблица
тестов, включая placement-уровень
(`test_layoutContainer_scrollOverflowStacksChildrenPastTheContainersOwnFrame`,
`FlexboxPlacementTests.swift`) — в
[r07-scroll-node.md](../validation/r07-scroll-node.md).

Не закрыто этим изменением: `.fraction`-размер (не `flexGrow`) вдоль scroll-оси
по-прежнему резолвится против реального `availableMain` в `measure()`'s
basis-проходе (`bases`, отдельный от `resolveLines`, который эта правка
меняла) — sketch §2's «`.fraction` резолвится в `0` с диагностикой» для этого
конкретного случая не реализовано; см. `r07-scroll-node.md`'s «Открытые
пункты».

Baseline обновлён отдельно для этого изменения не требуется — `resolveLines`
внутренний `static func` в `TrellisCore`, никакого нового public API.

## Почему `NativeScrollBacking` — top-level flat subview, не вложенный `CALayer`

Sketch's §4 предполагал, что backing вставляется «в тот же sublayer-слот»,
что и обычный слой узла. Реализация выбрала другую форму: адаптер добавляет
нативный `UIScrollView`/`NSScrollView` прямым subview хоста (или узла-хоста),
позиционированным в host-absolute координатах через `setFrame(_:)`, а не
вложенным в `CALayer` промежуточного предка. Обоснование: committed `frame`
уже root-absolute (тот же контракт, что `HitTestSnapshot.Record.frame`
документирует), так что позиция верна независимо от глубины вложенности без
пересчёта трансформов предков. Явная цена — открытый пункт, не скрытая
деталь: clip/transform **предков** ScrollNode не применяется к самому
native view композиционно (только к его позиции/размеру) — задокументировано
в `r07-scroll-node.md`'s «Открытые пункты».

## Решение

Baseline **не обновлён** этой сессией, честно: `python3 Scripts/check_api.py
--update --review-note docs/adr/0026-scroll-node-viewport.md` (и повторная
попытка после `.unspecified`-фикса выше) оба завершились «macOS build did not
produce a Modules directory» — `check_api.py`'s `build_macos_modules` ожидает
продукты в `.build/arm64-apple-macosx/debug/Modules` (конвенция более старого
SwiftPM layout), а в этой сессии (`swift-driver version 1.168.6`, Apple Swift
6.4, только Command Line Tools без полного Xcode) `swift build`/`xcrun --sdk
macosx swift build` кладёт продукты в `.build/out/Products/Debug`
(`.build/debug` — симлинк туда), путь, которого сам `check_api.py` не ищет.
Несоответствие окружения/тулчейна, не следствие правок этой карточки —
`swift build`/`swift test` работают штатно. `api/TrellisCore.json`,
`api/TrellisRender.json`, `api/TrellisAppKit.json`, `api/TrellisUIKit.json`
остаются на прежних значениях; см. `r07-scroll-node.md`'s таблицу проверок.

## Уточнение 2026-09-23 (R12a, дефекты #84/#86)

Согласовано с пользователем. Прокручиваемая ось — главная flex-ось, поэтому направление
раскладки `ScrollNode` следует за `configuration.axis`: `init` выравнивает направление по
вертикальной оси по умолчанию (`.row` → `.column`, `.rowReverse` → `.columnReverse`), смена
оси выравнивает его снова, `.both` направление не меняет. Ручная установка несовпадающего
`flexDirection` не запрещена, но пишется в лог как `style scroll-axis-mismatch`.

Вдоль прокручиваемой оси scroll-контейнер — viewport: его автоматический размер ограничен
`.atMost`-ограничением родителя, а не протяжённостью содержимого; дети по-прежнему
измеряются без ограничения по этой оси. Без этого вертикальный `ScrollNode`, растянутый
row-родителем, получал высоту содержимого, и прокручивать было нечего (#86).
