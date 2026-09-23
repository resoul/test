# A01 — Контракт focus engine и accessibility: API sketch и ожидаемые переходы

Дата: 2026-09-11. Первая карточка [implementation-plan-3.md](../implementation-plan-3.md) §5.
Решения D35–D48 приняты и перенесены в [decisions.md](../decisions.md); дефекты источника
#33–#35 ([defects.md](../defects.md)) закрываются в A04–A06. Кода здесь нет — таблицы §5
становятся тестами A03–A07 один в один. Механизм D44 предварительно выбран по чтению
SDK и подтверждается native evidence A02 ([a02-native-prototype.md](a02-native-prototype.md)).

## 1. API sketch (`TrellisCore`, только Foundation)

```swift
// Metadata на Node (A03). Value-типы, no-op equality в didSet, DirtyReasons.semantics.
public struct FocusProperties: Sendable, Hashable {
    public var isFocusable: Bool                          // Node: false; ControlNode: true
    public var priority: Int                              // только initial/fallback (D38)
    public var preferredNext: [FocusDirection: NodeID]    // explicit overrides
}
public enum FocusDirection: Sendable, Hashable { case up, down, left, right, next, previous }

public enum AccessibilityRole: Sendable, Hashable { case button, text, image, header, link, group, adjustable }
public enum AccessibilityChildrenPolicy: Sendable, Hashable { case contain, combine, ignoreSelf, hide }
public struct AccessibilityCustomAction: Sendable, Hashable { public let id: String; public let name: String }
public enum AccessibilityAction: Sendable, Hashable { case activate, increment, decrement, custom(String) }
public struct AccessibilityProperties: Sendable, Hashable {
    public var isElement: Bool          // false
    public var label, value, hint, identifier: String?
    public var role: AccessibilityRole?
    public var isSelected: Bool
    public var sortPriority: Double     // non-finite → 0
    public var childrenPolicy: AccessibilityChildrenPolicy   // .contain
    public var actions: [AccessibilityAction]                // авторские; ControlNode добавляет .activate
    public var customActions: [AccessibilityCustomAction]    // id ↔ name
}

extension Node {
    public var focus: FocusProperties                 // didSet → markSemanticsDirty()
    public var accessibility: AccessibilityProperties // didSet → markSemanticsDirty()
    public private(set) var semanticsRevision: UInt64
    public var onAccessibilityAction: (@MainActor (AccessibilityAction) -> Bool)?
    open func performAccessibilityAction(_ action: AccessibilityAction) -> Bool   // default: closure ?? false
}
extension ControlNode {
    public var isEnabled: Bool                        // D41: единственный источник enabled
    public private(set) var isFocused: Bool           // отдельно от isPressed
    public private(set) var lastActivationSource: ActivationSource?
    public func activate(source: ActivationSource) -> Bool   // D43 единая default activation
}
public enum ActivationSource: Sendable, Hashable { case pointer, keyboard, remote, accessibility }

// Committed снимок (A03) — из HitTestSnapshot + live metadata в commit-точке; без Node.
public struct SemanticSnapshot: Sendable {
    public struct Record: Sendable, Hashable {
        id, parent, children, traversalIndex, frame, visibleBounds: LayoutFrame?,
        focus, accessibility, isEnabled, isControl, isArrangementWrapper
    }
    public let root: NodeID; mountEpoch, geometryGeneration, revision: UInt64; bounds: LayoutFrame
    public let order: [NodeID]                         // committed pre-order
    public func record(for: NodeID) -> Record?
    public func focusCandidates(scope: NodeID?) -> [NodeID]   // D37, в порядке обхода
}
extension HitTestSnapshot { public func visibleBounds(of: NodeID) -> LayoutFrame? }   // D46

// Focus core (A04–A05).
public struct FocusChange: Sendable, Hashable { previous, next: NodeID?; reason: FocusChangeReason }
public enum FocusChangeReason: Sendable, Hashable { case request, navigation, restoration, invalidation, scope, native, detach }
public struct FocusTrace: Sendable, Hashable { direction, candidates: [NodeID], selected: NodeID? }
public enum FocusMoveResult: Sendable, Hashable { case moved(FocusChange), unchanged, unavailable }

@MainActor public final class FocusEngine {
    public private(set) var focusedID: NodeID?
    public private(set) var scopeID: NodeID?
    public private(set) var transitionRevision: UInt64
    public private(set) var lastTrace: FocusTrace?
    public var onFocusChange: (@MainActor (FocusChange) -> Void)?
    public func apply(_ snapshot: SemanticSnapshot, root: Node)             // после commit/publish
    @discardableResult public func focus(_ id: NodeID?, root: Node, reason: FocusChangeReason = .request) -> FocusMoveResult
    @discardableResult public func move(_ direction: FocusDirection, root: Node) -> FocusMoveResult
    public func setScope(_ id: NodeID?, root: Node)
    public func suspend(root: Node); public func reset()
}

// События (A07, D48, ADR 0013).
public enum EventType { …, focusIn, focusOut, keyDown, keyUp }
public struct FocusData: Sendable, Hashable { previous, next: NodeID?; reason }
public enum KeyboardKey: Sendable, Hashable { case tab, upArrow, downArrow, leftArrow, rightArrow, returnKey, space, select }
public struct KeyData: Sendable, Hashable { key: KeyboardKey; isShiftDown: Bool; isRepeat: Bool }
public enum EventPayload { pointer(PointerData), focus(FocusData), key(KeyData) }
extension Event { public var pointer: PointerData?; public var focus: FocusData?; public var key: KeyData? }

// Семантическое дерево (A06).
public struct AccessibilityElement: Sendable, Hashable {
    id, frame (visible AABB), label, value, hint, identifier, role, isEnabled, isSelected,
    isElement (leaf) / group, actions: [AccessibilityAction], customActions, children
}
public struct AccessibilityTree: Sendable, Hashable {
    public let elements: [AccessibilityElement]; readingOrder: [NodeID]; revision, mountEpoch
    public static func build(from: SemanticSnapshot, scope: NodeID?) -> AccessibilityTree
}
```

Bridge (`TrellisRender`): `semanticSnapshot`, `accessibilityTree`, `focusEngine` (только
чтение `focusedID`, запросы через bridge), `focus(_:)`, `moveFocus(_:)`,
`setFocusScope(_:)`, `send(key:phase:) -> KeyOutcome`,
`performAccessibilityAction(_:on:) -> Bool`, `onSemanticsPublished` (для адаптеров).

## 2. Владение

| Объект | Владелец | Хранит | Точка отмены |
|---|---|---|---|
| `Node.focus` / `Node.accessibility` | `Node` | value | `dispose()` |
| `SemanticSnapshot` | `NodeHostBridge` (последний) | `NodeID`, значения | `detach()`, замена root |
| `FocusEngine` | `NodeHostBridge` | `focusedID`, `scopeID`, `restorationID`, очередь, epoch | `detach()` → `reset()`; `suspend()` |
| `AccessibilityTree` | `NodeHostBridge` (последний) | value | `detach()` |
| Native proxy (`UIAccessibilityElement`+`UIFocusItem`, `NSAccessibilityElement`) | `TrellisHostView` (реестр `(mountEpoch, NodeID)`) | `NodeID`, weak bridge, копии properties | `detach()`, снимок без этого ID |
| Pending native focus request (tvOS) | `TrellisHostView` | token + `NodeID` | native callback, `detach()`, window loss |
| Key press-cycle | `ControlNode` | `KeyboardKey`, source | key-up, focusOut, disable, `suspend()`, `dispose()` |

Ни один объект выше не держит `Node` сильно, кроме bridge (root, как в D07).

## 3. Миграция событий (D48, ADR 0013)

`Event.pointer` — `PointerData?`; новые `EventType`/`EventPayload` cases. Все pointer-only
call sites (`ControlNode.track`, тесты H03–H06, consumer `verify_bootstrap.py`) переводятся в
A07. Focus-события идут по committed маршруту `HitTestSnapshot.route(to:)` через тот же
`EventDispatcher` — три фазы, `stopPropagation()`; `preventDefault()` для `focusIn/Out`
не имеет default action и игнорируется. Key-события: три фазы к **сфокусированной** ноде,
затем — если default не предотвращён и маршрут цел — default action `ControlNode` (D43).

### 3.1. Native role mapping

| Роль | UIKit (`accessibilityTraits`) | AppKit (`accessibilityRole`) | Fallback |
|---|---|---|---|
| `.button` | `.button` | `.button` | — |
| `.text` | `.staticText` | `.staticText` | — |
| `.image` | `.image` | `.image` | — |
| `.header` | `.header` | `.staticText` | AppKit не имеет heading-роли для произвольного элемента; label читается как текст — осознанный fallback |
| `.link` | `.link` | `.link` | — |
| `.group` | контейнер, `accessibilityContainerType = .semanticGroup`, без traits | `.group` | — |
| `.adjustable` | `.adjustable` + `accessibilityIncrement/Decrement` | `.slider` + `accessibilityPerformIncrement/Decrement` | — |
| `nil` + control | `.button` | `.button` | control без роли — кнопка (§3.2 плана) |
| `nil` + не control | без traits | `.unknown` → `.group` для контейнера, `.staticText` для leaf с label | — |

State: `isEnabled == false` → UIKit `.notEnabled`, AppKit `isAccessibilityEnabled = false`;
`isSelected` → `.selected` / `isAccessibilitySelected`. Label/value/hint/identifier —
`accessibilityLabel`/`Value`/`Hint`/`Identifier` и `accessibilityLabel`/`Value`/`Help`/
`Identifier`. Actions: `.activate` → UIKit `accessibilityActivate()`, AppKit
`accessibilityPerformPress()`; custom → `UIAccessibilityCustomAction`/`NSAccessibilityCustomAction`
с `name`, маршрутизация по `id`.

### 3.2. Уточнение `.contain` с `isElement == true` и element-потомками

UIKit не даёт одному `UIAccessibilityElement` быть одновременно leaf
(`isAccessibilityElement = true`) и контейнером с детьми — VoiceOver игнорирует детей
leaf-элемента; AppKit допускает группу с label. Единая семантика на обеих платформах:
такой узел — **группа с label** (UIKit: `isAccessibilityElement = false`,
`accessibilityContainerType = .semanticGroup`, `accessibilityLabel`; AppKit: `.group` +
`accessibilityLabel`), собственного endpoint в `readingOrder` у него нет. Автор, которому
нужен один leaf с объединённым текстом, использует `.combine`. Platform-тест A09/A10
проверяет, что native API видит и label группы, и её детей.

## 4. Порядок обхода: примеры

Дерево `R > [A, B, C]`, все — focusable controls, frames `(0,0,80,80)`, `(100,0,80,80)`,
`(200,0,80,80)`; traversal index — pre-order.

| # | Состояние | Запрос | Результат | Почему |
|---|---|---|---|---|
| 1 | focus `nil` | `.next` | `A` | начальный — priority 0 у всех, минимальный traversal index |
| 2 | focus `A` | `.next` | `B`; ещё раз — `C` | pre-order |
| 3 | focus `C` | `.next` | `.unchanged` | нет wrap вне modal — host отдаёт Tab системе |
| 4 | focus `C` | `.previous` | `B`, затем `A`, затем `.unchanged` | обратный порядок |
| 5 | focus `nil` | `.previous` | `C` | последний |
| 6 | focus `A`, `B.zIndex = 5`, `C` создан раньше `A` | `.next` | `B` | zIndex и порядок создания ID не участвуют |
| 7 | `R > [A, B]`, `A (0,0,80,80)`, `B (0,100,80,80)`, `D (100,0,80,80)` — `D` добавлен как третий child | из `A`: `.right` | `D` | строго положительная проекция по x; `B` проекция 0 → не кандидат |
| 8 | focus `A`; `B (100, 0)`, `C (100, 60)` | `.right` | `B` | score `B` = 100 + 0.5·0 = 100; `C` = 100 + 0.5·60 = 130 |
| 9 | focus `A`; `B (100,0)`, `C (100,0)` одинаковые frames | `.right` | `B` | равные scores — меньший traversal index; shuffled registry не влияет (снимок упорядочен) |
| 10 | focus `A`, `A.focus.preferredNext[.right] = C.id` | `.right` | `C` | valid override раньше поиска |
| 11 | override → `A.id` (self) / disposed ID / ID вне scope | `.right` | как без override | игнорируется |
| 12 | RTL environment, те же frames | `.right` | как в LTR | физическое направление |
| 13 | `B.isEnabled = false`, publish | из `A`: `.next` | `C` | disabled — не кандидат |
| 14 | `B.style.visual.opacity = 0`, commit | из `A`: `.next` | `C` | невидимая область |
| 15 | `B` полностью за `overflow == .hidden` предком | из `A`: `.next` | `C` | D46 |
| 16 | `B.accessibility.childrenPolicy = .hide` | из `A`: `.next` | `B` | AX hide не отключает focus (D37) |

## 5. Ожидаемые переходы и реентрантность (D39–D40)

| # | Ситуация | Ожидание |
|---|---|---|
| 1 | `focus(B)` при focus `A` | `A` получает `focusOut(previous: A, next: B)`, затем `B` — `focusIn`; `onFocusChange(A→B, .request)`; `transitionRevision + 1` |
| 2 | `focus(A)` при focus `A` | no-op: ни событий, ни `onFocusChange`, ревизия не растёт |
| 3 | `focus(B)`, в `focusOut` на `A` — `B.dispose()` | `focusIn` не доставляется; `focusedID == nil`; `onFocusChange(A→nil, .invalidation)` — ровно одно уведомление |
| 4 | `focus(B)`, в `focusOut` на `A` — `bridge.detach()` (или `engine.reset()`) | переход прерван, `focusedID == nil`, дальнейших callbacks нет |
| 5 | `focus(B)`, в `focusIn` на `B` — `focus(C)` | текущий переход завершается (`focusedID == B`, уведомление A→B), затем отложенный: `B` focusOut, `C` focusIn, уведомление B→C; ровно два уведомления |
| 6 | callback-loop: в `focusIn` каждой ноды — запрос на соседа | после 8 отложенных запросов очередь отбрасывает дальнейшие с диагностикой; engine остаётся в согласованном состоянии |
| 7 | `setScope(modal)` при focus `A` вне modal; в modal `X`, `Y` | `restorationID = A`; focus → `X` (первый в scope); `focus(A)` → `.unavailable`; `.next` из `Y` → `X` (wrap в modal); `.right` из `Y` без кандидата → `.unchanged` |
| 8 | `setScope(modal)` без focusable в modal | `focusedID == nil`; `.next` → `.unchanged`; фон не получает focus |
| 9 | `setScope(nil)` | восстанавливается `A`, если eligible; иначе первый доступный |
| 10 | `setScope(modal)` повторно с тем же ID | no-op |
| 11 | modal root удалён и commit | scope закрывается, восстановление по правилам 9 |
| 12 | commit удалил сфокусированный `B` из `[A, B, C]` | focus → `C` (следующий по прежнему traversal index), иначе `A`, иначе первый в scope, иначе `nil`; `reason: .invalidation` |
| 13 | `B.isEnabled = false` (publish) при focus `B` | как 12 |
| 14 | reparent `B` под другого родителя без commit | до commit: `focus(B)` по старому маршруту — `.unavailable`; после commit в том же mount — `B` снова eligible с тем же ID |
| 15 | resize хоста | focus не сбрасывается |
| 16 | `suspend()` при focus `B` с начатым key-down | press-cycle отменён, activation нет; `resume()` — focus `B` по первому актуальному снимку, activation нет |
| 17 | `detach()`; `attach(root)` заново | `focusedID == nil`, новая epoch; старый native proxy получает action → `false` |

## 6. Активация и accessibility (D43, D45)

| # | Ситуация | Ожидание |
|---|---|---|
| 1 | focus `B`, `keyDown(.returnKey)`, `keyUp(.returnKey)` | `B.isPressed` true → false; activation один раз, `source == .keyboard` |
| 2 | `keyDown`, `keyDown(isRepeat: true)`, `keyUp` | одна activation |
| 3 | `keyDown(.space)` на `B`, `focus(C)`, `keyUp(.space)` | activation нет ни у `B`, ни у `C` |
| 4 | `keyUp` без key-down | no-op |
| 5 | `keyDown` на `B`, `B.isEnabled = false`, `keyUp` | `isPressed` сброшен, activation нет |
| 6 | `preventDefault()` в bubble на `keyUp` | activation нет |
| 7 | `performAccessibilityAction(.activate, on: B)` при keyboard focus `A` | activation `B` (`.accessibility`), `focusedID == A` |
| 8 | `.activate` на disabled / на ID вне снимка / на ID прошлой epoch | `false`, activation нет |
| 9 | custom action `id: "share"` с `onAccessibilityAction` возвращающим `true` | `true`; `false` из closure → `false` |
| 10 | tvOS: native `didUpdateFocus` на proxy `B` | `focusedID == B`, `reason: .native`, без второго `setNeedsFocusUpdate` |
| 11 | metadata mutation во время solve (`B.accessibility.label = "x"`) | solver не отменён; commit публикует новый label; `requested` не растёт из-за mutation |
| 12 | label burst 100 раз на одной ноде без geometry change | один semantic publish, ноль layout snapshots и solves |

## Приёмка A01

- Нерешённых семантических альтернатив для A03–A07 нет: priority — только initial/fallback;
  `.contain`+`isElement`+дети — группа с label; wrap — только в modal; directional score —
  формула D38.
- D44 — proxy `UIAccessibilityElement`+`UIFocusItem`; окончательно после A02.
- D48 — [ADR 0013](../adr/0013-event-pointer-becomes-optional.md); baseline обновляется в A07.
