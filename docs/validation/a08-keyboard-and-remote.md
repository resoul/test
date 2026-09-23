# A08 — Клавиатура и remote в существующих хостах

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D38, D43–D45 ([decisions.md](../decisions.md)); механизм D44 — по
[a02-native-prototype.md](a02-native-prototype.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| AppKit клавиатура | `Sources/TrellisAppKit/TrellisHostView.swift` | `acceptsFirstResponder == true`, `mouseDown` делает host first responder. `keyDown`/`keyUp`: `NSEvent` → `KeyData` по virtual key code (48 Tab, 123–126 стрелки, 36/76 Return, 49 Space; `.shift` → `isShiftDown`, `isARepeat`) → `bridge.send(_:key:)`; `.unhandled` (незнакомая клавиша, Tab/стрелка на границе, key-up навигационных клавиш, нет root) → `super` — дальше по responder chain к системному key-view loop. Keyboard trap нет. |
| UIKit presses | `Sources/TrellisUIKit/TrellisHostView.swift` | `canBecomeFirstResponder`, `becomeFirstResponder()` при появлении в окне. `pressesBegan/Ended`: `UIPress` → `KeyData` (`keyData(pressType:key:isTV:)`): клавиатура по `UIKey.keyCode` (Tab/стрелки только вне tvOS, Return/Enter, Space; Shift), remote — `.select` → `.select`, стрелки только вне tvOS. На tvOS стрелки — системный focus engine (D44), Menu/PlayPause и всё непотреблённое — `super`. `pressesCancelled` → `bridge.cancelKeyPress()` — цикл закрывается без activation. |
| Native focus proxies (D44) | `Sources/TrellisUIKit/NativeProxies.swift` | `TrellisNodeProxy: UIAccessibilityElement, UIFocusItem` — один объект на `(mountEpoch, NodeID)`, `frame` = committed visible bounds в host space, `canBecomeFocused` = focus candidate в scope. `NativeProxyCoordinator` (владелец — host view): `apply(snapshot:tree:scope:)` переиспользует proxies по ID внутри mount, создаёт для кандидатов focus и элементов AX-дерева, удаляет остальные; смена epoch сбрасывает всё. `focusItems(in:)` host = `super` + proxies (только `isNativeFocusEnabled`, т.е. `userInterfaceIdiom == .tv`); `preferredFocusEnvironments` = pending request engine ?? текущий focus. |
| Handshake одного источника (D44/D45) | `NativeProxyCoordinator` | Engine → `onFocusChange` (reason ≠ `.native`) → `pendingNativeRequest = next`, `setNeedsFocusUpdate()`/`updateFocusIfNeeded()` на host → система читает `preferredFocusEnvironments` → proxy `didUpdateFocus` → `nativeFocusDidLand` → `bridge.focus(id, reason: .native)` (no-op, если engine уже там — подтверждение; переход, если система выбрала другой item — система побеждает, pending очищается). Уход focus на чужой native control → `nativeFocusDidLeave` → `bridge.focus(nil, reason: .native)`. Переход с reason `.native` обратно системе не отправляется — origin guard от loop. Proxy прошлой epoch игнорируется. |
| Cancel press | `ControlNode.cancelKeyPress`, `FocusEngine.cancelKeyPress(root:)`, `NodeHostBridge.cancelKeyPress()` | Для `pressesCancelled` и `detach()` — открытый key-цикл закрывается без activation. |
| Публичный API host views | оба `TrellisHostView` | `focusedID`, `onFocusChange`, `focus(_:)`, `moveFocus(_:)`, `setFocusScope(_:)`, `performAccessibilityAction(_:on:)`; UIKit — `nativeProxyCount`. |
| Порядок публикации в bridge (D47) | `NodeHostBridge.publishSemantics` | snapshot → engine.apply → дерево пересобрано (без уведомления) → `onSemanticsPublished` (адаптер перестраивает proxies) → `onAccessibilityTreeChanged` (только если изменилось). `setFocusScope` — тот же порядок. |
| Package | `Package.swift` | `TrellisRenderTests` зависит и от `TrellisUIKit`: UIKit-тесты под `canImport(UIKit)` выполняются на iOS/tvOS Simulator в C27-матрице, на macOS — пустой модуль. |

## Тесты

macOS `swift test --filter a08_` — 3 (`Tests/TrellisRenderTests/AppKitKeyboardInputTests.swift`):

| Тест | Приёмка |
|---|---|
| `a08_appKitTabShiftTabArrowsAndReturnDriveTheEngine` | реальные `NSEvent`: Tab → первый, → второй, Return down/repeat/up — одна activation `.keyboard`, Space — вторая, Shift-Tab назад; ничего не ушло выше по chain |
| `a08_appKitPassesUnconsumedKeysUpTheResponderChain` | «a», Tab/→ на границе, key-up навигации, всё после `detach()` — доходят до superview; Return потреблён |
| `a08_appKitKeyMapping` | таблица key code → `KeyData`, Escape → `nil` |

iOS 26.5 и tvOS 26.5 Simulator (`xcodebuild test`, `Tests/TrellisRenderTests/UIKitKeyboardAndFocusProxyTests.swift`) — 4, обе платформы зелёные (97 тестов `TrellisRenderTests` на каждой):

| Тест | Приёмка |
|---|---|
| `a08_uiKitPressMappingKeepsArrowsForThePlatformOnTV` | Select на обеих; стрелки — только вне tvOS; Menu/PlayPause — `nil` |
| `a08_uiKitSelectAndArrowsDriveTheEngineWhereTheEngineOwnsTraversal` | iOS: → двигает focus; tvOS: → `.unhandled` (системе); Select down/up — `isPressed`, одна activation `.remote`; Menu не перехвачен; `detach()` закрывает открытый press без activation |
| `a08_proxiesFollowThePublishedCandidatesAndAreReusedWithinAMount` | proxy на кандидата с committed frame (safe area учтена); metadata-only publish — тот же объект, `canBecomeFocused` меняется; dispose ноды удаляет proxy; `focusItems(in:)` — только на tvOS; `detach()` → 0 proxies |
| `a08_nativeHandshakeConfirmsEngineRequestsAndMirrorsPlatformMoves` | pending request → `preferredFocusEnvironments`; confirmation — без второго перехода; native move → `.native` без обратного запроса; уход к чужому control → nil; повторный leave игнорируется; система выбрала другой item — побеждает; proxy старой epoch после нового attach не доходит до engine |

## Не закрыто здесь (A11)

Ручные проверки: macOS Tab/Shift-Tab/Space/Return в Playground; iPadOS hardware keyboard;
tvOS remote стрелки/Select и выход к соседнему нативному control и обратно — headless focus
system tvOS инертен (A02), реальный запуск только через Playground-tvOS. Playground-tvOS
пока перехватывает стрелки/Select для переключения сцен — переводится на Menu/PlayPause в A11.

## API baseline

`TrellisAppKit`/`TrellisUIKit`: `focusedID`, `onFocusChange`, `focus(_:)`, `moveFocus(_:)`,
`setFocusScope(_:)`, `performAccessibilityAction(_:on:)`, `keyDown`/`keyUp`/`acceptsFirstResponder`
(AppKit), `canBecomeFocused`/`focusItems(in:)`/`preferredFocusEnvironments`/
`canBecomeFirstResponder`/`pressesBegan`/`pressesEnded`/`pressesCancelled`/`nativeProxyCount`
(UIKit); `TrellisRender`: `NodeHostBridge.cancelKeyPress()`; `TrellisCore`:
`FocusEngine.cancelKeyPress(root:)`. Этот отчёт — review note.
