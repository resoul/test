# M05 — Reduce Motion и lifecycle

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §5,
D67; зависимость M04 ([m04-layer-animator.md](m04-layer-animator.md)) закрыта.

## 1. Реализация

- **`ReduceMotionKey`** (`Sources/TrellisCore/ReduceMotion.swift`) — обычный
  наследуемый environment-ключ, `defaultValue = false`, `EnvironmentValues.reduceMotion`,
  `Node.setReduceMotion(_:)` — тот же паттерн, что `LocaleKey`/`TextRendererKey` (T09):
  безусловный bump ревизии через существующий `setEnvironment(_:to:)`, никакой отдельной
  лёгкой инвалидации не заводилось — реальное немедленное действие (снятие активных
  переходов) выполняется отдельным явным вызовом, не через layout-инвалидацию.
- **Резолюция в `.none` при commit** (D67) — `LayerRenderer.resolvedIntent(for:animationRoot:
  intents:epoch:)` читает `node.environment.reduceMotion` (живой, наследуемый) и
  возвращает `nil` вместо результата `resolvedAnimationIntent`, когда `true`.
  `animator.reconcile` уже трактует `nil`-intent как snap — тот же код-путь, что настоящий
  `.none`, без отдельной ветки. `AnimationIntent`'s memberwise init — `internal`, не
  `package` (единственные stored-поля `package let`, но синтезированный init не наследует
  `package` — компилятор это подтвердил), так что построить новый intent с `.none` изнутри
  `TrellisRender` нельзя было бы в принципе — оказалось и не нужно.
- **`LayerAnimator.finishAllActive(mountEpoch:layerForNode:)`** — новый метод: снимает
  каждую активную явную анимацию текущего mount epoch немедленно, без нового коммита/solve.
  Не хранит `CALayer` сама — принимает closure `(NodeID) -> CALayer?`, чтобы
  `LayerRenderer.finishActiveAnimations(mountEpoch:)` мог передать чтение из собственного
  `registry`, не заводя новую связь между классами. Узел без материализованного layer
  просто пропускается (уже неактуален).
- **`NodeHostBridge`**:
  - `attach(...)` получил `reduceMotion: Bool? = nil` (T09-стиль — `nil` не меняет
    поведение существующих вызовов).
  - `updateReduceMotion(_ isEnabled: Bool)` — пишет значение в root; если включается
    **впервые** (было `false`, стало `true`) — сразу вызывает
    `renderer.finishActiveAnimations(mountEpoch:)`, обрывая всё, что летит, на месте
    (D67: «немедленно завершает... без нового solve»). Выключение влияет только на
    будущие вызовы `animate` — уже снятое не воскресает.
  - `suspend()` теперь тоже вызывает `renderer.finishActiveAnimations(mountEpoch:)` — D67:
    «активное движение заканчивается snap'ом к committed target» — раньше suspend останавливал
    только *intent*-bookkeeping (M03), но не реальные уже добавленные `CABasicAnimation`.
  - detach/replaceRoot (через повторный `attach`) уже полностью обнуляли `LayerAnimator`
    (`renderer.unmount()` → `animator.unmount()`) — регрессия отсутствует, но добавлен
    прямой тест на неё (§2).
- **Host-адаптеры** (T09-паттерн, `installLocaleObserver`/`updateBridgeState`):
  - **UIKit**: `currentReduceMotion` читает `UIAccessibility.isReduceMotionEnabled`;
    `installReduceMotionObserver()` подписывается на
    `UIAccessibility.reduceMotionStatusDidChangeNotification` на `NotificationCenter.default`
    (тот же центр, что locale) — существующий `deinit`'s `removeObserver` уже покрывает.
  - **AppKit**: `currentReduceMotion` читает
    `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; `installReduceMotionObserver()`
    подписывается на `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` — но этот
    нотификейшен идёт через **`NSWorkspace.shared.notificationCenter`**, не через
    `NotificationCenter.default` (в отличие от всех остальных нотификаций в этом файле).
    `deinit` расширен явным `NSWorkspace.shared.notificationCenter.removeObserver(self)`,
    иначе эта подписка протекала бы — стандартный `removeObserver(self)` на дефолтном
    центре её не видит.
  - Оба адаптера передают `reduceMotion:` в `bridge.attach(...)` и вызывают
    `bridge.updateReduceMotion(...)` из общего `updateBridgeState()`.

## 2. Детерминированная приёмка

22 новых теста, все зелёные:

- `Tests/TrellisCoreTests/ReduceMotionTests.swift` (3) — default/override/inheritance
  environment-плюмбинга, тот же уровень, что уже покрыт для `LocaleKey`/`LayoutDirectionKey`
  в `EnvironmentTests.swift`.
- `Tests/TrellisRenderTests/LayerAnimatorTests.swift` (+2) — `finishAllActive` напрямую:
  снимает все отслеживаемые анимации указанного mount epoch на нескольких узлах разом и
  чистит bookkeeping (последующий reconcile для того же ключа не считает его «активным»);
  игнорирует другой epoch и узел без layer.
- `Tests/TrellisRenderTests/ReduceMotionLifecycleTests.swift` (5) — через настоящий
  `NodeHostBridge` (не голый `RenderCoordinator`/`LayerRenderer`, поскольку
  `updateReduceMotion`/`suspend`'s D67-поведение принадлежит bridge), слой смонтирован под
  реальным окном (M02 §2's warm-up):
  - `reduceMotion: true` при `attach` → `animate` резолвится в snap, никакого
    `CABasicAnimation`.
  - Включение Reduce Motion **посреди** реального полёта → анимация снимается мгновенно,
    без нового коммита (проверено прямым чтением `layer.animation(forKey:)` сразу после
    вызова, не через ожидание коммита).
  - Выключение не воскрешает уже снятое; следующий `animate` после выключения снова
    анимирует по-настоящему.
  - `suspend()` посреди полёта снимает анимацию к её committed target.
  - `detach()` после активной анимации, затем **новый** `attach()` тем же bridge — новый
    mount анимирует на своих условиях, старая bookkeeping не просачивается (эпохи не
    совпадают).
- `Tests/TrellisRenderTests/AppKitReduceMotionTests.swift` (2) и
  `Tests/TrellisRenderTests/UIKitReduceMotionTests.swift` (2, компилируются в пусто на
  macOS — только Simulator) — T09-паттерн: `attach` ставит системное значение на root;
  ручная отправка системной нотификации (`NSWorkspace.accessibilityDisplayOptionsDidChange
  Notification` / `UIAccessibility.reduceMotionStatusDidChangeNotification`) обновляет его
  же на живом дереве — то же самое, что и `t09_localeChangeNotificationRemeasuresTheAttached
  Tree`, реальным системным значением тест управлять не может, только доставкой
  нотификации.

```text
TRELLIS_LOG=off swift test --filter m05_
22 tests passed (macOS; UIKit's own 2 compile to nothing there)
```

Оба host-адаптера прогнаны на Simulator отдельно (полный `TrellisRenderTests` таргет,
`-only-testing` по имени теста не матчится для swift-testing функций через xcodebuild —
пришлось фильтровать по всему таргету):

```text
xcodebuild test -scheme Trellis-Package -destination "platform=iOS Simulator,id=3D9E75A3-…" \
  -only-testing:TrellisRenderTests
→ 213 passed, 0 failed (includes both m05_ UIKit tests)

xcodebuild test -scheme Trellis-Package -destination "platform=tvOS Simulator,id=E4F3829E-…" \
  -only-testing:TrellisRenderTests
→ PASSED
```

## 3. API baseline

Новые публичные символы (`TrellisCore`: `ReduceMotionKey`, `EnvironmentValues.reduceMotion`,
`Node.setReduceMotion`; `TrellisRender`: `NodeHostBridge.updateReduceMotion`, `attach`'s
mangled name changed by the new trailing `reduceMotion: Bool? = nil` parameter — additive,
every existing call site keeps compiling unchanged, same shape as T09's own
`textRenderer`/`localeIdentifier` addition to `attach`). `check_api.py --tvos --update
--review-note docs/validation/m05-reduce-motion-lifecycle.md` — `TrellisCore`/`TrellisRender`
baselines updated; `TrellisAppKit`/`TrellisUIKit` unchanged (their own `attach` wrapper
signatures did not change, only what they pass through).

## 4. Проверки

- `python3 Scripts/check_policy.py` — PASS, 0 diagnostics.
- `TRELLIS_LOG=off swift test --filter m05_` — PASS.
- `TRELLIS_LOG=off swift test` — PASS, whole package, twice in a row, no flakes.
- `check_api.py --tvos --update --review-note` (this document) — updated, diff limited to
  the additive symbols listed above.
- `TRELLIS_LOG=off python3 Scripts/check_all.py` — PASS: policy/verifier unit tests, strict
  format, `-warnings-as-errors` library build + package test + external consumer, API
  baselines (macOS/iOS/tvOS), 52 macOS screenshot scenarios, `TRELLIS_LOG` behavior.

No new defects found while implementing this card.

## Приёмка M05

- Host environment + системные notifications, отмена подписок — done, §1 (`installReduceMotion
  Observer` on both adapters; AppKit's own `deinit` extended for `NSWorkspace`'s separate
  notification center — the one real platform gotcha found here, caught by reading Apple's own
  documented behavior before writing the code, not by a failing test).
- Suspend/resume, detach/reattach, replaceRoot, dispose, поздний CA callback — done, §2
  (`m05_suspendFinishesActiveAnimationsToTheirCommittedTarget`,
  `m05_detachDoesNotLeaveAStaleAnimationAffectingTheNextMount`); a late CA completion callback
  finding nothing to clear after `unmount()`/`forgetNode` was already covered generically by
  M04's `completeIfCurrent` design and its own tests — no new gap found specific to suspend/
  detach here.
- Включение Reduce Motion останавливает уже начатые переходы — done, §2
  (`m05_turningOnReduceMotionMidFlightFinishesActiveAnimationsImmediately`).

Next card — M06 (реальная карточка с текстом, D65 поверх T07).
