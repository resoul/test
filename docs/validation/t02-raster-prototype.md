# T02 — Прототип растра и стоимость до масштабного переноса

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
зависит от T01 ([t01-text-contract.md](t01-text-contract.md), [decisions.md](../decisions.md)
D49–D60). Код здесь — исследовательский срез (§4 плана: «не второй production pipeline»):
`TextNode`/`ContentMeasurer`/`TextRenderer`/`DisplayScheduler` остаются задачами T03–T06.
Раскладка two-layer (D65) сверена в объёме, который касается T02 (растр/layer identity);
retarget/completion анимации — M02 в implementation-plan-5.md, не в этой карточке.

## 1. CoreText → bitmap → `CALayer.contents`: механизм подтверждён

`Tests/TrellisRenderTests/TextRasterPrototypeTests.swift` — 7 тестов, только
`CoreText`/`CoreGraphics`/`QuartzCore` (без `TrellisCore`/`TrellisRender`), зелёные на
всех трёх платформах:

| Платформа | Команда | Результат |
|---|---|---|
| macOS | `swift test` | 7/7, весь пакет 499/499 |
| iOS 26.5 Simulator (iPhone 17 Pro) | `xcodebuild test -scheme Trellis-Package -destination "platform=iOS Simulator,id=3D9E75A3-…" -only-testing:TrellisRenderTests` | 112/112 |
| tvOS 26.5 Simulator (Apple TV 4K) | тот же с `id=E4F3829E-…` | 112/112 |

Проверено:

- **Baseline из `CTLine`, не константа.** Однострочный текст, scale 2 и 3:
  `firstBaselineFromTop` (высота фрейма минус `CTFrameGetLineOrigins`) сходится с
  `CTLineGetTypographicBounds`'s `ascent` в пределах 1pt; расходится с Weave-константой
  `lineHeight * 0.8` больше чем на 1pt для pointSize 17 — заявленное в defect #38
  расхождение воспроизведено и зафиксировано тестом
  (`t02_singleLineRasterMatchesRealAscentNotWeaveConstant`).
- **Перенос по реально доступной ширине, не по ширине экрана (§3.3/W04).** Тот же текст
  (~2000 символов) на `maxWidth: 160` даёт больше строк и большую высоту, чем на
  `maxWidth: 800` (`t02_paragraphWrapsByAvailableWidthNotByScreenWidth`) — высота приходит
  из констрейнта, который solver реально передал, что и есть контракт D49.
- **Кооперативная отмена минимум раз на строку.** Обход `CTFrameGetLines` с проверкой
  между строками останавливается на середине абзаца, не досчитывая до конца
  (`t02_lineWalkCooperativelyCancelsAtLeastOncePerLine`) — механизм для `LayoutContext.
  checkCancellation()` (D58) осуществим на реальном CoreText API, не только в теории.
- **`CALayer.contents`/`contentsScale`.** Bitmap применяется к `CALayer.contents`,
  `contentsScale` совпадает с запрошенным scale (2 и 3)
  (`t02_rasterAppliesToCALayerContentsAtRequestedScale`).

`import CoreText` был также добавлен временно в `Sources/TrellisRender/` (не закоммичено,
удалено после проверки) и собран `swift build` + `xcodebuild build` на macOS/iOS/tvOS
Simulator — все три чистые сборки без warnings, `python3 Scripts/check_policy.py` —
`PASS policy 2.0.0 (0 diagnostics)`. `CoreText` не входит в `platform_modules`
(`UIKit`/`AppKit`/`Cocoa`/`SwiftUI`/`Metal`) политики — критерий приёмки выполнен
лексически и подтверждён компиляцией на всех трёх SDK.

## 2. D65 two-layer contract: механизм (без анимации/retarget — то у M02)

Те же 7 тестов включают `RasterHarness` — внешний `CALayer` (position/bounds) +
внутренний sublayer (raster), оба под `CATransaction.setDisableActions(true)` (тот же
приём, что уже в `LayerRenderer`/`DebugOverlayRenderer`):

| # | Проверка | Результат |
|---|---|---|
| 1 | Перемещение внешнего слоя дважды | `rasterCallCount == 1`, identity внутреннего `contents` не изменилась — move не порождает raster job (`t02_movingOuterLayerDoesNotRerasterOrReplaceInnerContents`) |
| 2 | Resize (bounds/masksToBounds) до готовности нового bitmap | старый bitmap остаётся as-is (не растянут) до явной подмены; после — атомарная замена без crossfade (`t02_resizeKeepsOldBitmapUntilReplacementIsReady`) |
| 3 | Смена текста | `contents` явно очищается (`nil`) вместо показа старого текста как актуального, затем заменяется новым (`t02_textChangeDropsStaleContentsInsteadOfShowingOldTextAsCurrent`) — контраст с resize: временная пустота допустима, устаревший текст — нет (D65) |

Это подтверждает D65 (implementation-plan-5.md) как реализуемый на одном `CALayer`-парном
механизме, без второго рендерера. Не проверено здесь: реальный `DisplayScheduler`
(асинхронный worker, T06), retarget поверх активной анимации (M02), стоимость
дополнительного sublayer на 1000 узлов (ниже — только стоимость самого растра, не
слоёв; сравнение со сценой без раздельного raster layer остаётся M02/T11).

## 3. Sendable compile-probe (D54) — результат меняет умолчание плана

Пробный файл `Sources/TrellisRender/CoreTextPolicyProbe.swift` (создан, проверен, **удалён**
— не входит в коммит; результат ниже воспроизводим и его код при необходимости
восстанавливается по этому отчёту). Toolchain — `toolchain.json`: Xcode 26.6, Swift 6.3.3,
SDK 26.5, `swiftLanguageModes: [.v6]` (strict concurrency).

Проверка — не только «структура помечена `Sendable`» (это может тихо провалиться на
несвязанных полях), а прогон значения через `Task.detached { … }` (`@Sendable` замыкание),
что требует настоящей Sendable-проверки захваченного значения:

| Тип | `struct Probe: Sendable { let x: T }` | Захват в `Task.detached { _ = x… }` | Итог |
|---|---|---|---|
| `CGImage` | компилируется | компилируется, без warnings | **Sendable** на этом SDK |
| `CGColorSpace` | — | компилируется, без warnings | **Sendable** на этом SDK |
| `CTFont` | — | `error: passing closure as a 'sending' parameter risks causing data races… closure captures 'font'…` | **не Sendable** |
| `CGDataProvider` | — | тот же `#SendingClosureRisksDataRace`, `captures 'provider'` | **не Sendable** |

Собрано на macOS (`swift build`), iOS Simulator и tvOS Simulator (`xcodebuild build
-scheme Trellis-Package -destination "platform=…Simulator,id=…"`) — `CGImage`/
`CGColorSpace` чистые на всех трёх; никаких `@unchecked Sendable`, `nonisolated(unsafe)`
или `@preconcurrency` не использовано (запрет AGENTS соблюдён, `check_policy.py`
`UNSAFE_CONCURRENCY` не сработал бы на них, а фактически и не понадобился).

**Это меняет умолчание, записанное в D54.** План (T01) предполагал: «CGImage лежит в
Sendable-структуре без проверки компилятором», предпочтение — `Data`-копия. На пином SDK
это не так: `CGImage` реально аудирован как `Sendable`, и `DisplayArtifact` может нести
`CGImage` напрямую без обязательной копии в `Data`. Обновление D54 — ниже в этом отчёте;
`decisions.md` дополнен ссылкой.

### 3.1. Стоимость обоих вариантов для 1000 строк

`Bench/Sources/TrellisBench/main.swift`, фикстура `text-raster-1000` (добавлена этой
карточкой; standalone CoreText-код, не зависит от TrellisRenderTests). Запуск:
`TRELLIS_BENCH_ONLY=text-raster-1000 python3 Scripts/bench.py --iterations 20 --label
t02-text-raster --write-summary`, Release, `TRELLIS_LOG=off`, MacBook Air (см.
[measurements/2026-09-12-t02-text-raster-release.json](measurements/2026-09-12-t02-text-raster-release.json)).

| Метрика | p50 | p95 | max |
|---|---|---|---|
| Растеризация 1000 строк (CoreText → `CGImage`) | 73.4 ms | 84.2–87.2 ms | 87.2 ms |
| Копирование 1000 `CGImage` → `Data` (стоимость варианта Б, которую вариант А не платит) | 8.2–9.6 ms | 12.7–13.7 ms | 13.7 ms |

Копирование в `Data` — дополнительные **~11–15% от времени самой растеризации** на 1000
строк; при прямом `CGImage`-артефакте (вариант А, теперь допустимый по §3 выше) эта
стоимость не возникает вовсе.

Резидентная память (один процесс, последовательные фазы — см. оговорку ниже):
`resident-before` 312.7–320.8 MiB, `resident-holding-1000-cgimage` +4.0 MiB,
`resident-holding-1000-data-copies` +4.0 MiB сверх этого (данные до `nil` предыдущего
держателя). `bytes-per-copy-sample` (одна строка, последняя из 1000, самая длинная):
84096 байт RGBA.

**Важная оговорка, не финальный бюджет T11.** Наблюдаемая суммарная резидентная дельта
(~8 MiB на оба держателя) заметно меньше, чем 1000 × 84 КБ (~84 МБ) — вероятная причина:
незакрашенные (прозрачные) области bitmap остаются страницами с нулевым содержимым,
которые ядро может отображать на общую zero-page до первой записи, поэтому «пустой фон»
внутри каждой строки не обязательно материализуется в резидентную память сразу. Это не
доказательство фактического потребления на устройстве под нагрузкой (компрессия памяти,
реальная плотность текста, живые ссылки во время scroll — другое дело); T11 обязана
перемерить на менее вырожденном сценарии (например, сцене с реальной плотностью текста и
удержанием всех 1000 artifacts одновременно в производственной структуре данных), а не
брать эти цифры как бюджет. Числа здесь — входные данные для T11, не его результат
(ровно то, что просит приёмка T02).

## 4. Обновление D54 (decisions.md)

D54 в [decisions.md](../decisions.md) дополнена (не заменена — предпочтение оставалось
условным до этой проверки): на закреплённом SDK (Xcode 26.6/Swift 6.3.3/SDK 26.5) `CGImage`
и `CGColorSpace` — `Sendable` без unsafe обходов; `CTFont`/`CGDataProvider` — нет.
`DisplayArtifact` (T06) может нести `CGImage` напрямую вместо обязательной `Data`-копии;
`Data`-вариант остаётся резервным путём для более широкой матрицы SDK, если T06
обнаружит регресс на другом закреплённом SDK. Обе стороны T02 (растр-механизм и
Sendable-стоимость) не блокируют T03–T05.

## Приёмка T02

- CoreText → bitmap → `CALayer.contents` подтверждён на macOS, iOS Simulator, tvOS
  Simulator: 7/7 прототипных тестов, полный набор пакета зелёный на всех трёх (499/112/112).
- `import CoreText` в `TrellisRender` проходит `check_policy.py` (`PASS`, 0 diagnostics) и
  реально компилируется на всех трёх SDK (проверено, пробный файл удалён).
- D54 закрыта компиляционной проверкой, а не предположением: `CGImage`/`CGColorSpace`
  Sendable, `CTFont`/`CGDataProvider` — нет; решение записано в decisions.md.
- Числа для бюджета T11 — раздел 3.1 и `measurements/2026-09-12-t02-text-raster-release.json`,
  с честной оговоркой о занижении из-за zero-page.
- D65 (implementation-plan-5.md) подтверждён на уровне механизма (move/resize/text-change);
  retarget поверх активной анимации и стоимость на 1000 узлов с реальным deferred worker —
  остаются M02/T11, не закрываются здесь.
- `check_all.py`-эквивалентные шаги пройдены точечно: `check_policy.py` PASS,
  `verify_bootstrap.py` PASS (включая `-warnings-as-errors` build+test+consumer),
  `check_api.py --tvos` PASS (0 изменений публичного API — карточка не трогала
  production-поверхность).
