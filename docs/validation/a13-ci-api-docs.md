# A13 — CI, API baseline и документация подключения

Дата: 2026-09-12. Последняя карточка [implementation-plan-3.md](../implementation-plan-3.md) §5;
зависимости A11–A12 закрыты (со срезами, см. итог).

## CI и матрица

Команда: `TRELLIS_LOG=off python3 Scripts/check_all.py --matrix`.

| Проверка | Результат |
|---|---|
| policy 2.0.0, `test_policy.py`, `test_verifier.py` | pass — `@unchecked Sendable`/`nonisolated(unsafe)`/`@preconcurrency` нет; `#if os(...)` нет (tvOS-ветки выбираются по `userInterfaceIdiom`); UIKit/AppKit только в адаптерах; все `public`/`open` документированы |
| swift-format strict, toolchain pins (Swift 6.3.3, Xcode 26.6, SDK 26.5) | pass |
| `swift build`/`swift test` macOS arm64, warnings-as-errors | pass — 492 теста (`TrellisCoreTests` + `TrellisRenderTests`) |
| Внешний consumer (`verify_bootstrap.py`, без `@testable`) | pass — расширен focus + AX API, см. ниже |
| API baseline `check_api.py --tvos` | pass — TrellisCore 894, TrellisRender 108, TrellisAppKit 32, TrellisUIKit 36 символов; tvOS surface = iOS baseline |
| 46 macOS screenshot references (S01–S23 + overlay) | pass |
| `TRELLIS_LOG` в реальном процессе | pass |
| macOS generic `ARCHS=arm64 x86_64` | build pass |
| iOS generic / tvOS generic (device SDK, без code signing) | build-only pass — не запуск на устройстве |
| iOS 26.5 Simulator | `xcodebuild test` pass — 384 Core + 105 Render, включая UIKit-adapter тесты A08/A09/A12 |
| tvOS 26.5 Simulator | `xcodebuild test` pass — 384 Core + 105 Render, включая proxies/handshake |

Native adapter тесты входят в матрицу через зависимость `TrellisRenderTests` → `TrellisUIKit`
(A08): на macOS модуль пуст, на Simulator файлы под `canImport(UIKit)` выполняются.

## Внешний consumer

`Scripts/verify_bootstrap.py` smoke расширен (тот же `EventControl: ControlNode`):
`accessibility.label/customActions`, `onAccessibilityAction`; `SemanticSnapshot(geometry:root:…)`
и `focusCandidates`; `FocusEngine.apply/move/sendKey` — Tab фокусирует control, Return
down/up активирует ровно один раз с `lastActivationSource == .keyboard`, Tab на границе —
`.unchanged`; `AccessibilityTree.build` — reading order, role `.button`, custom action;
`performAccessibilityAction(.activate/.custom/.increment)` — `true/true/false`; disabled →
`false` без activation. Компилируется и выполняется без `@testable`.

## API baseline

Baseline обновлялся отдельной командой на каждой карточке с review note
(A03, ADR 0013/A04, A06, A07, A08, A09, A10, A12); единственное source-breaking
изменение этапа — `Event.pointer: PointerData?` и новые enum cases
([ADR 0013](../adr/0013-event-pointer-becomes-optional.md)). A13 подтверждает `PASS` без
`--update`.

## Документация

- README: раздел «Focus, клавиатура и accessibility» — metadata, action handling, focus
  scope, роли/policies, владение/отмена, пример `BuyButton` без Flux и `@testable`
  (сверен с consumer); таблица документов дополнена планами 2/3.
- AGENTS.md: карта дерева (`Semantics`/`Focus`, `NativeProxies`, `AccessibilityElements`),
  правило `#if os(...)`/runtime idiom и «native объекты не читают live Node»,
  UIKit-тесты — только на Simulator.
- decisions.md D35–D48, ADR 0013, source-provenance (по строке на карточку), defects
  #33–#35 закрыты.

## Итоговая таблица этапа

| Что | Полностью | Только Simulator / automated | Недоступно / открыто |
|---|---|---|---|
| Focus core: Tab/Shift-Tab, стрелки, overrides, transaction, scope, restoration (A04–A05) | headless тесты; macOS automated `NSEvent` run | — | — |
| Semantic tree, четыре policies, reading order (A06) | headless + native деревья macOS/iOS/tvOS | — | — |
| Единая activation, key press-cycle, AX actions (A07) | headless; macOS keyboard automated; iOS real touch | — | физическая клавиатура не проверялась вручную |
| AppKit клавиатура и responder chain (A08) | реальные `NSEvent` через host в тестах и Playground | — | ручной Tab/Shift-Tab/Space/Return в Playground — не выполнялся руками |
| UIKit presses / iPad клавиатура (A08) | mapping + engine путь на iOS Simulator | — | hardware keyboard на iPad — не проверено |
| tvOS native focus proxies и handshake (A08) | unit на Simulator; Playground-tvOS: system focus подтверждает engine request | — | стрелки Siri Remote/Select, выход к соседнему native control — не проверено (нет автоматизации ввода); физический Apple TV — нет доступа |
| UIKit accessibility (A09) | native enumeration/actions/notifications на iOS/tvOS Simulator; native tree dump из Playground | — | VoiceOver cursor и spoken labels на iPhone/iPad/Apple TV — не проверено |
| AppKit accessibility (A10) | native enumeration/actions/frames/notifications; два окна; window move | — | VoiceOver на Mac — не проверено |
| Нагрузка (A12) | 1000 элементов, bursts, proxies bounded, weak release, глубина 1500 | release-замер macOS | замер на устройствах — нет доступа |
| CI (A13) | macOS + iOS/tvOS Simulator tests, device build-only | — | XCUITest/физический ввод не заявляются |

Открытые пункты полной приёмки N03 — в A11 (ручной протокол VoiceOver/Siri Remote/iPad
клавиатура, физические устройства). Новых дефектов при A13 не найдено; реестр
[defects.md](../defects.md) — #33–#35 закрыты.
