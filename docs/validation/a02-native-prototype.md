# A02 — Нативный путь до масштабного переноса: proxy без UIView

Дата: 2026-09-11. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решение D44 ([decisions.md](../decisions.md)). Ни один модуль Trellis в прототипе не
участвует — проверяется платформенный механизм, на который опираются A08–A10.

## Выбор: `UIAccessibilityElement` + `UIFocusItem` в одном NSObject-proxy

Сравнивались два способа предъявить CALayer-ноды системному focus engine tvOS и
accessibility:

| | NSObject-proxy (`UIAccessibilityElement`, `UIFocusItem`) | Прозрачные `UIView`-proxy |
|---|---|---|
| Объектов на ноду | 1 (`NSObject`, без CALayer) | 1 `UIView` + 1 `CALayer` — удваивает число слоёв (C26/C30 считали слои узким местом) |
| Создание 1000 | **1.0–1.5 ms** (tvOS/iOS Simulator, Debug) | 15.7–19.6 ms |
| Hit-testing касаний (H07) | не участвует: `container.hitTest` возвращает container — тест `a02_proxiesDoNotInterceptTouchHitTesting` | перехватывает касания, пока каждый view не выключит `isUserInteractionEnabled`; порядок subviews начинает конкурировать с `HitTestSnapshot` (D32) |
| VoiceOver | один элемент на ноду: `container.accessibilityElements = proxies`, `isAccessibilityElement = false` у container | view сам по себе — второй элемент на ту же ноду, если не отключить |
| Focus frame | `UIFocusItem.frame` в `coordinateSpace` container — committed frame ноды напрямую | `UIView.frame`, нужно синхронизировать с CALayer |
| Отрисовка | не рисует — `LayerRenderer` остаётся единственным художником | рисует прозрачный слой |

Выбран NSObject-proxy. Один объект на `(mountEpoch, NodeID)` для focus и accessibility,
без второго представления `NodeID` (A09).

## Evidence

### Headless (`xcodebuild test`, iOS 26.5 и tvOS 26.5 Simulator)

`Tests/TrellisRenderTests/NativeFocusProxyPrototypeTests.swift` — 3 теста, pass на обоих
симуляторах (73 теста `TrellisRenderTests` на каждом):

| Тест | Что доказано |
|---|---|
| `a02_proxiesAreTheOnlyAccessibilityElementsAndActivateOnce` | container не element; ровно два `accessibilityElements`; label `Card 1`, traits `.button`; `accessibilityFrame` в screen-координатах `(110, 40, 60, 60)` через `UIAccessibility.convertToScreenCoordinates`; `accessibilityActivate()` вызывает действие ровно у нужного proxy |
| `a02_proxiesDoNotInterceptTouchHitTesting` | `hitTest` под proxy возвращает container — touch-путь H07 не затронут |
| `a02_thousandProxiesCostVersusViews` | 1000 proxies за ~1 ms против ~16 ms у 1000 `UIView`; `focusItems(in: bounds)` содержит все 80 пересекающих proxies (плюс subviews, которые `UIView` возвращает сам с tvOS 16) |

`Tests/TrellisRenderTests/NativeAccessibilityElementPrototypeTests.swift` — macOS,
`a02_appKitExposesRealAccessibilityElementsWithFrameAndPress`: `NSView` с
`isAccessibilityElement() == false`, role `.group`, `accessibilityChildren()` — два
`NSAccessibilityElement`; у второго label `Card 1`, role `.button`, parent — host, screen
frame получен цепочкой flipped host → window (`convert(_:to: nil)` даёт `y = 200` для
`y = 60` сверху в 300-pt view) → `convertToScreen`; `accessibilityPerformPress()` вызывает
действие ровно один раз у нужного элемента.

### Ограничение headless-раннера

Внутри xctest-хоста на tvOS Simulator focus system **инертен**: `UIFocusSystem.focusSystem(for:)`
не `nil`, но ни `requestFocusUpdate(to:)` + `updateFocusIfNeeded()`, ни прокрутка run loop не
делают сфокусированным даже обычный `UIButton` (`focusedItem == nil`, окно key, scene
`foregroundActive`). Тест на переходы focus из файла удалён, а не оставлен «зелёным при любом
исходе». Это ограничение фиксируется как известное: unit test не закрывает remote-интеграцию,
как и предупреждала карточка.

### Playground-tvOS, tvOS 26.5 Simulator (Apple TV 4K 3rd gen), временный probe

В `TVPlaygroundViewController` был временно добавлен `A02Container: UIView`
(`focusItems(in:)` → 3 proxy без UIView, `canBecomeFocused == false`,
`preferredFocusEnvironments` → запрошенный proxy) поверх host; три `CALayer`-карточки
рисуются самим container; proxy подсвечивает свою карточку рамкой в `didUpdateFocus`.
Через 2 с — программный запрос на третий proxy. Лог `xcrun simctl launch --console-pty`:

```
A02PROBE focusItems(in: (0.0, 0.0, 1920.0, 1080.0)) -> 3
A02PROBE didUpdateFocus self=0 prev=nil next=Optional(0) heading=0        ← системный initial focus на proxy 0
A02PROBE t=2 focused=Optional(0)
A02PROBE didUpdateFocus self=0 prev=Optional(0) next=Optional(2) heading=0 ← focusOut на 0
A02PROBE didUpdateFocus self=2 prev=Optional(0) next=Optional(2) heading=0 ← focusIn на 2
A02PROBE after request focused=Optional(2)                                 ← синхронно после updateFocusIfNeeded
A02PROBE t=4 focused=Optional(2)
A02PROBE didUpdateFocus self=2 prev=Optional(2) next=nil heading=0         ← окно потеряло активность (активирован Simulator.app)
A02PROBE didUpdateFocus self=2 prev=nil next=Optional(2) heading=0         ← возврат: тот же proxy
```

Доказано в реальном приложении: (1) система принимает `UIFocusItem` без UIView и сама
выбирает начальный focus среди proxies; (2) программный запрос `preferredFocusEnvironments`
+ `requestFocusUpdate(to: container)` + `updateFocusIfNeeded()` синхронно переводит focus,
оба proxy получают `didUpdateFocus` с корректными `previously/nextFocusedItem` — это и есть
native confirmation D44; (3) потеря и возврат window activity возвращают focus на прежний
proxy без нашего участия. Patch не закоммичен — код A08 реализует то же в `TrellisHostView`.

**Не доказано здесь:** стрелки Siri Remote и `Select` → activation. Попытка послать
клавиши в Simulator.app через AppleScript упёрлась в permission dialog automation;
физический Apple TV — «нет доступа». Обе проверки — ручной протокол A11; headless unit test
их не закрывает (карточка это предупреждала).

## Решение D44 — окончательно

- Proxy: `final class … : UIAccessibilityElement, UIFocusItem`, один на `(mountEpoch,
  NodeID)`, `frame` = committed visible bounds в host space, `accessibilityFrame` —
  screen-space через host.
- Host `TrellisHostView` (UIKit): `focusItems(in:)` = `super + proxies` только при
  `traitCollection.userInterfaceIdiom == .tv` (на iPadOS клавиатурный Tab идёт через engine
  D38, второго владельца не заводим); `preferredFocusEnvironments` — pending request engine;
  `canBecomeFocused == false`.
- Схема одного источника: engine → `requestFocusUpdate(to: host)` с pending token →
  `didUpdateFocus` proxy → `engine.focus(id, reason: .native)`; native callback с другим
  item побеждает и очищает token.
- Стоимость: ~1 µs на proxy, без CALayer; бюджет A12 — proxies ≤ число элементов
  текущего снимка.
- SDK: `UIFocusItem.frame` — tvOS 12+/iOS 12+, `focusItems(in:)` на UIView — 16+
  (deployment target проекта — 16); все protocol-требования реализованы без
  `@preconcurrency` (класс `@MainActor`, protocol методы неизолированные — компилятор
  принял на Swift 6.3 strict concurrency).

## Приёмка

| Критерий | Статус |
|---|---|
| Два CALayer-карточки, реальные focus items, preferred focus | done (Playground probe, лог выше) |
| Переход Select → ровно одна activation | **не проверено** — ручной A11 (нет автоматизации ввода, нет устройства) |
| Возврат после window loss | done (лог: prev=2→nil, nil→2) |
| Custom `UIFocusItem` vs UIView proxies — выбран один | done — NSObject proxy |
| Frames, hit interception, отсутствие дубликатов VoiceOver | done (headless тесты) |
| Две доступные карточки UIKit и AppKit: label/role/frame/action | done (headless тесты, действие вызвано через system API, не notification) |
| Стоимость 1000 proxies | done — ~1 ms |
| Apple TV (физический) | нет доступа |
