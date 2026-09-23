# R02 — Подключить TrellisFlux

Дата: 2026-09-14. Карточка [implementation-plan-6.md](../implementation-plan-6.md)
§5, R02. Зависимость: R01 ([r01-flux-foundation.md](r01-flux-foundation.md)).

## Предпосылка: исправленный Flux

R01 нашёл дефекты #56–#59 во Flux 1.2.0 и заблокировал R02 до отдельного
исправленного pin. Исправление сделано и выпущено во внешнем репозитории:

| | |
|---|---|
| Commit | [`e99f664`](https://github.com/resoul/flux/commit/e99f664) |
| Release | [1.2.1](https://github.com/resoul/flux/releases/tag/1.2.1) |
| Штатный suite | 150 тестов (138 прежних + 12 новых regression, `FoundationRegressionTests.swift`), зелёный |
| Дефекты | #56, #57, #58, #59 закрыты в [defects.md](../defects.md) со ссылкой на этот commit |

Regression-тесты нацелены именно на воспроизведённые R01 сценарии (не только на
характеризацию): concurrent `modify` без потери инкремента, registration/replay в
одном actor turn, cancel до/во время MainActor-доставки без buffered значений,
`flatMapLatest` без stale yield после switch. Flux и Weave не менялись —
исправление сделано в собственном репозитории Flux, отдельным коммитом и тегом.

## Изменение в Trellis

`Package.swift`: один новый external dependency (`https://github.com/resoul/
flux.git`, `exact: "1.2.1"`), один новый продукт/target `TrellisFlux` (зависит от
`TrellisCore`, `TrellisRender` и продукта `Flux`), один новый test target
`TrellisFluxTests`. `TrellisCore`/`TrellisRender`/`TrellisUIKit`/`TrellisAppKit`
не меняются и не получают зависимость от Flux — обоснование и полный diff в
[ADR 0021](../adr/0021-trellis-flux-target.md).

`Sources/TrellisFlux/TrellisFlux.swift` — единственный файл первого среза:
`@_exported import Flux` плюс `TrellisFlux.fluxVersion`. Внутри пакета видимость
`package` (`StateSubject.observe`, D14) уже открыта для будущей интеграции — этот
мост (P6.2) не реализуется в R02, только модульный граф.

## Проверки

| Проверка | Результат |
|---|---|
| `swift build` (macOS) | чисто, `-warnings-as-errors` |
| `swift test` (весь пакет, 704 теста) | зелёный; один ретрай снял уже известный флейк `m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping` ([defects.md #60](../defects.md), не связан с этой карточкой) |
| `Scripts/verify_bootstrap.py` (без `--matrix`) | PASS, включая обновлённый Smoke-consumer |
| `Scripts/verify_bootstrap.py --matrix` | PASS полностью (macOS universal, iOS/tvOS device build, iOS/tvOS Simulator test) на итоговом прогоне; см. «Флейки» ниже |
| `Scripts/check_api.py` (все 5 модулей) | PASS; `TrellisFlux` — 2 символа, новый `api/TrellisFlux.json` через [ADR 0021](../adr/0021-trellis-flux-target.md) |
| `Scripts/check_api.py --tvos` | PASS, `TrellisUIKit` surface не изменился |
| `python3 Scripts/test_verifier.py` | 5 тестов зелёные: valid manifest, contract regressions (включая новые негативные фикстуры — левый URL, диапазон вместо `exact`, дубль зависимости), Flux, протёкшая в Foundation-only target, `TrellisFlux` без реальной зависимости от Flux |
| `xcrun swift-format lint --strict` | PASS |

### Dependency policy (`Scripts/verify_bootstrap.py`)

`manifest_issues` теперь: ровно один внешний git-dependency, URL и `exact`
requirement сверяются буквально с зафиксированным pin; продукт/target graph
ожидает пять библиотек и три test target; отдельно проверяется, что
`TrellisCore`/`TrellisRender`/`TrellisUIKit`/`TrellisAppKit` не получили Flux в
зависимостях таргета, а `TrellisFlux` — получил (не заглушка). Негативные
фикстуры в `test_verifier.py` покрывают: отсутствие зависимости, чужой URL,
range вместо `exact`, две зависимости сразу, Flux в Foundation-only target,
`TrellisFlux` без Flux.

### Smoke consumer

`check_consumer` (`Scripts/verify_bootstrap.py`) теперь дополнительно подключает
`TrellisFlux` и в конце `Smoke.main()` создаёт настоящий `CurrentValue` из
зависимости, `set`/читает поток — не только компилирует импорт. `main()` стал
`async throws` (был `throws`) для реального `await` на Flux API.

## Playground

`Playground/Playground.xcodeproj/project.pbxproj`: продукт `TrellisFlux`
подключён (`packageProductDependencies`/Frameworks build phase) ко всем трём
target — `Playground-iOS`, `Playground-tvOS`, `Playground-macOS`, тем же
способом, что уже подключены `TrellisUIKit`/`TrellisAppKit`. Native reactive
сцены (P6.5+) — предмет более поздних карточек (R10+); здесь только
инфраструктурное подключение продукта.

## Локальная разработка (документированный override)

`README.md` фиксирует способ работать против непроверенного checkout Flux без
правки `Package.swift`:

```sh
swift package edit Flux --path ../old/flux
swift package unedit Flux
```

Проверено на этом дереве: `edit` резолвит зависимость на `../old/flux`,
`swift build`/`swift test` используют содержимое checkout; `unedit` возвращает
pinned `1.2.1`. Опубликованный манифест не редактируется; override не должен
попадать в коммит `.build`/`Package.resolved` состояние (эти пути и так вне
git — см. `.gitignore`).

## Bench

`Bench/Package.swift`: обновлён только комментарий (пять продуктов вместо
четырёх, точная проверка количества — в `verify_bootstrap.py`, не в
комментарии). Bench остаётся двухпродуктовым consumer'ом (Core/Render) — не
подключает Flux, соответствует плану («Bench остаётся отдельным consumer
executable, не обязан импортировать каждый продукт»).

## api/TrellisFlux.json — почему одна macOS-baseline

`TrellisFlux` импортирует только `Foundation` + `Flux` (кросс-платформенный) —
как `TrellisCore`/`TrellisRender`, без UIKit/AppKit. Платформенного расхождения
поверхности не ожидается, поэтому `check_api.py` даёт ему одну macOS-baseline,
не отдельную tvOS-пробу (`TVOS_PROBE` в `check_api.py` не менялся, всё ещё
относится к `TrellisUIKit`). `--matrix` строит/тестирует `TrellisFlux` на
iOS/tvOS destinations как часть `Trellis-Package` scheme — это подтверждает,
что зависимость реально резолвится и компилируется там, без второго baseline.

## Флейки, встреченные при сборе evidence (не от этой карточки)

`--matrix` — полный прогон `xcodebuild test` на macOS/iOS device/tvOS device/
iOS Simulator/tvOS Simulator — несколько раз ловил уже зарегистрированные
Simulator-load флейки, не связанные с TrellisFlux (diff показывает, что этот
код не трогает `TrellisRender`/`M06`/`M07`/`M12`):

| Тест | Платформа в этом прогоне | Дефект |
|---|---|---|
| `m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping` | macOS (`swift test`, несколько прогонов), iOS Simulator (один прогон), tvOS Simulator (один прогон) | [#60](../defects.md) |
| `m06_contentChangeInFlightClearsTheStaleBitmapWithoutDisturbingTheRunningGeometryAnimation` | iOS Simulator (один прогон) | новый, похож на класс #43/#52/#60 |
| `m07_displayReadyTracksARealTextRasterJobFromScheduledToCommitted` | tvOS Simulator (один прогон) | [#52](../defects.md) (ранее видели только на iOS Simulator) |

Для каждого — изолированный повтор того же шага (`--filter` для M12 три раза
подряд на macOS; отдельный `xcodebuild test` только для iOS Simulator; отдельный
`xcodebuild test` только для tvOS Simulator) прошёл **чисто**, без единого
сбоя. Итоговый матричный прогон (`macOS universal`/`ios-device`/`tvos-device`/
`ios-simulator`/`tvos-simulator`) записан полностью зелёным. Обоснование: эти
тесты чувствительны к real-time CALayer presentation/raster timing под
нагрузкой хоста, когда рядом одновременно работают несколько xcodebuild/
simctl процессов (как было при первых прогонах этой карточки) — тот же класс,
что уже документируют #43 и #52 для других тестов на tvOS Simulator. `m06`
зарегистрирован здесь как наблюдение, отдельной строки в defects.md не заведено
(не воспроизвёлся повторно ни разу за несколько последующих прогонов).

## Открытые пункты

- Реактивные bindings (P6.2–P6.11: StateSubject-мост, эффекты, ScrollNode/списки)
  не реализованы — это R03 и далее.
- `TrellisFlux.fluxVersion` — статическая строка для смоук-проверки pin, не
  API для чтения версии в рантайме; не задумана как долгоживущий публичный
  контракт за пределами этой карточки.
- Известный флейк M12 (defects.md #60) остаётся открытым отдельно от этой карточки.
