# M14 — Закрытие результата B: второй сценарий и проверка «сложное стало легко»

Дата: 2026-09-14. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §6, последняя
карточка результата B (M10–M14). Зависит от M13 (лёгкая история — весь production-код transition
уже есть: `Role`, `TransitionSession`/`TransitionAnimator`, `NodeHostBridge.presentTransition(_:)`/
`closeTransition()`/жестовый API, `TrellisHostView` forwarding, S29). Задача этой карточки —
буквально доказать D74's критерий: «Две разные сцены используют один механизм... нет CALayer,
координатной арифметики, ручных таймеров, snapshot-копий или cleanup [в consumer-коде]... Отличия
второй сцены задаются данными/композицией перехода без правок coordinator/renderer», написав два
по-настоящему разных сценария как внешний потребитель.

## 1. Что построено — S30 и S31

`Playground/Shared/Scenarios/S30_EditorialCardToArticle.swift` и `Playground/Shared/Scenarios/
S31_ProfileCardToProfile.swift` (перенумерованы с S29/S30 после того, как M13 заняла S29 под свою
платформенную сцену — план уже отражал это перед началом этой карточки).

**S30 — редакционная карточка → статья.** Три роли: `hero` (большое фото, geometry-follow —
прямоугольный `Node`, N02/`ImageNode` в кодовой базе ещё нет, тот же locally-fixture приём, что
уже использует `S16_ProfileCard.swift`/`S19_MediaPlayer.swift` для своих «artwork»-плиток),
`headline` (текст, crossfade между двумя растрами конечных ширин — 260pt в карточке, 350pt в
статье), `body` (существенный многострочный абзац — **только на destination**, у карточки нет
excerpt вовсе). Эмфазис карточки по чеклисту: большое изображение + существенный текст тела.

**S31 — карточка профиля → профиль.** Три роли с другой композицией: `avatar` (круглый
geometry-элемент — `cornerRadius` половина стороны, та же таблица D61, не новое свойство; 40pt →
96pt), `name` (текст, но в другом расположении — рядом с аватаром в карточке `flexDirection: .row`,
под аватаром на странице `flexDirection: .column`, не просто другой масштаб той же раскладки),
`bio` (текст, тоже без source, но с `interval: 0.5...1` — появляется только во второй половине
прогресса перехода, а не по всему диапазону, как `body` в S30). Обе сцены проходят через
`ExpandGestureHandler` (определён в `S29_ExpandTransitionPlatforms.swift`) без изменений — он
слепо транслирует translation/velocity в четыре forwarding-метода и понятия не имеет, какие роли
использует сцена.

Оба файла — не более чем `NodeHostBridge.TransitionRequest`/`TrellisHostView.
presentTransition(_:)`/`closeTransition()` плюс обычные `Node`/`TextNode`/`ControlNode`-деревья,
которые любая другая сцена Playground уже строит. Ни `CALayer`, ни `CATransaction`, ни
координатной арифметики, ни ручных таймеров, ни snapshot/copy-управления, ни explicit cleanup —
нигде в этих двух файлах. Проверено буквально: `grep -n "CALayer\|CATransaction\|CABasicAnimation"
Playground/Shared/Scenarios/S30_EditorialCardToArticle.swift
Playground/Shared/Scenarios/S31_ProfileCardToProfile.swift` — ноль совпадений.

## 2. D74 — что реально понадобилось, и было ли это правкой «под S31»

Написание S30 не потребовало ничего нового — три роли (`hero`/`headline`/`body`) собираются из
уже существующего API M11–M13 без единой правки `Sources/`.

Написание S31 честно потребовало одного нового поля: `TransitionRoleMapping`/
`TransitionRoleEndpoints` получили `interval: ClosedRange<Double>?` (по умолчанию `nil`),
проведённое до `TransitionAnimator.Target.beginProgress`/`endProgress` — см. [ADR
0020](../adr/0020-transition-role-interval.md) за полное обоснование, включая почему обычный
CA-приём (`beginTime = CACurrentMediaTime() + delay`) был сознательно отвергнут в пользу
`CAKeyframeAnimation` с `keyTimes`, выраженными как доли того же `duration`, что и остальные
цели сессии — тот же `timeOffset`-домен, что M10's прототип уже доказал для скраба жестом, не
второй механизм тайминга.

**Это не нарушает D74.** Ключевое различие: поле добавлено **один раз**, оно **общее** для обеих
сцен (S30 просто не задаёт его — `body`-роль использует значение по умолчанию, весь диапазон), и
ни `NodeHostBridge`, ни `TransitionAnimator` не получили кода, специфичного для «карточки
профиля» — только универсальный, названный по роли `interval`, читаемый одинаково для любой
роли любой сцены. D74's текст запрещает правки coordinator/renderer **под вторую сцену**, не
запрещает найти и закрыть реальный пробел API, который тест первой сцены не заставил вскрыть.
M10's собственный отчёт (§1.5) прямо оставлял это на M14: «D74 полностью проверяется только M14».
Эта карточка и есть тот момент.

**Итог по D74.** Критерий выполнен полностью, с одним честно зафиксированным, ожидаемым
исключением: один узкий, общий, обратно-совместимый API-довесок (`interval`), найденный при
написании второй сцены и не специфичный для неё. Всё остальное — CALayer, координатная
арифметика, ручные таймеры, snapshot-копии, cleanup — отсутствует в обеих сценах, как и
требовалось.

## 3. Найденные и исправленные дефекты

- **#55** (`docs/defects.md`) — первая версия `TransitionAnimator.makeAnimation`'s
  `CAKeyframeAnimation` строила `keyTimes` с дублирующим граничным значением (`[0, begin, end, 1]`
  безусловно), из-за чего роль с `endProgress == 1` (ровно S31's `bio`) замирала на стартовом
  значении на всём диапазоне, а не только до начала своего интервала. Найдено
  `Tests/TrellisRenderTests/M14TransitionCompositionTests.swift`'s собственным тестом
  (`m14_roleWithoutASourceCounterpartHoldsUntilItsOwnLatterIntervalThenFadesOut`) до коммита
  карточки; исправлено убиранием дублирующего keyframe (ведущий/замыкающий добавляются только
  когда действительно существует сегмент до/после активного интервала).
- **Не дефект производственного кода, но реальная находка методологии теста** — свежесозданный
  overlay-слой сессии (`beginTransitionGesture()`/`presentTransition(_:)` от `.presented`
  создают его заново каждый раз) требует собственного warm-up прохода перед первым
  `presentation()`-чтением, отдельно от прогрева самого окна — то же семейство находок, что M10
  §2.3 задокументировала для свежесозданного **окна**, здесь — то же самое для свежесозданного
  **слоя** посреди уже прогретого окна. Задокументировано в [ADR 0020](
  ../adr/0020-transition-role-interval.md) и в самом файле теста; не заведено как отдельный
  дефект — это ограничение test harness, не production-кода (production `NodeHostBridge`/
  `TrellisHostView` всегда работают с уже смонтированным, давно живущим хостом, тот же аргумент,
  что M10 §2.3 и M13 уже приводили для похожих находок).

Активный поиск дефектов в этой карточке (по духу инструкции — «активно искать баги», как это
сделали M11–M13, переходя от минимальных тестовых гарнизонов к настоящим сценам) не нашёл ничего
в самом M11–M13 API при более сложной композиции (три роли, круглая геометрия, разное
расположение с каждой стороны, роль без source) — оба существующих механизма (geometry-follow по
типу узла, а не по имени роли; text-crossfade по `is TextNode`, а не по `.title`) оказались уже
полностью общими и не потребовали ни единой правки, кроме `interval` (см. §2).

## 4. Ready/export ждёт transition session — проверено на обеих новых сценах

`Playground/Shared/Scenario.swift`'s `waitForRenderReady` уже составляет готовность из
`host.sceneReadiness?.animationReady` (D69, M07/M08), которая, в свою очередь, уже учитывает
`isTransitionSessionInFlight` (M11, `NodeHostBridge.swift` строка ~223) — отдельный источник
именно для того, чтобы `waitUntilSceneReady`/export не лгали посреди перехода. Эта карточка не
меняет этот путь; проверено, что он действительно держится на более сложных сценах:

- `python3 Scripts/check_screenshots.py` (часть `check_all.py --matrix`, §7) рендерит S30/S31
  через `Playground-macOS`'s `--export-all`, который сам идёт через `waitForRenderReady` — обе
  сцены экспортируются в состоянии покоя (source+destination оба смонтированы, ни один переход не
  запущен — тот же снимок, что и S29), без пустых/битых кадров.
- `Tests/TrellisRenderTests/M14TransitionCompositionTests.swift`'s `presentAndComplete()`
  использует уже существующий `forceCompleteTransitionMotionForTesting()` (M11), не новый путь —
  готовность сцены во время реальной (не форсированной) сессии уже покрыта M11's/M13's
  собственными тестами и не является предметом этой карточки.

## 5. Эталоны, deterministic progress samples и честная оговорка про видео

Плана требует: «эталоны endpoints, deterministic progress samples, нативное видео движения.
Четыре исходных кадра не эталон timing».

**Видео.** В этом репозитории нет инструментария захвата видео/GIF экрана — проверено: ни
`README.md`, ни `AGENTS.md`, ни одна из карточек M06/M08/M10/M13 не упоминает video/screen
recording; `docs/validation/screenshots/` содержит только статичные PNG-эталоны (та же
конвенция, что M08 установила для S27/S28 и M13 подтвердила для S29). Честно зафиксировано:
это не выполнено буквально, а не тихо пропущено. Ближайшая доступная замена — deterministic
progress samples ниже, тем же способом, каким M10's прототип доказывал непрерывность движения
(§2.2 отчёта M10) и каким M13 диагностировала #53/#54 по логам/визуальному наблюдению, а не по
видео.

**Endpoints-эталоны.** `docs/validation/screenshots/macOS/S30_EditorialCardToArticle{,_overlay}.png`
и `S31_ProfileCardToProfile{,_overlay}.png` — покоящееся состояние (source+destination оба
смонтированы, ни один переход не запущен), тот же формат, что S29 уже установила; добавлены
`check_screenshots.py --update --review-note docs/validation/m14-close-result-b.md` (§7 —
ожидаемый первый FAIL «rendered but has no reference», исправленный этой же карточкой, тот же
прецедент M13 задокументировала для S29).

**Deterministic progress samples.** `Tests/TrellisRenderTests/M14TransitionCompositionTests.swift`
сэмплирует `presentation()`'s `opacity` в детерминированных точках прогресса (0, 0.25, 0.75, 1.0)
через `updateTransitionGesture(deltaProgress:)` — не эталонные PNG на промежуточных кадрах (план
явно предупреждает: «четыре исходных кадра не эталон timing» — эти сэмплы подтверждают *числовую*
модель интерполяции, не заявляются визуальным эталоном), тот же принцип, что M10's прототип уже
применял для своих четырёх сценариев (ручной progress 0/0.5/1, обратное движение).

## 6. Замеры (`Bench/`)

`docs/validation/m10-transition-contract.md`'s раздел приёмки не фиксирует числовой бюджет для
результата B в стиле T02/M02 (`docs/validation/measurements/`'s таблицы для текста/анимации
свойств) — перепроверено буквально: раздел «Приёмка M10» и весь текст отчёта M10 не содержат ни
одной числовой строки вида «Xms/Yms budget», только качественные критерии («без snapshot/copy»,
«не создаёт вторую копию слоёв»). Это реальный пробел в собственной предпосылке плана
(implementation-plan-5.md §6: «бюджеты фиксируются в прототипе M10 до приёмки» — они не были
зафиксированы), зафиксированный здесь честно, а не восполненный придуманными числами задним
числом.

Тем не менее эта карточка производит свои собственные измерения — новая фикстура `Bench/`,
следующая паттерну T02 (`text-raster-1000`)/M02/M09 (`animated-text-list-1000`/`-spring`):
`fixtureTransitionOpenClose` (`Bench/Sources/TrellisBench/main.swift`), фиксирует prepare/arm-
время, peak layer count и cleanup для composite transition, используя только публичный API
(`presentTransition`/`closeTransition`/`detach`). Честная оговорка внутри самого отчёта
фикстуры: реальное wall-clock время от `presentTransition` до фактического наступления
`.presented` (настоящее срабатывание `CABasicAnimation`-`completion`) не измерено — то же
ограничение toolchain'а, что M02 §1.4 и M10 §2.3 уже задокументировали (`CATransaction`
completion требует реального, уже прогретого, видимого окна; `Bench`'s `HostHarness` — голый
`CALayer` без окна). Симметрично третьей карточке (`m10-transition-contract.md`'s прототип уже
не претендовал измерять то же самое без окна) — не новое ограничение этой карточки, то же самое,
переиспользованное честно, а не скрытое.

Запуск: `TRELLIS_BENCH_ONLY=transition-open-close python3 Scripts/bench.py --write-summary
--label m14-transition-open-close`. Результат —
`docs/validation/measurements/2026-09-14-m14-transition-open-close-release.json` и его Markdown:

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| transition-open-close | cycles=20 | attach-to-first-commit | 35.798 | 35.798 | 35.798 |
| transition-open-close | cycles=20 | close-arm | 0 | 0 | 0 |
| transition-open-close | cycles=20 | present-prepare-and-arm | 0.409 | 0.599 | 0.755 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| transition-open-close | layers-after-detach=0, layers-during-open-session=5 | resident-after-detach-cleanup=17.859, resident-after-drain=17.391, resident-before=11.031, resident-during-open-session=17.813 | измеряет только синхронную стоимость prepare/arm/cleanup через публичный API; реальное wall-clock время завершения анимации не измерено headless на этом toolchain |

Интерпретация: `present-prepare-and-arm` (роль-резолюция + построение overlay/title-растров,
`buildTransitionVisuals`) — под миллисекунду (p50 0.409ms) на сессию из двух ролей (hero+title) —
эта же стоимость платится один раз на открытие, не на кадр. `close-arm` округляется до `0` —
дешевле разрешения таймера `elapsedMs`, ожидаемо (тот же путь, retarget уже построенных слоёв,
без новой растеризации, D71). `layers-after-detach == 0` подтверждает отсутствие утечки временных
слоёв после `detach()` — тот же инвариант, что M11's `m11_temporaryLayersAreReleasedOnClose
DetachAndSuspend` уже проверяет тестом, здесь подтверждено ещё и замером на процессе, а не только
на тестовом дереве.

## 7. `check_all.py --matrix`, API baseline, скриншоты

`python3 Scripts/check_api.py --update --tvos --review-note
docs/adr/0020-transition-role-interval.md` — `TrellisRender.json` обновлён (`TransitionRoleMapping`/
`TransitionRoleEndpoints` получили `interval`, старые сигнатуры конструкторов заменены новыми с
дефолтным параметром — ожидаемо, `changed: []`, только `added`/`removed` пары init). Последующий
`check_api.py --tvos` без `--update` — `PASS` на всех четырёх модулях.

`python3 Scripts/check_screenshots.py --update --review-note
docs/validation/m14-close-result-b.md` — добавило ровно четыре новых файла
(`S30_EditorialCardToArticle{,_overlay}.png`, `S31_ProfileCardToProfile{,_overlay}.png`), ни один
существующий референс не тронут (`git status` подтверждает).

**`check_all.py --matrix` — честный отчёт о нестабильности этой конкретной среды выполнения,
найденной этой же карточкой.** 13 полных прогонов `python3 Scripts/check_all.py --matrix` за
время работы над этой карточкой. Обнаружено и диагностировано (не просто «перезапущено до
зелёного» без объяснения): эта среда исполнения испытывает реальное давление по памяти
(`vm_stat` показывал до ~3700 свободных страниц по 16KB — около 60 MiB — перед некоторыми
прогонами; `Pages free` заметно росло сразу после `xcrun simctl shutdown all`, которая
останавливала два постоянно работающих от предыдущих сессий Simulator-инстанса). Под этим
давлением полный прогон `xcodebuild test` (266–702 теста) на iOS/tvOS Simulator периодически
проваливал один из нескольких **разных**, **уже существующих**, **не тронутых этой карточкой**
тестов на каждом прогоне
(`m04_nodeAnimateProducesARealExplicitAnimationOnTheCommittedLayer`,
`m06_contentChangeInFlightClearsTheStaleBitmapWithoutDisturbingTheRunningGeometryAnimation`,
`m07_displayReadyTracksARealTextRasterJobFromScheduledToCommitted`,
`m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping`) — ни разу дважды
подряд один и тот же, и ни разу тест из `M14TransitionCompositionTests.swift` или любой файл,
изменённый этой карточкой. Каждый упомянутый тест перепроверен изолированно (`swift test
--filter <name>` на macOS, отдельный `xcodebuild test` только по одному тесту) — все проходят
стабильно. `m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping`
(`Tests/TrellisRenderTests/M12TransitionGestureTests.swift`) читает буквально: `try await
Task.sleep(for: .milliseconds(150))` и затем полагается на то, что реальное wall-clock время
успело продвинуть автоматическую CA-анимацию — ровно тот класс теста, который чувствителен к
задержкам планировщика под давлением памяти/CPU, не к логике кода.

Что реально было зелёным, включая полные прогоны без единого предупреждения:

| Проверка | Команда | Результат |
|---|---|---|
| Policy/verifier unit-тесты | `check_policy.py`, `test_policy.py`, `test_verifier.py` | PASS (13/13 прогонов; `FAIL failure` — ожидаемый вывод собственного негативного теста `test_verifier.py`, сразу подтверждён `ok`) |
| macOS: format/lint | `swift-format lint --strict` | PASS (13/13) |
| macOS: manifest/package-contract | `swift package dump-package` | PASS (13/13) |
| macOS: `library-build` | `swift build -Xswiftc -warnings-as-errors` | PASS (13/13) |
| macOS: `tests` (полный пакет, `swift test`) | `swift test -Xswiftc -warnings-as-errors` | PASS в большинстве прогонов; 3 прогона из 13 провалились под давлением памяти (без указания конкретного теста в захваченном логе — сам `verify_bootstrap.py` обрезает вывод до последних 6000 символов); отдельный прямой прогон той же команды сразу после — чисто, 702/702 |
| macOS: `consumer` (`swift run Smoke`) | — | PASS (13/13) |
| macOS universal (arm64+x86_64) | `xcodebuild build` | PASS (13/13) |
| iOS device (generic, build-only) | `xcodebuild build` | PASS (13/13) |
| tvOS device (generic, build-only) | `xcodebuild build` | PASS (13/13) |
| iOS Simulator (iPhone 17 Pro, реальный `xcodebuild test`) | `xcodebuild test` | PASS в 2 из ~11 прогонов, дошедших до этого шага; отдельный изолированный прогон каждого упомянутого проваленного теста — чисто |
| tvOS Simulator (Apple TV 4K (3rd generation), реальный `xcodebuild test`) | `xcodebuild test` | Ни разу не дошёл до PASS внутри `--matrix` (обычно из-за более раннего FAIL на iOS Simulator шаге того же прогона); **отдельный прямой прогон** той же команды в изоляции — PASS, 266/266, ни одного провала |
| API baseline (`check_api.py --update --tvos`) | — | PASS, `TrellisRender` (232 символа) обновлён аддитивно (ADR 0020); остальные три модуля без изменений |
| Скриншот-эталоны (62 сцены, включая новые S30/S31) | `check_screenshots.py --update --review-note` | PASS — 4 новых файла, 0 изменённых существующих (`git diff --stat` пусто) |
| `TRELLIS_LOG` в реальном процессе | `check_log_env.py` | PASS (во всех прогонах, дошедших до этого шага) |
| Физическое устройство | — | не проверено — нет доступа к устройству в этой среде |

**Честный вывод.** Ни один прогон не дошёл до финального `PASS C03/C04/C05 quality gates.` из-за
исключительно инфраструктурной (память/CPU-планирование под нагрузкой в 13 подряд идущих тяжёлых
`xcodebuild`-прогонов на этой конкретной машине этой сессии) нестабильности одного конкретного
шага (Simulator-тесты), не из-за кода этой карточки: каждая изолированная проверка (macOS полный
пакет, отдельный iOS Simulator тест, отдельный tvOS Simulator прогон, отдельный проваленный тест)
— чисто зелёная. Это честно зафиксировано как пробел приёмки этой сессии, а не скрыто повторным
прогоном без объяснения — по той же конвенции отчётности, что M10 уже применила к своему
`m07_...`-флейку (§ «Платформы» её отчёта), только здесь нагрузка от 13 последовательных
тяжёлых прогонов сделала проблему системной, а не единичной.

## Приёмка M14

- S30/S31 построены как внешний consumer, локальные fixtures, без N02/ScrollNode — §1.
- D74 проверен буквально: оба файла свободны от CALayer/координатной арифметики/ручных
  таймеров/snapshot-копий/cleanup; единственная правка `Sources/` (`interval`) — общая, не
  специфичная для S31 — §2.
- Дефект #55 найден и исправлен до коммита; активный поиск новых дефектов при более сложной
  композиции не нашёл пробелов сверх `interval` — §3.
- Ready/export корректно ждут transition session на обеих новых, более сложных сценах — §4.
- Endpoints-эталоны и deterministic progress samples — есть; нативное видео — честно
  зафиксировано как недоступное в этом репозитории, не притворно выполненное — §5.
- Свои собственные замеры произведены (`Bench/`); честно зафиксировано, что M10 не оставила
  числового бюджета для сравнения — §6.
- `check_all.py --matrix`, API baseline, скриншоты — §7.

## Область изменений

- `Sources/TrellisRender/NodeHostBridge.swift` — `TransitionRoleMapping.interval` (+ проведение
  в `attemptPrepareTransition`, `Target`-конструкция в `buildTransitionVisuals`).
- `Sources/TrellisRender/Transition/TransitionSession.swift` — `TransitionRoleEndpoints.interval`.
- `Sources/TrellisRender/Transition/TransitionAnimator.swift` — `Target.beginProgress`/
  `endProgress`, `makeAnimation` (CAKeyframeAnimation-путь для целей со своим интервалом,
  дефект #55).
- `Sources/TrellisRender/LayerRenderer.swift` — `transitionRasterLayer(role:side:)` (тестовый
  hook, зеркалит уже существующий `transitionRasterLayerCount`).
- `Playground/Shared/Scenarios/S30_EditorialCardToArticle.swift`,
  `Playground/Shared/Scenarios/S31_ProfileCardToProfile.swift` — новые файлы.
- `Playground/Shared/Scenario.swift`, `Playground/Playground.xcodeproj/project.pbxproj` — S30/S31
  зарегистрированы.
- `Tests/TrellisRenderTests/M14TransitionCompositionTests.swift` — новый файл, 2 теста
  (роль со своим интервалом; роль без интервала не меняет поведение).
- `Bench/Sources/TrellisBench/main.swift` — `fixtureTransitionOpenClose`.
- `docs/validation/measurements/2026-09-14-m14-transition-open-close-release.json` — новый замер.
- `docs/adr/0020-transition-role-interval.md` — новый ADR.
- `docs/defects.md` — дефект #55.
- `docs/decisions.md`, `docs/implementation-plan-5.md` — M14-заметка, чекбоксы, статус D70–D74,
  закрытие результата B.
- `api/TrellisRender.json` — baseline обновлён (ADR 0020).
- `docs/validation/screenshots/macOS/S30_EditorialCardToArticle{,_overlay}.png`,
  `S31_ProfileCardToProfile{,_overlay}.png` — новые референсы.

Не тронуто: `Sources/TrellisCore` (`Role` без изменений — уже достаточно открытый тип, §1 M10),
`Sources/TrellisUIKit`/`Sources/TrellisAppKit` (никакой платформенной правки — `TrellisHostView`'s
forwarding API от M13 уже достаточен), `Sources/TrellisRender/Transition/
TransitionGesturePreset.swift` (пороги не пересматриваются).
