# M11 — Session, overlay и общие элементы

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §6,
реализует D70–D74 против таблицы состояний и открытых архитектурных решений,
зафиксированных [m10-transition-contract.md](m10-transition-contract.md). Первая карточка
результата B, которая пишет production-код в `Sources/TrellisCore` и `Sources/TrellisRender` —
M10 была контрактом и прототипом (`Tests/` только).

## 1. Два архитектурных решения, оставленных M10 явно открытыми — приняты здесь

### 1.1. Session-геометрия — отдельный explicit-animation путь, не через `LayerAnimator`

`Sources/TrellisRender/Transition/TransitionAnimator.swift` — маленький, module-internal класс,
параллельный `LayerAnimator`, не построенный поверх него. Причина (подтверждена чтением
`LayerAnimator.swift` целиком перед началом, как требовала карточка): временный overlay-слой
не имеет `NodeID`, значит не подходит под `LayerAnimator.active`'s адресацию
`(mountEpoch, NodeID, property)`. `TransitionAnimator` переиспользует те же два свойства
безопасности, что и `LayerAnimator` (не изобретая заново):

- **retarget от живого presentation-значения** (D66) — `TransitionAnimator.play` читает
  `layer.presentation()?.value(forKeyPath:)`, если под тем же ключом уже есть анимация, вместо
  устаревшего "before";
- **stale-completion cleanup** (D66 п.3) — но на грануляции **сессии**, не
  `(layer, property)`: один `UInt64 currentToken`, а не токен на каждый `(layer, keyPath)`,
  ровно как того требует D71 («один токен на сессию... retarget отменяет весь набор слоёв
  разом»).

### 1.2. `sceneReadiness`/D69 — параллельный источник, не через `LayerAnimator.active`

`NodeHostBridge.sceneReadiness`'s `animationReady` теперь дополнительно проверяет приватный
`isTransitionSessionInFlight` (`true`, если сессия существует и не в `.presented`) — второй,
независимый источник, скомбинированный через `&&` с уже существующим
`!renderer.hasActiveAnimations(mountEpoch:)`. Выбран вариант «б» из двух, которые M10 назвала
(`m10-transition-contract.md` §3): не заводить session-активность в тот же `LayerAnimator.active`
(это смешало бы владение — overlay-слои принадлежат `LayerRenderer`, а не отслеживаются
`LayerAnimator`), а расширить сам композитный критерий в `NodeHostBridge`. `SceneReadiness`'s
публичная форма (три `Bool`) не меняется — расширяется только то, что уже вычисляет
`animationReady`, не публичный тип. Проверено тестами: `sceneReadiness?.animationReady == false`
во время `opening`/`settling`, `== true` в `presented`/после закрытия
(`M11TransitionSessionTests.swift`).

## 2. Реализовано по D70–D74 (детали формы)

### 2.1. `Role` (D70) — `TrellisCore`

`Sources/TrellisCore/Transition/Role.swift` — `String`-подложенный, `RawRepresentable`,
`ExpressibleByStringLiteral`, не `enum`, ровно как зафиксировала M10 §1.1. `.hero`/`.title` —
`static let`-константы, не case'ы: любой consumer всё равно может завести `Role("anything")`
(проверяется структурно самим типом, не тестом на конкретное имя).

Дубликат роли и пропавший `source` валидируются на **prepare** (`presentTransition(_:)`), до
создания какого-либо слоя — тест `m11_duplicateRoleIsRejectedBeforeAnyMovement`:
`transitionSession == nil` и `card`'s слой не тронут после отклонённого запроса.

### 2.2. `TransitionSession` (D71) — форма 1:1 с settled-текстом M10

`Sources/TrellisRender/Transition/TransitionSession.swift`: value-тип, одно optional-свойство
на bridge (`NodeHostBridge.transitionSession`), поля `sourceNodeID`/`destinationRootID`
(`NodeID`), `roles: [Role: TransitionRoleEndpoints]`, `overlayLayer: CALayer`
(`LayerRenderer`-владение, тот же паттерн, что `rasterLayers`), `state`, `progress`, `token`
(один на сессию). Ничего сверх того, что M10 §1.2 уже специфицировала, не добавлено.

**Растровая политика заголовка (D71).** Два независимых endpoint-растра
(`LayerRenderer.materializeTransitionRasterLayer(role:side:parent:)`,
`transitionRasterLayers: [TransitionRasterKey: CALayer]` — третья таблица общего вида с
`rasterLayers`, session-scoped, не node-scoped, как и предлагала M10 §3) + crossfade
(`opacity` 1→0 / 0→1 через `TransitionAnimator`). Растеризация — прямой синхронный вызов
`CoreTextRenderer().rasterize(_:context:)` на подготовке (тот же путь, что M10's прототип), не
через `DisplayScheduler`: у title-эндпоинта нет своего `NodeID`, а подготовка уже разовая
(D71) — фоновый job с отменой/коалессингом не даёт здесь выгоды. Оба выбора, которые M10 §3
называла равноценными, использованы: ручная растеризация (выбрана и обоснована выше) вместо
`DisplayScheduler`.

**Crop/fit картинки (D71's открытый пункт) — закрыт.** Роль-геометрия (`.hero`-подобная, любая
не-текстовая роль) на подготовке один раз читает `contentsGravity` и `contents` с той стороны,
которую движение раскрывает (`toNode ?? fromNode`), и переносит их на overlay-слой без
повторного чтения на кадр — `buildTransitionVisuals` делает это один раз при построении
`targets`, не в `TransitionAnimator.play`'s цикле кадров (которого у явной `CABasicAnimation`
и нет — сама `CALayer.contentsGravity` не участвует в анимации, только геометрия/opacity).
Открытый пункт из `m10-transition-contract.md` §1.2 закрыт этой реализацией; в этой карточке
не заведён отдельный `ImageNode` (его нет в `Sources/` — не появляется скрытой зависимостью),
но правило общее: любой не-текстовый узел с растровым `contents` получает то же однократное
поведение.

### 2.3. Таблица состояний (D72) — реализована как есть, без пересмотра

`TransitionSessionState`/`TransitionSettleTarget` — прямая копия перечисления из
`m10-transition-contract.md` §1.3. M11's чек-лист требует только открытие/закрытие `.expand`
кнопкой (без жеста) — реализованы переходы `(нет сессии)→preparing→opening→presented` и
`presented→settling(closed)→(нет сессии)`, плюс повторный `present` (retarget, тот же
`overlayLayer`, новый `token`), отмена подготовки (source исчез), `detach()`/`suspend()`/Reduce
Motion на каждом активном состоянии (все ветки таблицы, кроме `interactiveClosing`, которую
M11 сознательно не подключает к живому жесту — М12). Форма состояния не потребовала изменений
для будущего жеста: `interactiveClosing` уже существует как case, `finishTransitionMotionInPlace`
уже умеет его завершать (`opening`/`interactiveClosing` в одной ветке), M12 добавит только
писателя `progress`, не новый case.

### 2.4. Modal scope (D73) — `FocusEngine.setScope` буквально

`completeTransitionMotion(direction: .opening, ...)` вызывает
`focusEngine.setScope(session.destinationRootID, root: root)` строго на границе
`opening → presented` (не в момент `presentTransition`) — прочитан `FocusEngine.setScope`/
`scopeID`/`restorationID` и `NodeHostBridge.focusScopeID` перед началом карточки, как и
требовал текст задания; ни `FocusEngine`, ни `focusScopeID`-проброс не изменены. Закрытие
(`direction: .closing`) вызывает `setScope(nil, root:)` — restoration уже даёт существующий
D40-путь.

**Одна логическая AX-репрезентация (D73).** Вместо изменения `AccessibilityTree.build`
используется уже существующий `AccessibilityChildrenPolicy.hide` (D42): при первом `present`
destination получает `.hide` немедленно (до какого-либо кадра overlay — превентивно, не
только в момент `presented`); на `opening→presented` source получает `.hide`, destination
восстанавливает исходную политику; на закрытии — наоборот; исходные политики обеих сторон
сохраняются один раз (`transitionSavedAccessibilityPolicies`) и восстанавливаются полностью,
когда сессия заканчивается. Проверено `m11_expandOpensAndClosesWithRealTextEndToEnd`:
`card.accessibility.childrenPolicy == .hide` в `presented`, `page`'s — нет; оба восстановлены
после закрытия.

## 3. Реализация чек-листа M11 (3 пункта)

1. **Подготовка endpoints/artifacts, локальные роли, координаты, временные слои, clipping,
   D71's политика заголовка** — `NodeHostBridge.buildTransitionVisuals(direction:)`. Перевод
   координат — `CALayer.convert(_:from:)` (реальный API слоя, не переизобретённая арифметика):
   `transitionHostRect(of:)` конвертирует `layer.bounds` каждого участвующего узла напрямую в
   систему `hostLayer`. Временные слои — `LayerRenderer.beginTransitionOverlay(on:)`/
   `materializeTransitionRasterLayer`/`endTransitionOverlay()`. Clipping — `masksToBounds = true`
   на каждом overlay-слое (та же D65-модель, что `rasterLayers`).
2. **`.expand`: открытие/закрытие кнопкой на одной session** —
   `NodeHostBridge.presentTransition(_:)`/`closeTransition()`, проверено сквозь настоящий
   `NodeHostBridge` + реальный оконный `CALayer` (`TransitionWindowHost`, тот же паттерн, что
   M02/M06/M10) + реальный `CoreTextRenderer` (не заглушка) — `m11_expandOpensAndClosesWithRealTextEndToEnd`.
3. **Покрытие: отсутствующий/удалённый source, дубликаты ролей, задержанный raster, повторный
   запрос, release временных layers** — все пять сценариев есть отдельными тестами (§4 ниже).

## 4. Тесты (`Tests/TrellisRenderTests/M11TransitionSessionTests.swift`, 7 тестов)

- `m11_expandOpensAndClosesWithRealTextEndToEnd` — оба направления, реальный текст (два разных
  растра на разных ширинах через реальный `CoreTextRenderer`), D69 readiness, D73 scope/AX.
- `m11_duplicateRoleIsRejectedBeforeAnyMovement` — диагностика до какого-либо кадра.
- `m11_missingSourceIsRejected` — неразрешимый `source` отклоняется целиком.
- `m11_sourceRemovedWhilePreparingCancelsTheSessionAndRestoresVisibility` — source исчезает
  посреди `preparing`; следующий commit находит его отсутствие и отменяет сессию.
- `m11_delayedDestinationMeasurementKeepsSessionPreparingUntilTheNextCommit` — destination
  примонтирован в то же синхронное окно, что и `presentTransition` (ещё не размерен);
  сессия остаётся `preparing`, source не трогается; следующий реальный commit (не опрос по
  кадру — тот же `onPostCommit`/`onDisplayOnly` хук, что уже существовал для display-work)
  довершает подготовку и переводит в `opening`.
- `m11_repeatedPresentRetargetsTheSameSessionRatherThanCreatingASecondCopy` — тот же
  `overlayLayer` (`===`), новый `token`, число title-растров не растёт (2, не 4).
- `m11_temporaryLayersAreReleasedOnCloseDetachAndSuspend` — три пути (close, detach,
  suspend), каждый проверен `hasTransitionOverlayForTesting`/`transitionRasterLayerCountForTesting`
  до/после — ни один слой не остаётся.

Полный прогон (`swift test`) — 676/676 тестов пакета зелёные, без регрессий в существующих
областях (Focus/AX/hit-test/text/animation), после этой карточки.

**Про завершение анимации в тестах.** `TransitionAnimator.play`'s `completion` — реальный
`CATransaction.setCompletionBlock`; M02 §1.4 (`m02-animation-prototype.md`) уже
задокументировала, что доставка такого колбэка не воспроизводится в XCTest/Swift-Testing
хостинге на этом toolchain (`LayerAnimator.completeIfCurrent` несёт тот же прецедент для D61's
собственных анимаций). `NodeHostBridge.forceCompleteTransitionMotionForTesting()` — новый,
module-internal test hook, вызывающий ту же логику завершения напрямую, тем же способом, каким
`LayerAnimator.completeIfCurrent` уже документирован как «exposed for direct invocation from
tests»: всё до этого момента (реальные `CABasicAnimation`, реальные `fromValue`/`toValue`,
реальное скрытие/показ слоёв) уже отработало по-настоящему; напрямую вызывается только финальное
уведомление.

## 5. Реальные дефекты

Не найдено ни одного дефекта поведения, требующего строки в `docs/defects.md` — реализация
прошла собственные 7 тестов и полный пакет (676 тестов) без нового бага в новом или
существующем коде. `xcrun swift-format lint --strict` изначально нашёл шесть форматных
нарушений (trailing comma, длина строки, отсутствующий перенос) в новом коде
`NodeHostBridge.swift` — исправлено `swift-format format --in-place` до коммита; это
стилистическая, не поведенческая находка, поэтому не заведена как отдельный дефект (тот же
порог, которым руководствовались прежние карточки — регистр фиксирует расхождения поведения, не
форматирование).

## 6. Платформы — что реально проверено

| Платформа | Команда | Результат |
|---|---|---|
| macOS | `swift build`, `swift test` (676 тестов) | PASS |
| macOS | `xcrun swift-format lint --strict` | PASS (после исправления) |
| macOS | `python3 Scripts/check_policy.py` | PASS |
| macOS (build+test+consumer, `-Xswiftc -warnings-as-errors`) | `check_all.py --matrix` | PASS |
| macOS universal (arm64+x86_64, `xcodebuild build`) | `check_all.py --matrix` | PASS |
| iOS device (generic/platform=iOS, build-only, нет подключённого устройства) | `check_all.py --matrix` | PASS |
| tvOS device (generic/platform=tvOS, build-only) | `check_all.py --matrix` | PASS |
| iOS Simulator (iPhone 17 Pro, реальный `xcodebuild test`, весь пакет) | `check_all.py --matrix` | PASS, с первого прогона (без флейка) |
| tvOS Simulator (Apple TV 4K (3rd generation), реальный `xcodebuild test`) | `check_all.py --matrix` | PASS |
| API baseline (`check_api.py --tvos`) | 1046/219/35/39 символов (TrellisCore/TrellisRender/TrellisAppKit/TrellisUIKit) | PASS, обновлён [ADR 0017](../adr/0017-node-host-bridge-gains-transition-session.md) |
| Screenshot-эталоны (56 сцен) | `check_all.py --matrix` | PASS, без изменений |
| `TRELLIS_LOG` в реальном процессе | `check_all.py --matrix` | PASS |
| Физическое устройство | — | не проверено (нет доступа к устройству в этой среде) |

`check_all.py --matrix`'s полный лог — вне репозитория, не входит в коммит (как и в
предыдущих карточках).

## Область изменений

- `Sources/TrellisCore/Transition/Role.swift` — новый файл.
- `Sources/TrellisRender/Transition/TransitionSession.swift` — новый файл
  (`TransitionSession`, `TransitionRoleEndpoints`, `TransitionSessionState`,
  `TransitionSettleTarget`, `TransitionEndpointSide`, `TransitionRasterKey`).
- `Sources/TrellisRender/Transition/TransitionAnimator.swift` — новый файл.
- `Sources/TrellisRender/LayerRenderer.swift` — `transitionRasterLayers`,
  `beginTransitionOverlay`/`materializeTransitionRasterLayer`/`endTransitionOverlay`,
  `unmount()` releases the transition overlay too.
- `Sources/TrellisRender/NodeHostBridge.swift` — `transitionSession`, `TransitionRoleMapping`,
  `TransitionRequest`, `presentTransition(_:)`, `closeTransition()`, `sceneReadiness`'s second
  readiness source, hooks in `suspend()`/`updateReduceMotion(_:)`/`detachCurrentRoot()`/
  `onPostCommit`/`onDisplayOnly`, test hooks (`forceCompleteTransitionMotionForTesting`,
  `hasTransitionOverlayForTesting`, `transitionRasterLayerCountForTesting`).
- `Tests/TrellisRenderTests/M11TransitionSessionTests.swift` — новый файл, 7 тестов.
- `docs/adr/0017-node-host-bridge-gains-transition-session.md` — новый ADR.
- `docs/decisions.md`, `docs/implementation-plan-5.md` — обновлены (M11 implementation note,
  чек-боксы M11).
- `api/TrellisCore.json`, `api/TrellisRender.json` — baseline обновлён (ADR 0017).

Не тронуто: `Sources/TrellisUIKit`, `Sources/TrellisAppKit` (M13's работа — platform adapters
для transition), `Sources/TrellisRender/LayerAnimator.swift` (D61's per-property путь не
изменён, только используется рядом), `FocusEngine.swift` (D73 переиспользует `setScope`
буквально, без правок).
