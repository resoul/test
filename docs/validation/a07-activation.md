# A07 — Focus events, enabled и единая activation

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D41, D43, D45, D48 ([decisions.md](../decisions.md),
[ADR 0013](../adr/0013-event-pointer-becomes-optional.md)); случаи —
[a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §6.

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Typed payloads (D48) | `Events/Event.swift` — с A04 | `focusIn/focusOut/keyDown/keyUp`, `FocusData`, `KeyData`, `Event.pointer: PointerData?`. Все pointer-only call sites мигрированы в A04 (`ControlNode.track`, `TapRecognizer`/`PanRecognizer`, тесты); внешний consumer компилируется (использует только `event.type`) и получает focus/AX путь в A13. |
| `ActivationSource`, `activate(source:)` (D43) | `Controls/ControlNode.swift` | `open func activate(source:) -> Bool` — единственная default activation: `isEnabled && !isDisposed` → `lastActivationSource = source`, `activation?()`, `true`; иначе `false` и лог. Pointer: `tapEnded` → `activate(source: .pointer)` (up-inside H06 сохранён). Keyboard/remote: key-up закрывает press-cycle. Accessibility: `performAccessibilityAction(.activate)` → `activate(source: .accessibility)`. |
| `isFocused` (D39/D45) | `ControlNode.track` | `true` между `focusIn` и `focusOut` (target-события engine); отдельно от `isPressed`; appearance dirty на изменение. |
| Key press-cycle (D43) | `ControlNode.handleKeyDefault(_:defaultPrevented:source:)` (internal), `FocusEngine.sendKey` | Engine после three-phase dispatch key-события к сфокусированной ноде вызывает default action control'а: key-down Return/Space/Select (не repeat, enabled, focused, цикл не открыт) → `isPressed = true`, `pressedKey`; key-up той же клавиши → `isPressed = false`, activation ровно один раз, если default не предотвращён; prevented key-up закрывает цикл без activation; чужой key-up цикл не трогает. `focusOut` (смена focus, suspend), `isEnabled = false`, `dispose()` закрывают цикл без activation. Source: `.select` → `.remote`, иначе `.keyboard`. |
| `FocusEngine.sendKey` / `KeyOutcome` | `Focus/FocusEngine.swift` | Tab/Shift-Tab/стрелки на key-down → `move`; `.handled` при переходе, иначе `.unhandled` (host отдаёт системе — нет keyboard trap); key-up навигационных клавиш — `.unhandled`. Return/Space/Select — dispatch `keyDown`/`keyUp` по committed маршруту focused (capture/target/bubble, `preventDefault()` до default action), затем `handleKeyDefault`; без focused — `.unhandled`. |
| AX actions (D43, D45) | `Node.onAccessibilityAction`, `open func performAccessibilityAction(_:)`, `ControlNode` override, `NodeHostBridge.performAccessibilityAction(_:on:)` | Node: closure ?? `false`. Bridge: ID должен быть leaf текущего `accessibilityTree` (значит внутри modal scope и не hidden), живым под mounted root по committed маршруту (`SemanticSnapshot.liveNode(for:under:)`), для `.activate` — enabled по опубликованному **и** live состоянию; результат — результат обработчика. Keyboard focus не меняется. Stale ID после нового attach — `false`. |
| Bridge key API | `NodeHostBridge.send(_:key:)` | `.unhandled` без root, на suspended хосте, при `skipsLayoutOnlyWrappers`. |
| Controls — элементы по умолчанию | `ControlNode.init` | `accessibility.isElement = true` (как `focus.isFocusable`): кнопка видна VoiceOver без явного opt-in; label задаёт автор (§3.2 плана). |

## Тесты

`swift test --filter a07_` — 12 тестов, все зелёные; полный набор — 481.

Core (`Tests/TrellisCoreTests/Controls/ActivationTests.swift`):

| Тест | Случаи §6 |
|---|---|
| `a07_returnAndSpaceActivateOnceOnKeyUpWithThePressCycleVisible` | 1: Return/Space → `.keyboard`, Select → `.remote`; `isPressed` виден между down и up; порядок событий `focusIn, keyDown, keyUp` |
| `a07_repeatKeyDownAndStrayKeyUpNeverActivate` | 2, 4; чужой key-up не закрывает цикл |
| `a07_focusChangeBetweenKeyDownAndKeyUpCancelsTheCycle` | 3; `isFocused` переключается |
| `a07_disablingDuringThePressClearsItAndNeverActivates` | 5; `activate` любого source на disabled — `false`; после publish focus уходит |
| `a07_preventDefaultOnKeyUpOrKeyDownSuppressesActivation` | 6: veto в bubble на key-up; veto на key-down — цикл не открывается; после снятия — работает |
| `a07_activationKeysWithoutFocusAndNavigationKeysReportTheOutcome` | без focus — `.unhandled`; Tab/стрелки — `.handled`/`.unhandled` на границе; key-up навигации — `.unhandled` |
| `a07_activationMayDisposeTheControlOrDetachTheTreeWithoutASecondDelivery` | удаление control внутри activation, reset engine внутри activation — без повторной доставки |
| `a07_accessibilityActivateUsesTheSameActivationAndKeepsKeyboardFocus` | 7–8 |
| `a07_customActionsReturnTheHandlerResultAndPlainNodesUseTheClosure` | 9; custom не активирует; plain Node через closure |
| `a07_pointerActivationRecordsItsSourceAndStillNeedsUpInside` | pointer-регрессия H03–H06 (все прежние тесты зелёные) + `.pointer` source; key-cycle переживает посторонний tap |

Render (`Tests/TrellisRenderTests/FocusBridgeTests.swift`):
`a07_bridgeRoutesKeysAndRefusesThemWhileInactive` (Tab/стрелка/Return через bridge, suspend
отменяет press, resume не активирует), `a07_bridgeAccessibilityActionValidatesAgainstThePublishedTreeAndTheLiveNode`
(focus не меняется; disabled live/published; вне scope; unknown custom; stale ID после нового attach).

«Одно native действие не доставляется дважды через key и AX adapters» — свойство адаптеров,
проверяется в A08/A09 (host view не шлёт Select одновременно как key и как AX activate).

## API baseline

Добавлены `ActivationSource`, `KeyOutcome`, `ControlNode.isFocused`/`lastActivationSource`/
`activate(source:)`/`performAccessibilityAction`, `Node.onAccessibilityAction`/
`performAccessibilityAction`, `FocusEngine.sendKey`, `NodeHostBridge.send(_:key:)`/
`performAccessibilityAction(_:on:)`; этот отчёт — review note.
