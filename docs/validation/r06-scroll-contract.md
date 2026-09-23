# R06 — Scroll-контракт и ранний native прототип: evidence (закрыта)

**R06 закрыта 2026-09-15.** Все 7 пунктов чек-листа
[implementation-plan-6.md](../implementation-plan-6.md)#R06 выполнены; итоговая
запись закрытия — в самом плане, сразу после чек-листа R06. Этот файл
накапливался по мере выполнения пунктов и остаётся как хронология находок
(включая опровергнутую по пути гипотезу §2 и дефекты #63–#65) — не переписан
в единый пересказ задним числом.

## Выполнено

### Разбор Weave scroll/collections (§3.1)

См. [weave-scroll-analysis.md](../weave-scroll-analysis.md) — полный разбор
`Scroll.swift`/`Collections.swift` и обоих адаптеров. Главный вывод: в Weave
нет ни одного `UIScrollView`/`NSScrollView` — вся прокрутка ручная (дефект #63).
Второй найденный дефект — `updateItems`'s anchor-restore игнорирует измеренные
длины (дефект #64). Оба зарегистрированы в [defects.md](../defects.md).

### Прототип: TrellisHostView как единственный content реального scroll view

`Tests/TrellisRenderTests/AppKitNativeScrollEmbeddingPrototypeTests.swift`,
`Tests/TrellisRenderTests/UIKitNativeScrollEmbeddingPrototypeTests.swift` — 4
теста (2 на платформу), без единой правки `Sources/`. Проверено:

- Неизменённый `TrellisHostView`, размером во всю (пока не виртуализированную)
  высоту контента, встраивается как единственный `documentView`
  (`NSScrollView`) / единственный `subview` (`UIScrollView`) — один render
  subtree, без второго host/renderer на строку (P6.3).
- `TextNode` рядом с началом контента и `ControlNode` рядом с концом —
  control изначально вне видимой области `documentVisibleRect`/`bounds`
  скролл-контейнера.
- После программной прокрутки нативного контейнера (`NSClipView.scroll(to:)`
  + `reflectScrolledClipView`, `UIScrollView.setContentOffset`)
  `host.layer.bounds.origin` **не меняется** — offset целиком принадлежит
  native clip view / scroll view layer, Trellis не участвует. Это прямая
  проверка требования P6.3 «Изменение только offset не запускает полный
  layout/raster» и противоположность дефекту #63 (`layer.bounds.origin`
  вручную в Weave).
- Один и тот же host-локальный `LayoutPoint` (центр `control.calculatedFrame`)
  до и после прокрутки корректно резолвится в `control` через
  `NodeHostBridge.send(.pointerDown, …)` — координатная конверсия hit-test
  не знает о scroll вообще, что и требует P6.3 («одна проверяемая конверсия
  для hit testing … reveal»).

Прогон: `swift build`/`swift test --filter NativeScrollEmbedding` (macOS,
AppKit-часть, 2/2 зелёные); `xcodebuild test -scheme Trellis-Package
-only-testing:TrellisRenderTests` на iPhone 17 Pro Simulator (UDID
`3D9E75A3-CD75-4A24-8D16-021D8E2FB490`, iOS 26.5) — 268 тестов, 1 не связанный
флейк (`m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping`,
уже задокументирован как дефект #60, не воспроизводится изолированно; здесь не
переисследовался); повторный изолированный прогон только двух новых UIKit-тестов
— зелёный. То же на Apple TV 4K Simulator (UDID `E4F3829E-9A69-4ABC-BE81-815B1B3C54B0`,
tvOS) — полный `TrellisRenderTests` зелёный без единого сбоя в этом прогоне.

**Что этот прототип не доказывает** (честно, не «пройдено»): реальный жест
(`UIPanGestureRecognizer`/`NSScrollView`'s собственный wheel/trackpad путь),
момент/bounce/deceleration от системы, AX scroll actions, поведение при resize
во время активной прокрутки, incremental raster/layout под реальным fling —
все они требуют либо реального окна+run loop (как M12/M13 уже документировали
для gesture recognizer'ов), либо устройства. Это остаётся отдельными пунктами
чек-листа R06 (нативное движение — фактически R08, здесь только геометрия
embedding) и не считается «доказано» этим прототипом.

### Native performance harness (§6.1) — срез, не полная приёмка

`Playground/Shared/PerfRecorder.swift`: `PerfSamples` (bounded, p50/p95/p99,
capacity 5000 с явным `droppedCount` — не растёт безгранично), `PerfEnvironment`
(device model через `sysctlbyname("hw.model", …)` — тот же на симуляторе и
устройстве, что честно отражается как «хостовый Mac» на симуляторе; OS version;
debug/release configuration; refresh rate через `UIScreen.maximumFramesPerSecond`/
`CGDisplayCopyDisplayMode`, `nil` а не выдуманный `60`; source revision —
явный параметр, не `git` в рантайме процесса), `PerfReport` (JSON
sorted+pretty и построчный CSV), `PerfLaunchConfiguration` (парсит `--perf-run
--perf-scenario --perf-seed --perf-count --perf-viewport --perf-repeats
--perf-warmup --perf-output --perf-revision` из `CommandLine.arguments` — тот
же приём, что уже `Scenario.initialIndex`/`--scene`).

`Playground/Shared/PerfHarness.swift`: один сквозной fixture
(`app-text-list-<N>`) — колонка из `N` `TextNode` (реальный `CoreTextRenderer`,
не headless fallback) с детерминированным LCG-содержимым по `--perf-seed`,
через настоящий `TrellisHostView`, прикреплённый к настоящему окну приложения.
`attach-to-ready` меряет `perfElapsedMs` + `waitForRenderReady` (существующая
функция `Scenario.swift`); `resize-to-commit` меряет request-to-*commit*
(polling `NodeHostBridge.statistics.committed`, `await Task.yield()` — не
ручной `RunLoop.main.run(until:)`, недоступный из async и не нужный: у
приложения уже крутится собственный run loop, в отличие от Bench), с явным
2-секундным пределом на итерацию и запиской в `notes`, если он превышен —
ни один прогон его не превысил. Первая версия функции по ошибке мерила только
синхронный вызов `layoutIfNeeded()`/`layout()` без ожидания реального коммита
(числа <0.01 ms — неправдоподобно быстро для 200 строк) — найдено и
исправлено до commit, не оставлено как дефект в отчёте.

`runPerfHarnessIfRequested(host:terminate:)` подключён во все три
`PlaygroundApp.swift` сразу после создания host/window, до любой другой ветки
запуска (`--export-all`, `--drive-focus`, обычный browse) — возвращает `false`
и ничего не меняет, если `--perf-run` не передан.

Реально прогнано (не только собрано):

- iOS: `xcrun simctl launch --console-pty <iPhone 17 Pro> org.trellis.playground.ios
  --perf-run --perf-scenario text-list --perf-count 200 --perf-seed 42
  --perf-viewport 390x844 --perf-repeats 10 --perf-warmup 2
  --perf-output /tmp/….json --perf-revision <rev>` — JSON+CSV написаны,
  `resize-to-commit` p50 ≈ 200 ms на 200 строк (симулятор, debug build).
- tvOS: тот же вызов на Apple TV 4K Simulator, `--perf-viewport 1280x720
  --perf-count 150` — p50 ≈ 122 ms, без единого timeout.
- macOS: бинарник приложения напрямую (`Playground-macOS.app/Contents/MacOS/
  Playground-macOS --perf-run …`) — p50 ≈ 127 ms.
- Подтверждено отдельно: запуск без `--perf-run` на iOS Simulator продолжает
  открывать обычный browse UI (флаг ничего не ломает по умолчанию).

**Что не сделано** (честно, не «пройдено»): XCUITest target в
`Playground.xcodeproj` (`xcrun simctl launch` — ручной/скриптовый вызов, не
автоматизированный UI-тест конкретных touch/remote сценариев, которых §6.1
явно требует); ровно один fixture (нет `text-paragraph`, нет grid/wide
аналога Bench); numeric budgets/baseline документ под
`docs/validation/r06-native-performance/` — эта evidence-запись не тот файл;
Instruments trace для реального hitch/frame-drop — deterministic sampling из
`PerfSamples` не выдаётся за это (§6.1 explicit); тот же прогон на физическом
устройстве (недоступно).

### Спецификация конфигурации §1.2 (предложение)

[scroll-configuration.md](../scroll-configuration.md) — не D-решение (нужен
явный разговор с пользователем, как и остальные P6-предложения плана 6), но
конкретное предложение: `ScrollConfiguration` эскиз с полями и default'ами
(axis/directionalLock/indicators/insets/bounce/keyboardDismiss/edgeLoad),
таблица платформенной поддержки iOS/tvOS/macOS, таблица явного поведения при
изменении каждого поля во время `isScrolling == true` (часть полей
откладывается до конца жеста — `axis`/`bounce`, часть применяется немедленно
— `indicators`/`edgeLoad`), и численная проверка примера «верхний Node 0.5H +
pager 1H» из §1.1 плана: конфигурация применяется дважды в одной композиции
(внешний scroll с растущей content length + pager с собственным конечным
viewport, не суммой строк), без числового противоречия. Арбитраж
внешний/внутренний scroll осознанно не решён здесь (это R09).

### Фиксация P6.3 как контракта (предложение)

[r06-scroll-api-sketch.md](r06-scroll-api-sketch.md) — API sketch в формате
t01-text-contract.md: coordinate spaces (host/content/viewport — content space
уже совпадает с сегодняшним committed-frame пространством, прототип это уже
доказал), constraints (продольная ось — `.unspecified`/max-content по ADR
0009, `.fraction` вдоль неё резолвится в 0 с диагностикой), `NativeScrollBacking`
(адаптерная граница, симметричная `EdgePullContainer`), `LayerRenderer.
scrollBackings` (T07-style parallel table), clipping/z-order (`.scroll` уже
существующий `OverflowPolicy` case, сегодня — синоним `.hidden` в
`applyPresentation`, sketch специфицирует замену), insets (передаются
backing'у, не считаются вручную Trellis), `ScrollPhase`
(idle/dragging/decelerating/settling/programmatic), `ScrollCommandOutcome`
(completed/superseded/cancelledByUser/notAttached — явное подтверждение вместо
Weave's синхронного возврата), и feedback suppression (`isUserDriven` —
native — источник истины во время жеста). 8 сценариев-кандидатов в тесты R07.
Явно нерешено этим документом: точный способ передачи backing-фабрики в
`attach(...)`, арбитраж вложенного scroll (R09), что такое backing на tvOS.

### Relay vs coordinated-native (срез, обновлён после фикса #65)

[r06-scroll-arbitration-comparison.md](../r06-scroll-arbitration-comparison.md):
relay изучен по реальному, шипящему в проде коду (`TabBarPagerController.swift`,
`ProfileViewController.swift`, полное чтение). По пути найден и исправлен
реальный дефект **#65** (`docs/defects.md`) — `Playground-iOS` без
`UILaunchScreen` уходил в legacy 320×480 scaling на холодном `simctl launch`,
из-за чего первый прогон прототипа выглядел сломанным, хотя вся логика была
верна; исправлено одной строкой в `project.pbxproj`
(`INFOPLIST_KEY_UILaunchScreen_Generation = YES`), подтверждено `NSLog`
(`scene.coordinateSpace.bounds` теперь `(402, 874)`, `activationState ==
.foregroundActive`) и визуально. После фикса — три контролируемых реальных
свайпа на iPhone 17 Pro Simulator дали убедительный, воспроизводимый
результат: touch-down на списке страницы **никогда** не передаёт жест
внешней шапке (даже свайпом на ~600pt, далеко за пределы высоты шапки),
touch-down на самой шапке скроллит только её — простое вложение
`UIScrollView` **не даёт** hand-off «список докрутился → жест уходит к
шапке» посреди одного пальцевого движения, опровергая исходную гипотезу
этой карточки. Пересмотренная рекомендация — coordinated-native, но в форме
«одна `UIScrollView` на страницу» (шапка как часть контента, а не второй
scroll поверх), для composition — шапка вне hit-testable области любой
page-scrollview, читает (не пишет) offset активной страницы. Честно не
закрыто: continuous momentum через границу шапка/список для этой формы не
проверен вживую (R08); AX-путь не проверялся. Прототип-файл был временным и
удалён после записи находок.

### Baseline и числовые бюджеты R15 (срез, не финальный baseline)

[docs/validation/r06-native-performance/](../validation/r06-native-performance/README.md):
реальный `app-text-list-1000` прогон через `PerfHarness` на всех трёх
платформах. iOS завершился с правдоподобными числами (attach-to-ready
5.17ms, resize-to-commit p50 1078ms, p99 1779ms, 0 таймаутов). tvOS и macOS
**не завершили** большинство итераций в 2-секундный предел харнесса —
собрано в конце сессии с несколькими параллельными Xcode-сборками/
Simulator-инстансами на одной машине, честно помечено как непригодное для
сравнения (не архитектурная деградация, конкуренция за ресурсы хоста).
Доказывает: pipeline `PerfLaunchConfiguration → PerfRecorder/PerfHarness →
JSON+CSV` работает end-to-end на всех трёх платформах через настоящий
`TrellisHostView`. Переснято чистым изолированным прогоном (без параллельной
сборочной нагрузки) — все три платформы завершили все 20 повторов без
таймаутов, согласованный порядок величины (p50 895–969ms на 1000 строк);
обновлённые JSON — в `r06-native-performance/`.

## Сознательно передано следующим карточкам (не пробел R06)

- Continuous momentum через границу шапка/список и AX-путь для пересмотренной
  архитектуры (§«одна scrollview на страницу») — R08's собственный чек-лист,
  требует реального `ScrollNode` (R07), которого ещё нет.
- XCUITest target с реальными touch/remote-сценариями — та же причина: нечего
  осмысленно автоматизировать до R07.
- Числовой бюджет на физических устройствах, несколько fixture, разбивка по
  фазам, Instruments trace — R15's собственная задача по тексту плана
  («R15 повторяет тот же protocol и сравнивает»).
