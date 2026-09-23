# M09 — Следующий самостоятельный шаг: настоящая пружина

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §5 —
необязательное продолжение после закрытия результата A (M01–M08,
[m08-close-result-a.md](m08-close-result-a.md)), не входит в его приёмку.

## 1. Модель — `TrellisCore/Animation.swift`

`AnimationCurve` получает пятый случай:

```swift
case spring(response: Double, dampingFraction: Double)
```

`response` — воспринимаемая длительность в секундах (период недемпфированной пружины до
первого достижения цели); `dampingFraction` — `0` (искл.) `...1` (`1` — критическое
демпфирование, без перелёта; меньше — более «прыгучая»). Тот же двух-параметрический вид, что
SwiftUI's собственный `.spring(response:dampingFraction:)` — намеренно, а не изобретение новой
параметризации: «удобный preset» из приёмки карточки означает узнаваемую запись, не только
короткую.

```swift
public static func spring(response: Double = 0.35, dampingFraction: Double = 0.86) -> Animation
public static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.86)
```

Оба параметра нормализуются в `spring(...)`, той же дисциплиной, что уже применяют
`TextStyle.pointSize`/`Animation.init(duration:curve:)`: `response` — минимум `0.05`
(неположительный не имеет физического смысла и делит на ноль при переводе в
stiffness/damping); `dampingFraction` — `0.05...1` (`0` никогда не устанавливается — вечные
колебания без демпфирования — отклоняется тем же способом, что `duration <= 0` уже нормализуется
в `.none` в этом типе). `duration`, которую видит эта модель для `.spring`, — не то число, что
реально управляет `CASpringAnimation` (см. §2): это оценка (`response` в секундах), нужная
только чтобы `> .zero`-проверка каждого reconciliation-пути не приняла пружину за `.none`.

`Animation.snappy` подобран на сцене S27 (M08): лёгкий, контролируемый bounce
(`dampingFraction` близко к, но меньше `1`), ощущается отзывчиво без заметного перелёта на
свойствах, которые типично анимирует press/disclosure (bounds/position карточки, opacity фейда).

## 2. Renderer — одна общая фабрика вместо четырёх копий

`LayerAnimator` до этой карточки создавал `CABasicAnimation` в четырёх местах
(`reconcileValue` — opacity/cornerRadius; `reconcileAxisPair` — position/bounds, по одной
анимации на ось; `reconcileBackgroundColor`; `reconcileTransform`), каждое — с одинаковыми
тремя строками `duration`/`timingFunction`. Вместо patch'а всех четырёх под spring отдельно —
новая единственная точка:

```swift
private func makeAnimation(keyPath: String, timing: Animation) -> CABasicAnimation {
    switch timing.curve {
    case .linear, .easeIn, .easeOut, .easeInOut:
        // существующий путь: CABasicAnimation + duration + timingFunction
    case let .spring(response, dampingFraction):
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2) * spring.mass
        spring.damping = 4 * .pi * dampingFraction * spring.mass / response
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        return spring
    }
}
```

`response`/`dampingFraction` → `mass`/`stiffness`/`damping` — стандартный перевод (тот же,
на котором построен SwiftUI's собственный двух-параметрический API), `mass` зафиксирована в
`1`. `duration` **не вычисляется формулой в этом пакете** — читается обратно из только что
построенной `CASpringAnimation`'s собственного `settlingDuration`, вычисленного SDK
(«settling... проверяются на SDK», приёмка карточки). `CASpringAnimation` — подкласс
`CABasicAnimation`, так что все четыре вызывающих места продолжают работать с возвращаемым
значением как раньше (`fromValue`/`toValue`/`layer.add(_:forKey:)`) без отдельной ветки —
diff карточки на 4 сайта: замена трёх строк на один вызов `makeAnimation(keyPath:timing:)`.

**Ничего не потребовало отдельного spring-кода:**

- **Retarget (D66)** — тот же presentation-read/`before`-fallback путь, что уже был; для
  пружины исходное значение перед retarget'ом читается из `layer.presentation()` точно так же,
  как для eased-кривых (§4, тест).
- **Reduce Motion (D67)** — `LayerRenderer.resolvedIntent` резолвит в `nil` до того, как
  `reconcile` вообще видит `intent.animation.curve`; `nil`-intent снапает независимо от того,
  какой curve *был бы* у него.
- **Token cleanup (D64)** — адресация `(mountEpoch, NodeID, property)` не знает о curve вообще;
  `completeIfCurrent` для пружины работает тем же кодом, что и для eased.

## 3. Физически ограниченные свойства (opacity/cornerRadius) — проверено, не подавлено

Недодемпфированная пружина (`dampingFraction < 1`) по своей физике перелетает цель до
остановки. Для `opacity`/`cornerRadius` — единственных двух свойств D61's таблицы с
содержательным диапазоном (`0...1` и `>= 0` соответственно) — перелёт может дать видимое,
но кратковременное значение вне диапазона (полу-прозрачность выше исходной, отрицательный
радиус, который `CALayer` тихо трактует как `0`). Это — принятая характеристика выбранной
физики, не дефект: карточка не глушит/не клэмпит промежуточные значения (потребовало бы
`CAKeyframeAnimation` с явно посчитанными сэмплами вместо настоящей пружины — другая
архитектура, не входит в объём этой карточки) и не подменяет её другой кривой. `Animation.snappy`
(`dampingFraction: 0.86`) выбран достаточно демпфированным, чтобы перелёт на этих двух свойствах
был почти незаметен на глаз — но кастомная `.spring(response:dampingFraction:)` с низким
demping (проверено `dampingFraction: 0.4`, тест §4) технически может дать заметный перелёт;
задокументировано, автор может выбрать более демпфированные параметры для чувствительных к
диапазону свойств.

## 4. Тесты

`Tests/TrellisCoreTests/AnimationIntentTests.swift` (+2): `Animation.spring`/`.snappy`
нормализуют параметры (клэмп `response`/`dampingFraction`, никогда не схлопываются в `.none`).

`Tests/TrellisRenderTests/M09SpringAnimationTests.swift` (5 новых тестов, реальное окно —
M02 §2's warm-up):

- `m09_springIntentCreatesARealCASpringAnimationNotAnEasedStandIn` — построенная
  `CASpringAnimation` проверена против формулы напрямую (`mass`/`stiffness`/`damping`), не
  просто «какое-то положительное число»; `duration == settlingDuration`, читается из SDK.
- `m09_springRetargetsMidFlightFromThePresentationValueNotTheOriginalModel` — D66 для пружины:
  реальное окно, реальное время (`host.pump(for: 0.25)`), новая цель стартует от живого
  presentation-значения, не от исходной модели.
- `m09_reduceMotionSnapsASpringIntentTheSameWayItSnapsAnyOtherCurve` — `nil`-intent снапает
  активную пружину так же, как eased-переход.
- `m09_physicallyBoundedPropertiesBuildTheSameSpringPhysicsAsUnboundedOnes` — opacity/
  cornerRadius под намеренно «прыгучей» (`dampingFraction: 0.4`) пружиной строятся с той же
  формулой, что и любое другое свойство — §3's задокументированный компромисс, не другой код.
- `m09_completionTokenCleanupWorksForASpringExactlyLikeAnEasedAnimation` — адресный cleanup
  (D64) работает для пружины тем же вызовом `completeIfCurrent`, что и для eased.

```text
TRELLIS_LOG=off swift test --filter m09
7 tests passed (5 в TrellisRenderTests + 2 в TrellisCoreTests)
```

```text
TRELLIS_LOG=off swift test
665 tests passed (было 658 после M08), без флейков
```

## 5. Bench — стоимость

Новый параметр `timing:`/`nameSuffix:` у `fixtureAnimatedTextList` (M08's fixture) —
`animated-text-list-1000-spring` повторяет тот же сценарий (1000 карточек, список анимируется
целиком) под `.snappy` вместо `.smooth`:

| Fixture | `animated-commit-full-list` p50 | `scene-ready-after-last-animation` |
|---|---|---|
| `animated-text-list-1000` (`.smooth`) | 161.6 мс | 1 |
| `animated-text-list-1000-spring` (`.snappy`) | 162.9 мс | 1 |

Разница (~1.3 мс на 1000 узлов) — в пределах шума измерения, не систематическая; построение
`CASpringAnimation` и чтение `settlingDuration` не дороже `CABasicAnimation` + `CAMediaTimingFunction`
на этом масштабе. `scene-ready-after-last-animation = 1` для обеих — то же прямое доказательство
реальной доставки CA completion callback вне XCTest, что M08 впервые получила для `.smooth`,
теперь подтверждено и для пружины.

Полный отчёт: [measurements/2026-09-13-m09-spring-animation-release.md](measurements/2026-09-13-m09-spring-animation-release.md).

## 6. API consumer

`Scripts/verify_bootstrap.py`'s Smoke-таргет (реальный внешний consumer, без `@testable`)
проверяет `Animation.snappy.curve`/`Animation.spring(response:dampingFraction:)`'s клэмп —
`TrellisRender`'s перевод в `CASpringAnimation` намеренно не виден потребителю модели: только
нормализованный публичный результат.

## 7. Сцена S27 — дальнейшее использование

`DisclosureCardNode.toggle()` (M08) переключён с `.smooth` на `.snappy` — тот самый press/
disclosure сценарий, под который подбирался пресет. Скриншоты (macOS reference,
`check_screenshots.py`) не изменились ни на бит: `CALayer.render(in:)` рисует model-значения
независимо от того, какая кривая их туда доставила (то же наблюдение, что уже сделано в M08 —
смена кривой невидима статическому кадру), так что смена `.smooth` → `.snappy` не потребовала
обновления baseline.

## 8. Платформенная матрица

```text
python3 Scripts/check_all.py --matrix
```

policy/test_policy/test_verifier, `verify_bootstrap.py --matrix` (macOS arm64/x86_64 +
iOS/tvOS device build-only + **реальный** `xcodebuild test` на iPhone 17 Pro Simulator и
Apple TV 4K Simulator), `check_api.py --tvos`, `check_screenshots.py` (56 сцен, без изменений),
`check_log_env.py` — все PASS.

## 9. API baseline

Аддитивно: `TrellisCore.AnimationCurve.spring(response:dampingFraction:)` (новый case),
`Animation.spring(response:dampingFraction:)`, `Animation.snappy`. `check_api.py --tvos --update
--review-note docs/validation/m09-spring-animation.md` — `TrellisCore` baseline обновлён;
`TrellisRender`/`TrellisAppKit`/`TrellisUIKit` без изменений (карточка не меняет их публичный
API — `CASpringAnimation`-перевод целиком internal в `LayerAnimator`).

## Приёмка M09

- `.spring` + один удобный preset для press/disclosure, параметры подобраны на S27 — done, §1/§7.
- Настоящая `CASpringAnimation` без подмены ease; settling читается из SDK; retarget проверен на
  реальном окне и реальном времени — done, §2/§4. Сохранение скорости (velocity matching через
  retarget) — не реализовано, как и заявляла карточка («отдельное явное решение»);
  `initialVelocity` всегда `0` при retarget.
- Физически ограниченные свойства, Reduce Motion, token cleanup, стоимость, API consumer,
  платформенная матрица — все проверены, все done, §3–§8.

Дефект #41 закрыт. Нет новых дефектов, найденных этой карточкой.

Следующий шаг по плану — Результат B (M10–M14, implementation-plan-5.md §6): составной переход
«карточка → страница → обратно», обязательная часть N07, не начат.
