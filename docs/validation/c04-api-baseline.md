# C04 — API baseline и внешний consumer

Дата: 2026-09-10. C04 реализована на текущем минимальном содержимом пакета
(`NodeID`, `LayerRegistry`, два `TrellisHostView`). Baseline фиксирует именно
этот срез API, а не финальную поверхность этапа — новые public/open
объявления следующих карточек будут расширять его обычным `--update`.

## Что добавлено

- `Scripts/check_api.py` переписан: вместо одного Weave/macOS baseline —
  список модулей, у каждого своя SDK и target triple.
- `api/TrellisCore.json`, `api/TrellisRender.json`, `api/TrellisAppKit.json` —
  сняты на `arm64-apple-macosx14.0` через `swift build` +
  `swift-symbolgraph-extract`, модули берутся из
  `.build/arm64-apple-macosx/debug/Modules`.
- `api/TrellisUIKit.json` — снят на `arm64-apple-ios16.0`. Модуль под UIKit
  не собирается на macOS SDK (`#if canImport(UIKit)` даёт пустой modul), для
  него нужен отдельный `xcodebuild -destination 'generic/platform=iOS'` c
  `-derivedDataPath` под `.build/api-derived-data/iOS`; extraction читает
  `Build/Products/Debug-iphoneos`.
- tvOS не получает отдельный baseline по умолчанию: `--tvos` собирает тот же
  `TrellisUIKit` под `generic/platform=tvOS` и сравнивает символы с
  `api/TrellisUIKit.json` после нормализации `platform`. При совпадении
  печатается PASS без создания файла; при расхождении требуется
  `--update --tvos --review-note <adr>`, создающий `api/TrellisUIKit.tvOS.json`.
  На снятом срезе (`UIView`-хост без UIKit/AppKit-специфичных API) поверхности
  iOS и tvOS совпали — второй файл не создан.
- Команды разделены: `check_api.py [--module NAME]` только сравнивает;
  `--update` пишет baseline и требует `--review-note` на существующий файл;
  при `removed`/`changed` имя review-note должно содержать `adr`
  (перенесено из Weave без изменений контракта).
- Внешний consumer публичного импорта — уже существующий
  `Scripts/verify_bootstrap.py::check_consumer` из C02/C03: отдельный
  локальный SwiftPM-пакет, `swift run` без `@testable`, использует
  `NodeID`, `LayerRegistry`, `TrellisHostView` (AppKit). C04 не создаёт
  второй consumer — расширять этот же после появления `Node`
  (subclass + DSL, C08/C21) более честно, чем городить временный второй.

## Ограничение снятого baseline

`Node` ещё не существует (C08), поэтому пункт карточки «дополнить consumer
subclass Node и DSL» технически невыполним в C04 и остаётся открытым до
соответствующих карточек M2/M5. Сохранённые здесь baseline описывают только
уже перенесённый минимальный API; они не заменяют собой ревью API следующих
карточек.

## Выполненные проверки

| Проверка | Результат |
|---|---|
| `python3 Scripts/check_api.py` (все 4 модуля) | PASS, baseline снят и сверен |
| `python3 Scripts/check_api.py --tvos` | PASS, tvOS-поверхность совпадает с iOS |
| `python3 Scripts/check_all.py` (с интеграцией `check_api.py`) | PASS |

Время: сборка iOS/tvOS через `xcodebuild generic/platform=...` — по ~35–40с
каждая на использованной машине; macOS-модули переиспользуют обычный
`swift build`. Полная xcodebuild-матрица C02/C03 (`--matrix`) не заменяется
этой проверкой и остаётся отдельным шагом.

Toolchain и SDK — те же пины `toolchain.json`, что и в C02/C03: Xcode 26.6
(17F113), Swift 6.3.3, macOS/iOS/tvOS SDK 26.5.

## Не засчитывается этим отчётом

Полноценный внешний consumer с subclass `Node` и DSL — после C08/C21–C22.
Node/layout/render-конвейер не существует, поэтому текущий API baseline
маленький и заведомо неполный.
