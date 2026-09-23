# M04 — маленький explicit animator внутри renderer

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §5;
зависимость M03 ([m03-animation-intents.md](m03-animation-intents.md)) закрыта. Эта
карточка создаёт первый настоящий `CABasicAnimation` в production-коде Trellis —
всё до неё (M01–M03) было контрактом, прототипом или только доставкой intent.

## 1. Реализация

`LayerAnimator` (`Sources/TrellisRender/LayerAnimator.swift`) — internal-класс,
владение и время жизни у `LayerRenderer` (одна инстанция на renderer, не на ноду).
Публичного API не добавляет — `LayerRenderer`'s собственный публичный API (`applyCommitted`/
`applyAppearance` с `AnimationCommitEnvelope`, package-уровня) уже существовал после
предыдущей сессии M03; `check_api.py`/`check_api.py --tvos` подтверждают отсутствие
изменений символов во всех четырёх модулях.

- **Таблица D61**: `position`, `bounds`, `opacity`, `transform`, `backgroundColor`,
  `cornerRadius` — ровно шесть кейсов `LayerAnimator.Property`. `captureBeforeState(layer:)`
  читает все шесть с layer до записи geometry/presentation этим коммитом;
  `reconcile(nodeID:layer:before:mountEpoch:intent:host:generation:)` перечитывает те же
  поля после записи и диффит.
- **Адресные ключи (D64)**: `(mountEpoch, NodeID, Property)` — `ActiveKey`, приватный
  словарь `active`. Токен — монотонный `UInt64` у самого `LayerAnimator`, не у ноды и не
  у CA. `completeIfCurrent(nodeID:mountEpoch:property:token:)` — адаптер завершения:
  игнорирует чужой (более старый) токен вместо снятия текущего (D66 п.3).
- **Retarget/snap (D66)**: изменившееся свойство без intent или с `.none`
  снимается — модельное значение уже записано (actions disabled в `LayerRenderer`), явная
  анимация по этому ключу удаляется адресно (`removeAnimation(forKey:)`, никогда
  `removeAllAnimations`). С positive-duration intent — `fromValue` берётся из
  `presentation()`, если по этому ключу уже идёт анимация, иначе из `before` (прежней
  модели); `toValue` — уже записанное новое значение. D64's "тот же target не
  перезапускает" реализован не отдельной веткой, а тем, что `before == after` для
  повторной записи того же значения — diff не находит изменения, активная запись не
  трогается вовсе (тот же CA-объект, тот же токен).
- **Смешение (D63)**: непересекающееся свойство другого intent'а не читается этим
  вызовом `reconcile` вообще — каждый вызов видит только *свой* changed/unchanged на
  *своём* ключе, так что «не отменяет чужую анимацию» — не специальный случай, а
  структурное следствие адресности по property.
- **`position`/`bounds` — не единый `NSValue`-boxed keyPath**: см. дефект #49 в
  [defects.md](../defects.md) — `NSValue(cgPoint:)`/`NSValue(cgRect:)` не существуют на
  macOS (только `NSValue(point:)`/`NSValue(rect:)`, AppKit-геометрия), а
  `NSValue(point:)`/`NSValue(rect:)` не существуют на iOS/tvOS (только `cgPoint:`/
  `cgRect:`). Ни один вариант не переносим без `#if canImport(AppKit\|UIKit)`, запрещённого
  политикой вне адаптеров. Решение — `position`/`bounds` анимируются как пары независимых
  `CGFloat` sub-keyPath'ов (`position.x`/`position.y`, `bounds.size.width`/
  `bounds.size.height`), которые бриджируются в `NSNumber` одинаково везде; оба члена пары
  создаются/ретаргетятся/снимаются атомарно под одним `ActiveKey`/токеном — колбэк
  завершения для `.position` означает «обе оси устоялись», не «одна из двух».
- **`transform` (D61 rotation limit)**: поворот детектируется через декомпозицию matrix
  (`atan2(b, a)` — та же формула, которой `cgAffineTransform(_:)` в `LayerRenderer`
  кодирует `LayoutTransform.rotationRadians` обратно в `CGAffineTransform`). Если поворот
  до/после отличается — свойство снимается независимо от intent (документированное
  ограничение первой версии); если поворот совпадает (включая общий случай 0/0) —
  анимируется как единый `CATransform3D` через `NSValue(caTransform3D:)`, который
  портируем на всех платформах без AppKit/UIKit.
- **`backgroundColor` (D61 normalization)**: `nil` с одной стороны нормализуется в цвет
  другой стороны с нулевой альфой (`CGColor.copy(alpha: 0)`), а не в `nil` — CA не
  принимает `nil` на одном конце явной анимации цвета осмысленно. Модельное значение
  (что реально останется на layer) — то, что уже записал `LayerRenderer`
  (`applyVisualStyle`), не синтетический цвет.
- **`LayerRenderer` wiring** (уже было в незакоммитированном состоянии сессии до этой
  карточки — см. `git log`; эта карточка добавила только `LayerAnimator.swift`, файл,
  которого не хватало для сборки): `update(node:...)` вызывает `captureBeforeState`
  до записи geometry/presentation при `!snapsThisCommit`, `reconcile` после; новый/
  reparented layer идёт через `animator.snapAll` (D62 — ничего не ретаргетить, нет
  системы координат для retarget); `removeStaleLayers` вызывает `animator.forgetNode`;
  `unmount()` вызывает `animator.unmount()`. `applyAppearanceRecursively` (paint-only
  путь) делает то же самое дерево-широко.

## 2. Детерминированная приёмка

13 новых тестов, все зелёные macOS (`swift test`, warnings-as-errors):

- `LayerAnimatorTests.swift` (10 тестов) — прямые вызовы `LayerAnimator` на голом
  `CALayer`, смонтированном под реальным окном (M02's `WindowHost`-паттерн:
  `CALayer.add(_:forKey:)`/`presentation()` ненадёжны до прогрева на несмонтированном
  дереве, см. [m02-animation-prototype.md §2](m02-animation-prototype.md)):
  from/to/key/duration создания анимации; retarget посреди движения от presentation, не
  от старой/новой модели; same-target repeat не трогает активную запись; отсутствие
  intent — снимает без создания объекта; поздний `.none` снимает только своё свойство,
  не трогая чужое; `snapAll` снимает всё для нового/reparented layer; `forgetNode` чистит
  bookkeeping (последующий reconcile больше не считает свойство «активным»);
  `completeIfCurrent` игнорирует протухший токен, принимает текущий; поворот снимает
  transform, scale/translation — анимируют; отсутствующий цвет нормализуется в
  прозрачный, не в `nil`-конец.
- `AnimationCommitLayerTests.swift` (3 теста) — end-to-end через настоящие
  `Node.animate` → `RenderCoordinator` (M03) → `LayerRenderer` (M04), с
  `RenderCoordinator.onAnimationCommit`/`onCommitGeometry`/`onPaintOnly` подключёнными
  ровно как в `NodeHostBridge.attach`: `node.animate` реально создаёт `CABasicAnimation`
  на закоммиченном layer с ожидаемыми to/duration; обычная мутация вне scope снимает,
  даже пока другая нода анимирует (D63); только что смонтированный layer никогда не
  анимирует своё первое появление (D62).

```text
TRELLIS_LOG=off swift test --filter m04_
13 tests passed
```

Один тест (`m04_plainMutationOutsideAnyScopeSnapsEvenWhenAnotherNodeIsAnimating`)
изначально использовал `.smooth` (250ms) для проверяемой анимации, из-за чего при
занятом параллельном прогоне (полный `swift test`, 635 тестов) она успевала
завершиться и самоудалиться (`isRemovedOnCompletion`) до финального `#expect` — не
дефект `LayerAnimator`, а хрупкость самого теста (реальное время < реального времени
прогона). Исправлено удлинением проверяемой анимации до 30s — не влияет на то, что
тест проверяет (снятие несвязанной мутации), только устраняет гонку со временем
прогона.

## 3. Проверки

- `python3 Scripts/check_policy.py` — PASS, 0 diagnostics.
- `TRELLIS_LOG=off swift test --filter m04_` — PASS, 13/13; полный набор
  (`TRELLIS_LOG=off swift test`) — PASS, 635/635, трижды подряд без флейков.
- `python3 Scripts/check_api.py` / `--tvos` — PASS на всех четырёх модулях
  (macOS/iOS/tvOS), 0 изменённых символов — `LayerAnimator` internal, никакого нового
  публичного/package API в этой карточке. Дефект #49 (см. выше) найден именно этим
  шагом: `swift build`/`swift test` (macOS-only через SwiftPM) не собирают под iOS SDK,
  так что первая (сломанная под iOS) версия boxing'а прошла оба локально, но упала
  здесь.
- `TRELLIS_LOG=off python3 Scripts/check_all.py` — PASS: policy/verifier unit-тесты,
  strict format, `-warnings-as-errors` library build + package test + external consumer,
  API baselines (macOS/iOS/tvOS), 52 macOS screenshot scenarios, `TRELLIS_LOG` behavior;
  итог `PASS C03/C04/C05 quality gates`.

## Приёмка M04

- Diff и таблица свойств D61, адресные keys, установка model target — done, §1.
- Retarget D66, no-op commit сохраняет действующую анимацию — done, §1/§2
  (`m04_unchangedPropertyLeavesAnActiveAnimationCompletelyUntouched`,
  `m04_retargetMidFlightStartsFromThePresentationValueNotTheOldOrNewModel`).
- Отдельные presentation-reader и completion adapter для тестирования — done:
  `captureBeforeState`/чтение `layer.presentation()` внутри `reconcile*`, и
  `completeIfCurrent` как отдельный вызываемый напрямую метод (M02 §1.4: реальная
  доставка CA-колбэка не воспроизводится в XCTest-хостинге — тот же сужение контракта
  здесь, cleanup-логика проверена прямым вызовом).
- Новые/удалённые/reparented layers — snap; overlay без анимации — done:
  `snapAll`/`forgetNode`, `m04_snapAllRemovesEveryTrackedAnimationForANewOrReparentedLayer`,
  `m04_newlyMountedLayerNeverAnimatesItsFirstAppearance`. Overlay (`DebugOverlayRenderer`)
  не проходит через `LayerAnimator` вообще — не тронут этой карточкой.

Визуальная непрерывность на слое в реальном окне с прокачанным run loop проверена
(`m04_retargetMidFlightStartsFromThePresentationValueNotTheOldOrNewModel` читает
`presentation()` посреди движения, не только `animationKeys()`/`animation(forKey:)`).
Дефект #49 — единственный найденный этой карточкой, исправлен до коммита.

Следующая карточка — M05 (Reduce Motion и lifecycle).
