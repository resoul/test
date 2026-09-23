# A09 — UIKit accessibility

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D42, D43, D45–D47 ([decisions.md](../decisions.md)); mapping ролей —
[a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §3.1–3.2;
механизм proxy — [a02-native-prototype.md](a02-native-prototype.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Host — container | `Sources/TrellisUIKit/TrellisHostView.swift` | `isAccessibilityElement == false`; `accessibilityElements` = proxies верхнего уровня опубликованного `AccessibilityTree` в reading order (внутри modal scope — только его поддерево, D40). Один proxy на `NodeID` — тот же объект, что и focus item A08 (без двойного представления). |
| Properties (§3.1) | `TrellisNodeProxy.updateAccessibility(from:children:)` | Leaf: `isAccessibilityElement = true`, label/value/hint/identifier, traits — `.button`/`.staticText`/`.image`/`.header`/`.link`/`.adjustable` по роли, `.selected`, `.notEnabled` при `isEnabled == false`; custom actions → `UIAccessibilityCustomAction(name:)` с handler по `id`. Group (§3.2): `isAccessibilityElement = false`, `accessibilityContainerType = .semanticGroup`, label группы, `accessibilityElements` = proxies детей. Заполняется только из опубликованных значений; live `Node` никогда не читается из getters. |
| Frame (D46) | `accessibilityFrame` | Host-space visible AABB из дерева, конвертируемый в screen space через `UIAccessibility.convertToScreenCoordinates(_:in: host)` при **каждом чтении** — перемещение host/window меняет ответ без layout pass. |
| Actions (D43) | `accessibilityActivate`/`Increment`/`Decrement`, custom handlers → `NativeProxyCoordinator.perform` → `bridge.performAccessibilityAction` | Каждое действие проходит live guard bridge: leaf в текущем дереве, живой маршрут, enabled для `.activate`. Disabled, hidden (вне scope), stale proxy после detach/нового attach — `false`, ничего не вызывается. Keyboard focus не меняется (D45). |
| Diff/reuse и уведомления (D47) | `NativeProxyCoordinator.apply`, `TrellisHostView.announceAccessibilityTree` | Proxies переиспользуются по ID внутри mount, дети обновляются раньше родителей; после `onSemanticsPublished` (proxies уже обновлены) bridge вызывает `onAccessibilityTreeChanged` только при изменившемся дереве → host постит `UIAccessibility.post`: `.screenChanged` при смене scope/mount (первое дерево, modal open/close), иначе `.layoutChanged` с аргументом — proxy сфокусированной ноды. Равное дерево (тот же value, paint-only) не уведомляет. Test hook `accessibilityNotificationSink`. |
| Тесты в матрице | `Package.swift` (A08), `Tests/TrellisRenderTests/UIKitAccessibilityTests.swift` | Под `canImport(UIKit)`, выполняются на iOS/tvOS Simulator в C27-матрице (`xcodebuild test`), не только Core. |

## Тесты

iOS 26.5 Simulator (iPhone 17 Pro) и tvOS 26.5 Simulator (Apple TV 4K 3rd gen) —
`xcodebuild test -only-testing:TrellisRenderTests`: 101 теста, обе платформы зелёные.

| Тест | Приёмка |
|---|---|
| `a09_hostExposesTheTreeAsProxiesWithPropertiesAndScreenFrames` | native enumeration: host не element, roots `[card, background]`; card — semantic group с label и тремя детьми (реальные native containers, §3.2); traits header/button/adjustable+selected; label/value/hint/identifier/custom action; `accessibilityFrame == convertToScreenCoordinates(committed frame)`, 120×44; первое дерево — `.screenChanged` |
| `a09_actionsRouteThroughTheBridgeAndRespectEnabledAndStaleness` | `accessibilityActivate` → activation `.accessibility`, focus не меняется; custom handler `true`; increment/decrement → handler; не-activatable — `false`; disabled → `.notEnabled`, `false`; после `detach()` старый proxy → `false` |
| `a09_valueChangeKeepsIdentityNoOpDoesNotNotifyAndModalHidesTheBackground` | value change — тот же proxy, `.layoutChanged`; same value и paint-only — без уведомления; modal scope → roots `[card]`, background без proxy и без действия, `.screenChanged` с аргументом focused; закрытие scope восстанавливает |
| `a09_resizeAndWindowMoveUpdateFramesWithoutTouchingIdentity` | перемещение host — frame пересчитан из committed frame через host при чтении; resize — новый commit, тот же proxy, тот же размер |

Cursor VoiceOver, чтение реальных названий и активация выбранной карточки голосом — ручная
проверка A11 (unit test не заменяет её).

## API baseline

`TrellisUIKit`: `TrellisHostView.isAccessibilityElement`/`accessibilityElements` overrides;
этот отчёт — review note.
