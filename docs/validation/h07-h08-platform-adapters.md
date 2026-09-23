# H07/H08 — Платформенная проводка: UIKit touches, AppKit mouse

Дата: 2026-09-11. Карточки C-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5, решения D16, D27, D30 ([decisions.md](../decisions.md)). По G01 адаптеры **не** переносят
собственный touch/mouse pipeline Weave (`UIKitAdapter.swift`/`AppKitAdapter.swift`) — они
переводят нативный ввод в `PointerData` и вызывают уже перенесённое ядро
(`NodeHostBridge.send(_:_:)`, H02–H06); никакой отдельной state machine здесь нет.

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| `UITouch` → `PointerData` | `Sources/TrellisUIKit/TrellisHostView.swift`: `touchesBegan/Moved/Ended/Cancelled` | `touch.location(in: self)` — уже в системе координат host view (top-left, как ожидает `PointerData`, D30). Нефинитная координата → `nil`, событие не отправляется (адаптер отклоняет до `PointerData`, ни `LayoutPoint`'а). |
| Стабильный `UITouch` → pointer ID | `touchPointerIDs: [ObjectIdentifier: UInt64]` | Присваивается в `touchesBegan`, снимается в `touchesEnded`/`touchesCancelled` — двух коллбэков, которые UIKit документированно всегда вызывает для отслеживаемого touch. `ObjectIdentifier(touch)` — корректный и дешёвый ключ: `UITouch` переиспользуется на весь жизненный цикл одного касания и никогда — между двумя разными. |
| Single-touch, детерминированный отказ (D30) | `bridge.send(.pointerDown, data)` вызывается **для каждого** touch в батче | Не отдельная логика адаптера: `PointerSessions` (H04) уже детерминированно отклоняет второй одновременный `pointerDown` (`.secondaryPointer`) без сессии и без побочных эффектов — адаптер просто не пытается выбрать «победителя» сам. `touches` — `Set`, порядок недетерминирован между процессами; `orderedDeterministically(_:)` сортирует по `timestamp` для воспроизводимости в пределах одного запуска. |
| `touchesCancelled`, уход окна/scene, detach — общий cancel path | не новый код: `.pointerCancel` идёт через тот же `bridge.send(_:_:)` → `PointerSessions`; `sceneWillDeactivate`/`didMoveToWindow(window == nil)` уже вызывали `bridge.suspend()` (H04) | Дополнено: `didMoveToWindow()` при уходе из окна также очищает `touchPointerIDs` — UIKit не гарантирует `touchesCancelled` для touch, чей responder убран из иерархии целиком (в отличие от backgrounding, где `touchesCancelled` вызывается); сама сессия в `PointerSessions` уже закрыта `suspend()`, здесь только адаптерская bookkeeping не резервирует id навсегда. |
| `mouseDown`/`mouseDragged`/`mouseUp` | `Sources/TrellisAppKit/TrellisHostView.swift` | `mouseDown` создаёt сессию через `bridge.send(.pointerDown, …)`; `mouseDragged`/`mouseUp` продолжают её тем же `pointerID`. Координаты — `convert(event.locationInWindow, from: nil)`: `isFlipped == true` у `TrellisHostView`, поэтому `convert` уже даёт top-left локальные координаты (проверено эмпирически: `convert(NSPoint(x:50,y:20), from: nil)` на 400pt view даёт `(50, 380)` — корректный флип без окна, `location:` в `NSEvent` остаётся в нативной bottom-left системе). |
| Secondary buttons игнорируются (D30) | `rightMouseDown`/`otherMouseDown` не переопределены | Стандартный responder chain обрабатывает их сам; адаптер никогда не создаёт для них `PointerData`. |
| resign key / уход окна / detach — тот же cancel path | не новый код | `windowDidResignKey` уже вызывал `bridge?.suspend()` (H04), который делает `pointerSessions.cancelAll(...)`; `detach()` — тот же путь через `bridge.detach()`. |
| Вызов через существующий `NodeHostBridge`/`TrellisHostView` | оба файла | Ни одного нового view/типа хоста — только новые override-методы на уже существующих `TrellisHostView`. |

## Почему UIKit не тестируется автотестами напрямую

`UITouch` не имеет публичного инициализатора — сконструировать его в unit-тесте невозможно.
`Package.swift` не заводит тестовую цель, зависящую от `TrellisUIKit` (`TrellisRenderTests`
зависит от `TrellisAppKit`, не от `TrellisUIKit`); локальный `swift test` собирается только под
macOS, где `#if canImport(UIKit)` не компилируется вовсе. Это состояние существовало и до этой
карточки, не введено ею. То, что действительно ниже адаптера (снимок, dispatch, сессия,
арбитр, control), уже исчерпывающе протестировано на уровне ядра (H02–H06) и на уровне
bridge-входа (`bridge.send(_:_:)` в `PointerSessionBridgeTests.swift`, H04) — без конструирования
`UITouch`, ровно как просит приёмка H07. Сам адаптер оставлен тонким намеренно (H07 явно этого
просит) и проверяется:

1. **Сборкой на реальных SDK.** `xcodebuild -destination 'generic/platform=iOS' build` и
   `generic/platform=tvOS build` — оба зелёные (тот же файл, без платформенных `#if`, помимо
   общего `#if canImport(UIKit)`).
2. **Реальным прогоном тестов на симуляторе.** `python3 Scripts/verify_bootstrap.py --matrix`
   — `xcodebuild test` на iOS Simulator и tvOS Simulator (реальные `simctl`-устройства, не
   build-only) зелёный целиком; это подтверждает, что `TrellisUIKit` линкуется и не ломает
   остальной пакет на этих платформах, хотя сам файл touch-хендлинга не имеет отдельной тестовой
   цели.
3. **Ручной сценарий — явно отложен на H09.** Реальный тап, доходящий до `ControlNode`, требует
   видимой интерактивной сцены; такой сцены в Playground сегодня нет — её строит H09
   («список тапаемых карточек»), которая по плану и так зависит от H07 (§4: `H07 (iOS), H08
   (macOS)` → `H09`). Утверждать «ручной сценарий пройден» здесь было бы неверно — это
   незакрытый пункт H07, закрывается H09.

## Почему AppKit тестируется автотестами напрямую

В отличие от `UITouch`, `NSEvent` имеет публичный фабричный метод
(`NSEvent.mouseEvent(with:location:...)`), и `TrellisRenderTests` уже зависит от `TrellisAppKit`
(`AppKitHostViewTests.swift`, C18). Это позволило написать реальный, автоматизированный
end-to-end тест: настоящий `mouseDown`/`mouseDragged`/`mouseUp` через **реальные** переопределения
`TrellisHostView`, до активации `ControlNode` — не просто до `bridge.send(_:_:)`. Это превышает
формальную приёмку H08 (которая тоже просит только «build + ручной сценарий»), но было
естественно сделать раз инструмент уже под рукой.

## Тесты

`Tests/TrellisRenderTests/AppKitPointerInputTests.swift` — 5 новых тестов, все зелёные:

| Тест | Что проверяет |
|---|---|
| `test_appKitHostView_mouseDownUpInsideActivatesControl` | down/up внутри через реальные `NSEvent` → `isPressed`, активация ровно один раз |
| `test_appKitHostView_mouseDraggedOutsideThenUpDoesNotActivate` | drag наружу снимает `isPressed`; up снаружи не активирует |
| `test_appKitHostView_mouseUpOutsideAfterDownInsideDoesNotActivate` | up вне control без промежуточного move — не активирует |
| `test_appKitHostView_nonFiniteLocationSendsNothing` | `NaN`-координата отклоняется адаптером, не создаёт сессии |
| `test_appKitHostView_windowResignationCancelsAnActivePress` | `detach()` (тот же путь, что `windowDidResignKey`) отменяет активный press без активации |

`python3 Scripts/check_all.py` — зелёный. `python3 Scripts/verify_bootstrap.py --matrix` —
зелёный целиком: `macos-universal`, `ios-device`, `tvos-device` (build-only), `ios-simulator`,
`tvos-simulator` (реальный `xcodebuild test`). API baseline `TrellisAppKit`
(+`mouseDown`/`mouseDragged`/`mouseUp`) и `TrellisUIKit`
(+`touchesBegan`/`touchesMoved`/`touchesEnded`/`touchesCancelled`) — только добавления;
`TrellisUIKit` tvOS-поверхность по-прежнему совпадает с iOS (не понадобился отдельный файл).

## Provenance

Ни `UIKitAdapter.swift`, ни `AppKitAdapter.swift` Weave не использованы как источник (G01:
их собственный `HitTester`/`EventDispatcher`/`GestureArena` не используется даже самим Weave,
дублирующие ручные state machines — нечего и незачем переносить). Оба файла — заново, поверх
уже существующего `TrellisHostView` (C17/C18).

## Не входит

Ручной/симуляторный тап до `ControlNode` на iOS — явно отложено на H09 (см. выше). Нагрузка и
lifecycle под реальным вводом — H10.
