# A10 — AppKit accessibility

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D42, D43, D45–D47 ([decisions.md](../decisions.md)); mapping ролей —
[a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §3.1;
прототип — [a02-native-prototype.md](a02-native-prototype.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Реальные `NSAccessibilityElement` | `Sources/TrellisAppKit/AccessibilityElements.swift` — `TrellisAccessibilityElement` | Один элемент на `(mountEpoch, NodeID)`, без NSView. `update(from:children:)` ставит role (`.button`/`.staticText`/`.image`/`.link`/`.slider`/`.group`; header → `.staticText` — осознанный fallback §3.1; leaf без роли с label → `.staticText`), label, value, help (hint), identifier, enabled, selected, `accessibilityChildren` для группы. Значения только из опубликованного дерева. Класс не `@MainActor` (SDK не изолирует `NSAccessibilityElement`): действия — nonisolated overrides с `MainActor.assumeIsolated`, захватывающие только coordinator/identity/epoch, не `self`. |
| Parent/children | `AppKitAccessibilityCoordinator.apply(tree:)` | Дети обновляются раньше родителей; `setAccessibilityParent` — host для roots, group-элемент для детей; `isAccessibilitySelectorAllowed`: press только у button, increment/decrement только у slider. |
| Screen frames (D46) | `updateScreenFrame(host:)`, `refreshScreenFrames()` | Host-space AABB хранится; flipped host → `convert(_:to: nil)` → `window.convertToScreen` в адаптере. `NSWindow.didMoveNotification` (только своё окно) пересчитывает frames без Flex/layout. |
| Actions (D43) | `accessibilityPerformPress/Increment/Decrement`, `NSAccessibilityCustomAction` handlers → `coordinator.perform(_:on:epoch:)` → `bridge.performAccessibilityAction` | Epoch guard: элемент прошлого mount (ОС может держать его после detach/attach того же root, когда `NodeID` снова валидны) отвергается до bridge; далее live guard bridge (leaf в дереве, живой маршрут, enabled для activate). Keyboard focus не меняется (D45). Тот же epoch guard добавлен UIKit-proxies (A09). |
| Notifications (D47) | `apply(tree:)`, `removeAll()` | Сначала полностью заменены элементы/значения, затем `NSAccessibility.post(element: host, .layoutChanged)` — на host, не на `NSApplication.shared`; `.valueChanged` на каждом leaf, чей value изменился; равное дерево не приходит из bridge → без уведомлений; detach → пустые children + `.layoutChanged`. Test hook `notificationSink`. |
| Host | `TrellisAppKit/TrellisHostView.swift` | `isAccessibilityElement() == false`, `accessibilityRole() == .group`, `accessibilityChildren()` = roots (modal scope — поддерево); `nativeAccessibilityElementCount` (A12 hook). |

## Тесты

`swift test --filter a10_` — 4 теста, зелёные (`Tests/TrellisRenderTests/AppKitAccessibilityTests.swift`):

| Тест | Приёмка |
|---|---|
| `a10_hostExposesRealElementsWithRolesValuesParentsAndScreenFrames` | native API видит дерево и reading order `[card(group) > [title, button, slider], background]`; роли (header → staticText), label/value/help/identifier/enabled/selected/custom actions; parent links; slider allows increment, не press; screen frame = flipped host → window → screen с origin окна; первое дерево — `.layoutChanged` |
| `a10_voiceOverActionsRouteThroughTheBridge` | press → activation `.accessibility`, focus не меняется; custom handler; increment/decrement; press на slider — `false`; disabled → `isAccessibilityEnabled == false`, press `false` |
| `a10_reuseValueChangedNotificationsAndTeardown` | value change — тот же элемент, `.layoutChanged` + `.valueChanged(button)`; same value/paint-only — без уведомлений; modal scope — только card; detach → 0 элементов, старый элемент press `false`; после повторного attach старый элемент по-прежнему `false`, новый — `true` |
| `a10_twoWindowsKeepTheirElementsApartAndAWindowMoveUpdatesScreenFrames` | два окна — разные элементы и parents; перенос окна `setFrameOrigin` → frame сдвинут на (60, 40) без нового commit |

Ручной VoiceOver на macOS (press/custom/increment/decrement голосом) — A11.

## API baseline

`TrellisAppKit`: `isAccessibilityElement()`/`accessibilityRole()`/`accessibilityChildren()`
overrides, `nativeAccessibilityElementCount`; этот отчёт — review note.
