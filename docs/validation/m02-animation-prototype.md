# M02 — Маленький нативный прототип до инфраструктуры

Дата: 2026-09-12. Карточка [implementation-plan-5.md](../implementation-plan-5.md)
§5, зависит от M01 ([m01-animation-contract.md](m01-animation-contract.md)) и T02
для растровой части. Код здесь, как и в T02
([t02-raster-prototype.md](t02-raster-prototype.md)), — исследовательский прототип:
`Node`/`RenderCoordinator`/`LayerRenderer` не меняются этой карточкой (M03+). Проверяется
только платформенный механизм — explicit `CABasicAnimation`, retarget от `presentation()`
(D66), completion cleanup по token (D66/D67), и D65 two-layer раскладка под анимацией —
без `TrellisCore`/`TrellisRender`.

## 1. Что подтверждено, что найдено

`Tests/TrellisRenderTests/AnimationPrototypeTests.swift` — 10 тестов, только
`QuartzCore`/`Foundation` + `AppKit`/`UIKit` для реального окна (без
`TrellisCore`/`TrellisRender`), зелёные на всех трёх платформах:

| Платформа | Команда | Результат |
|---|---|---|
| macOS | `swift test` | 10/10, весь пакет 609/609 (было 599 после T12) |
| iOS 26.5 Simulator (iPhone 17 Pro) | `xcodebuild test -scheme Trellis-Package -destination "platform=iOS Simulator,id=…"` | 10/10 |
| tvOS 26.5 Simulator (Apple TV 4K) | тот же с `id=88D32E1E-…` | 10/10 |

`RasterProbe` (T02) сменил доступ с `private` на internal-в-таргете — переиспользуется
здесь для §3, а не скопирован заново.

### 1.1. Два слоя, explicit position/bounds/opacity/color, retarget посреди движения

`AnimationHarness.animate(_:keyPath:to:duration:)` — один explicit `CABasicAnimation` на
`(layer, keyPath)`, actions выключены на модельном присвоении (D61), адресная
замена/удаление по ключу (D66 п.3).

- `m02_explicitAnimationRetargetsFromPresentationNotFromOriginalModelValue` — реальное
  окно (`WindowHost`, см. §2), анимация к 100 запущена, run loop прокачан на 250ms,
  `presentation()` прочитан (доказано: не nil, между 0 и 100), затем retarget к 50 —
  новый `CABasicAnimation.fromValue` совпадает с прочитанным presentation-значением (±5pt),
  не с 0 и не со 100. Ровно то, что требует D66 п.1 и сценарий «повторное нажатие
  посреди движения» (§1 implementation-plan-5.md).
- `m02_twoIndependentPropertiesDoNotInterruptEachOther` — анимация `position.x`, затем
  независимо `opacity` на том же слое — первая анимация не тронута
  (`===` тот же объект), обе присутствуют одновременно (D66: «изменение другого свойства
  тоже его не отменяет»).

### 1.2. Completion cleanup по token без unsafe concurrency; detached layer; same-target; snap

- `m02_completionBlockCompilesUnderStrictConcurrencyWithoutUnsafeConcurrencyEscapes` —
  компилятная проверка: `CATransaction.setCompletionBlock { @MainActor [weak self] in
  self?.completeIfCurrent(...) }` компилируется под `SWIFT_STRICT_CONCURRENCY=complete`
  (`check_all.py`/`verify_bootstrap.py`) без `@unchecked Sendable`,
  `nonisolated(unsafe)` или `@preconcurrency` (запрет AGENTS). Открытый вопрос
  D66/D67 «способ безопасного хопа из CA callback на MainActor» — **решён**: обычный
  `@MainActor`-замыкание, переданное в API без Sendable-требования к своему типу
  (`(() -> Void)?`, простой `Any`-совместимый closure type, не `@Sendable`), компилируется
  без обхода.
- `m02_completionLogicIgnoresAStaleTokenAndAcceptsTheCurrentOne` — прямой вызов
  `completeIfCurrent(keyPath:token:)` (internal, не private — см. её doc-comment)
  симулирует последовательность: token 0 зарегистрирован → заменён token 1 (D66 п.3) →
  колбэк token 0 приходит и **игнорируется** (не трогает активный token 1) → колбэк
  token 1 приходит и **принимается**, запись очищена. Почему через прямой вызов, а не
  через настоящий CA callback — см. §1.4 ниже, найденный по пути пробел.
- `m02_detachedLayerHasNoPresentationSoRetargetFallsBackToModelValue` — слой без
  superlayer/окна: `presentation() == nil` подтверждено; `animate` берёт `fromValue`
  из прежнего **модельного** значения (7), не из 0 и не из target (D66 п.1, вторая
  ветка).
- `m02_sameTargetRepeatDoesNotRestartTheActiveAnimation` — повторный вызов с тем же
  target возвращает тот же token и **тот же объект** `CABasicAnimation` (`===`), не новый
  с обнулённым elapsed time — D64.
- `m02_noneIsAnImmediateSnapWithNoAnimationObjectAtAll` — `duration: 0` (`.none`, D61) —
  `animation(forKey:)` остаётся `nil`, `token == nil`, модельное значение применено
  синхронно.

### 1.3. Совместно с T02 — карточка с raster sublayer: move/resize/смена текста под анимацией

`AnimatedCardHarness` расширяет T02's `RasterHarness`-форму (внешний `outer` + внутренний
`inner` raster sublayer) явной анимацией внешнего слоя — T02 проверил этот контракт
только мгновенно (actions disabled), не во время реального движения; это и оставалось
явно отложенным на M02 (t02-raster-prototype.md §2).

- `m02_animatedMoveDoesNotRerasterAndInnerLayerHasNoAnimationOfItsOwn` — `outer.position`
  анимируется explicit-анимацией; `rasterCallCount == 1` (move не порождает raster job,
  как и в T02's мгновенном тесте); `inner` не получает **своей** анимации `position.x` —
  растровый слой следует за родителем через обычную иерархию слоёв, не через
  дублирующую анимацию (D65: «внутренний слой обновляется без actions»).
- `m02_animatedResizeKeepsOldBitmapUntilReplacementWhileBoundsAnimateInStep` — `outer` и
  `inner` получают **зеркальную** explicit-анимацию `bounds.size.width` (тот же
  duration/target на обоих) — старый bitmap остаётся как есть, пока не готов новый (то
  же поведение, что в T02's мгновенном тесте, но здесь bounds оба слоя реально в полёте,
  не применены мгновенно).
- `m02_textChangeDuringAnAnimatedMoveStillDropsStaleContentsFirst` — смена текста во время
  анимированного move: устаревший bitmap убирается немедленно (D65 «temporary emptiness
  acceptable, stale text is not»), несвязанное движение `outer` не потревожено.

### 1.4. Найдено: CA completion (transaction block и delegate) не доставляется в XCTest-хостированном процессе

Исходно `m02_completionCleansUpByTokenAndIgnoresAStaleCallbackFromAReplacedAnimation`
проверяла настоящую доставку колбэка: запустить анимацию, дождаться retarget'а,
прокачать run loop, проверить `completedTokens`. Тест **стабильно** (не флакующе)
проваливался — `completedTokens` оставался пустым.

Изолировано пятью пробами (создавались, проверялись, удалены — не входят в коммит,
результат воспроизводим по этому описанию):

1. Голый top-level `swift script.swift` (тот же код, что и в тесте) — колбэк
   доставляется надёжно, при повторном прогоне тоже.
2. Тот же код внутри `@Test @MainActor func` через `swift test` — колбэк **не**
   доставляется, ни разу, при нескольких прогонах.
3. Тот же код через `xcodebuild test -destination "platform=macOS"` (полноценный
   XCTest-бандл, не голый `swift test`) — колбэк **тоже не** доставляется. Значит дело
   не в `swift test` конкретно, а в XCTest-хостинге как таковом (оба раннера используют
   XCTest бандл под капотом).
4. Упрощение до одной **незаменяемой** анимации (без retarget вообще) — тот же результат:
   колбэк не доставляется даже для простейшего случая внутри XCTest.
5. Замена `CATransaction.setCompletionBlock` на `CAAnimationDelegate.animationDidStop` —
   тот же результат: не доставляется внутри XCTest-хостированного процесса.

При этом `presentation()`'s посреди-полёта значение (§1.1, тест 1) **читается корректно**
в том же `swift test` процессе — то есть внутренний «часы» анимации (что видно через
чтение presentation) продолжают работать, а вот доставка completion-колбэка — нет.
Причина не установлена (вероятно, colbэк требует полного round-trip до render server,
которого XCTest-хостинг не обеспечивает тем же образом, что обычный процесс с реальной
Aqua-сессией — предположение, не подтверждено экспериментом дальше этого).

**Решение (сужение контракта):** доставка completion-колбэка (в отличие от самого
retarget/token-механизма, который проверен напрямую, §1.2) не может быть верифицирована
автоматическим тестом в этой среде — ни `swift test`, ни `xcodebuild test`. M02
верифицирует **логику** cleanup'а (`completeIfCurrent`) прямым вызовом, как если бы
колбэк действительно пришёл — сам факт, что колбэк рано или поздно придёт в реальном
приложении (Playground, не XCTest), remains evidence for M06+/Simulator-скриншотов
поведения, не для этого набора тестов. Это открытый пункт, который **не блокирует**
M02 (её приёмка — «механизм проверен» и «SDK-вопросы решены или контракт сужен» —
контракт сужен явно, здесь).

## 2. `WindowHost` — реальное окно, не просто `CALayer().addSublayer`

Второй пробел, найденный при первой версии тестов: слой без superlayer (`CALayer()` без
монтирования) **иногда** не сохранял добавленную explicit-анимацию —
`animation(forKey:)` возвращал `nil` сразу после `add(_:forKey:)` на **первом** таком
вызове в холодном процессе, но не на последующих. Изолировано: это не per-keypath и не
per-layer эффект, а one-time **глобальный** прогрев процесса — как только **любой**
смонтированный (имеющий superlayer, в реальном окне) слой где-либо успешно
зарегистрировал explicit-анимацию, все последующие `add(_:forKey:)` (в том числе на
несмонтированных слоях) начинают надёжно сохраняться. До этого прогрева результат
зависит от того, какой тест выполнится первым — то есть флаки без видимой причины при
параллельном запуске тестов.

Поскольку в существующем коде Trellis ни один путь ещё не вызывает
`CALayer.add(_:forKey:)` (implicit actions всегда выключены, explicit-анимаций до этой
карточки не было нигде), этот прогрев никогда не происходил раньше в тестовом процессе
случайно — только сами тесты этой карточки его и создают, порядок выполнения не
гарантирован (`swift-testing` параллелит тесты).

**Решение:** каждый тест этого файла монтирует свой слой под `WindowHost.containerLayer`
(реальное окно, `NSWindow`/`UIWindow`, `makeKeyAndOrderFront`/`makeKeyAndVisible`) — то
же самое реальное окно попутно даёт рабочий `presentation()` (§1.1), а не просто
устраняет прогрев-флаки. Единственное исключение — тест, который **намеренно**
проверяет detached-слой (`m02_detachedLayerHasNoPresentationSoRetargetFallsBackToModelValue`);
он не утверждает, что `add(_:forKey:)` на нём надёжен (это отдельный, не тестируемый
здесь риск), только что при отсутствии presentation используется модельное значение.

Для production-кода Trellis (M03+) это не риск: `NodeHostBridge`/`LayerRenderer`
создают/монтируют слои только для реально подключённых (`attach`) деревьев, всегда под
хостовым layer'ом уже в реальном окне — первый `add(_:forKey:)`, который карточки
M03+ добавят, будет на уже смонтированном слое.

## 3. 1000 слоёв — timing и память, сравнение со сценой без анимации

Временный standalone-скрипт (`swift -O script.swift`, реальное `NSWindow`; создан,
измерен, удалён — не входит в коммит, результат воспроизводим по этому описанию) и
временный тест под `#if canImport(UIKit)` (тот же код, `xcodebuild test` на iPhone 17
Pro Simulator; тоже удалён после измерения):

| Платформа | Сценарий | Время (1000 слоёв) | Резидентная память, дельта |
|---|---|---|---|
| macOS | 1000 слоёв, мгновенный `position` (без анимации) | ~0.6 ms | ~0.7–0.75 MB |
| macOS | 1000 слоёв, explicit `CABasicAnimation` на каждом | ~2.6–2.8 ms | ~0.6–0.77 MB (не больше baseline в пределах шума) |
| macOS | маржинальная стоимость анимации сверх baseline | **~2.0 ms** (~2 μs/слой) | не выявлено измеримого стабильного прироста |
| iOS 26.5 Simulator (iPhone 17 Pro) | 1000 слоёв, без анимации | ~0.76 ms | ~0.38 MB |
| iOS 26.5 Simulator | 1000 слоёв, с анимацией | ~2.83 ms | ~0.72 MB |
| iOS 26.5 Simulator | маржинальная стоимость | **~2.07 ms** | те же оговорки, что и T02 §3.1 (RSS — не точный byte-в-byte учёт) |

Числа согласуются между macOS и iOS Simulator (~2ms/1000 слоёв, то есть ~2
микросекунды CA-бухгалтерии на explicit-анимацию сверх обычного мгновенного
присвоения) — не финальный бюджет M08 (та же оговорка, что T02 §3.1 давала для
растра: «входные данные для следующей карточки, не её результат»), но подтверждает
качественное ожидание §2 implementation-plan-5.md: «нулевое создание CAAnimation для
обычной сцены» — здесь сцена **с** анимацией стоит на ~2μs/узел больше, не на порядки,
и не показывает устойчивого лишнего резидентного роста при 1000 узлов. M08 сравнит
median/p95 на реальном pipeline (`NodeHostBridge`/`LayerRenderer`), не на голых
`CALayer`, и это единственное окончательное число.

## Приёмка M02

- Два слоя, explicit position/bounds/opacity/color, retarget посреди движения —
  done, §1.1.
- Completion cleanup с token, без unsafe concurrency обходов; detached layer без
  presentation, same-target, snap, два независимых свойства — done, §1.2 (доставка
  самого CA-колбэка — сужена до логики, не до end-to-end, §1.4).
- Вместе с T02 — карточка с raster sublayer: move, resize, смена текста — done, §1.3.
- macOS и iOS Simulator evidence, timing и память для 1000 слоёв; сравнение со сценой
  без анимации, бюджет для M08 — done, §3 (входные числа, не финальный бюджет).

Механизм проверен до изменения pending/coordinator (ничего в `TrellisCore`/
`TrellisRender` не тронуто); открытые SDK-вопросы решены (§1.2's completion
compile-safety) либо контракт явно сужен (§1.4's completion delivery in-XCTest, §2's
mount-before-first-add). Следующая карточка — M03 (scope intent в pending и commit).
