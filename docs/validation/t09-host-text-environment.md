# T09 — Environment в хостах (`TrellisUIKit`/`TrellisAppKit`)

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует D51 ([decisions.md](../decisions.md), [ADR 0015](../adr/0015-node-host-bridge-attach-gains-text-environment.md)).
Зависит от T05 ([t05-coretext-measurement.md](t05-coretext-measurement.md)).

## 1. Что добавлено

`Sources/TrellisCore/Text/TextRenderer.swift`: `Node.setTextRenderer(_:)` и
`Node.setLocaleIdentifier(_:)` — convenience-обёртки над
`setEnvironment(TextRendererKey.self, to:)`/`setEnvironment(LocaleKey.self,
to:)`, тем же видом, что уже есть `setLayoutDirection`/`setSafeAreaInsets`.

`Sources/TrellisRender/NodeHostBridge.swift`: `attach(...)` получает два новых
именованных параметра `textRenderer: (any TextRenderer)? = nil`,
`localeIdentifier: String? = nil` — применяются к корню внутри `attach`, до
первого `coordinator.invalidate(...)`, так что первый flush уже видит полное
окружение (см. ADR 0015 — почему не отдельный вызов после `attach`). Новый
`updateLocaleIdentifier(_:)` — симметрично `updateLayoutDirection`.

`Sources/TrellisUIKit/TrellisHostView.swift` и
`Sources/TrellisAppKit/TrellisHostView.swift` (идентичная логика на обеих
платформах):

- `attach(root:)` передаёт `textRenderer: CoreTextRenderer()`,
  `localeIdentifier: currentLocaleIdentifier` (`Locale.current.identifier`).
- `updateBridgeState()` — уже вызываемый на resume/trait-change/window-move —
  теперь также зовёт `bridge?.updateLocaleIdentifier(currentLocaleIdentifier)`,
  рядом с существующими `updateSafeArea`/`updateLayoutDirection`.
- Новый `installLocaleObserver()` регистрирует `localeDidChange` на
  `NSLocale.currentLocaleDidChangeNotification` один раз за время жизни view
  (внутри `ensureBridge()`, которая сама создаётся один раз) — системное
  событие, не привязанное к конкретной scene/window, в отличие от
  `installSceneObservers`/`installWindowObservers`. `deinit`'s
  `NotificationCenter.default.removeObserver(self)` уже покрывает и эту
  регистрацию.

## 2. Тесты и результаты

9 новых тестов, весь пакет зелёный на трёх платформах:

| Платформа | TrellisCoreTests | TrellisRenderTests |
|---|---|---|
| macOS (`swift test`, AppKit-guarded тесты реальные) | — | — (588 тестов пакета целиком) |
| iOS 26.5 Simulator (UIKit-guarded тесты реальные) | 419/419 | 166/166 |
| tvOS 26.5 Simulator (UIKit-guarded тесты реальные) | 419/419 | 166/166 |

`Tests/TrellisRenderTests/AppKitTextEnvironmentTests.swift` (3, `#if
canImport(AppKit)` — реально выполняются только на macOS) и
`Tests/TrellisRenderTests/UIKitTextEnvironmentTests.swift` (3, `#if
canImport(UIKit)` — реально выполняются только на iOS/tvOS Simulator),
идентичный набор на обеих платформах:

- `t09_attachInstallsCoreTextRendererAndTheSystemLocale` — после `attach`
  `root.environment.textRenderer is CoreTextRenderer` и
  `root.environment.localeIdentifier == Locale.current.identifier`.
- `t09_localeChangeNotificationRemeasuresTheAttachedTree` — тест не может
  управлять настоящей системной локалью, поэтому публикует само уведомление
  (`NSLocale.currentLocaleDidChangeNotification`) — тот же код, что и
  реальная смена, реагирует одинаково; проверяет, что
  `root.environmentSnapshot.revision` растёт (перемер запрошен).
- `t09_hostedTextNodeMeasuresDifferentlyFromTheHeadlessFallback` — одна и та
  же строка через реальный `TrellisHostView` (`CoreTextRenderer`) и через
  «голый» `NodeHostBridge` без `textRenderer` (`PortableTextMeasurer`)
  дают разную итоговую высоту — конкретное измеримое доказательство того, что
  T09 действительно подключает CoreText, а не молча остаётся на fallback.
  (Найден и исправлен до прогона: `NodeHostBridge(hostLayer: CALayer())` с
  временным литералом — `hostLayer` хранится `weak`, и без отдельной
  `let`-переменной слой освобождался ARC ещё до вызова `attach`, из-за чего
  `attach` возвращал `false` по `reason=invalid-input`. Это баг теста, не
  кода карточки — исправлено сохранением слоя в `let headlessHostLayer`.)

## Приёмка T09

- `TextRendererKey`/`LocaleKey` выставляются обоими `TrellisHostView` при
  `attach` и при смене locale; scale — из request (не тронуто, уже было) —
  done, §1, тесты §2.
- Смена locale/direction → перемер (environment revision уже поднимает
  geometry) — done, `t09_localeChangeNotificationRemeasuresTheAttachedTree`;
  direction не менялся в этой карточке (уже работал с T01).
- Без хоста — fallback, с хостом — CoreText — done,
  `t09_hostedTextNodeMeasuresDifferentlyFromTheHeadlessFallback`.
- RTL переключение меняет выравнивание без правки нод — не новое для T09
  (направление уже было environment-полем с T01/D50); отдельно не
  перепроверялось этой карточкой, т.к. T09 добавляет только
  locale/textRenderer, не направление.
- Тесты на обоих хостах — done, идентичные наборы в
  `AppKitTextEnvironmentTests.swift`/`UIKitTextEnvironmentTests.swift`.

Следующая карточка — T10 (Lifecycle и отмена).
