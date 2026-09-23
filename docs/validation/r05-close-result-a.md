# R05 — Закрыть результат A

Дата: 2026-09-14. Карточка [implementation-plan-6.md](../implementation-plan-6.md)
§5, R05. Зависимость: R04. Закрывает результат A (R01–R05) плана 6.

## `check_policy.py`: 0 diagnostics, документация вместе с API

`python3 Scripts/check_policy.py` — 0 diagnostics на всём дереве, включая
`EffectOwner`/`Conflict` (R04) и `TrellisHostView.hostBridge` (новое в этой
карточке, оба платформы) — каждое новое public/open объявление документировано
Ownership/Isolation/Errors/Cancellation вместе с самим API, не отложено.

## Внешний consumer: фильтр кнопками, задержанные результаты, retry и анимация

`Playground/Shared/Scenarios/S32_FluxFilterFeed.swift` — новая сцена: три кнопки
фильтра (All/Even/Odd, обычные `ControlNode`, без text-input), реальная
задержка (`Task.sleep`, 700 мс), гарантированный один сбой на "Even" с
восстановлением через Retry, список результатов — всё через настоящий
`NodeHostBridge.bindFlux`/`EffectOwner`/Flux `CurrentValue` (R02–R04), не через
операторы в unit-тестах. Подключена через новый `TrellisHostView.hostBridge`
(единственный способ достать мост для `bindFlux`, поскольку
`TrellisAppKit`/`TrellisUIKit` не могут зависеть от `TrellisFlux` — R02's
dependency policy). Полное обоснование — [ADR 0024](../adr/0024-host-view-hostbridge-escape-hatch.md),
[ADR 0025](../adr/0025-flux-external-consumer-scene.md).

Дублирующий автоматический уровень (не полагаться только на ручной клик):
`Tests/TrellisFluxTests/ExternalConsumerFeedTests.swift` — та же форма модели
и экрана, но с реальным временем (`Task.sleep`, не управляемые continuation),
настоящим `ControlNode`, активированным через настоящий
`PointerSessions`/hit-test pipeline (не прямой вызов метода) — 5 тестов:
initial→filtered (с анимацией), тап по кнопке, retry после гарантированного
сбоя, отмена устаревшего запроса при быстрой смене фильтра (R04's "запрос A
завершается после B" на реальной модели), отсутствие утечек.

## C29 regression, memory/cancellation

Полный `swift test` (730 тестов) — включает все существующие C29
(`StateBindingTests.swift`) регрессии без изменений; TrellisRender/TrellisCore
не тронуты этой карточкой. Memory/cancellation — покрыто и R03/R04's тестами
(`FluxStateBindingTests`, `EffectOwnerTests`, weak-ссылки), и новыми
`ExternalConsumerFeedTests`'s `test_externalConsumer_
cancelReleasesTheModelAndScreenNoLeaks`.

## Найденный дефект #61 (не блокирует карточку)

При подготовке screenshot-эталона для S32: слово «Odd» в auto-width `TextNode`
обрезалось многоточием до «O…» **на macOS** (scale 2) независимо от того,
насколько широк контейнер (проверено вплоть до 140pt) — специфично именно для
этой строки: «XYZ» и «odd» (нижний регистр) в той же позиции рендерились
полностью. Та же семья дефектов, что #37/#47/#48 (measure/rasterize
расхождение для auto-width текста), но впервые на macOS, а не только iOS
Simulator (#48 явно НЕ воспроизводился на macOS). Обойдено тем же способом,
что #48: явная `TextNode.style.width` с запасом. Зарегистрировано как #61,
открыто, не диагностировано до точной причины.

## Проверки

| Проверка | Результат |
|---|---|
| `swift build` | чисто, `-warnings-as-errors` |
| `xcrun swift-format lint --strict` | чисто (после форматирования новых test-файлов) |
| `swift test` (весь пакет) | 730/730 тестов зелёные |
| `python3 Scripts/check_policy.py` | 0 diagnostics |
| `Scripts/check_api.py` (все 5 модулей + `--tvos`) | PASS; `TrellisAppKit` 47 (+1 `hostBridge`), `TrellisUIKit` 51 (+1 `hostBridge`), `TrellisFlux` 15 — не изменился этой карточкой |
| `Scripts/check_screenshots.py` | PASS, 64 эталона (63 сцены × 2 включая overlay); 62 существующих не изменились, S32 — новый принятый эталон |
| `Scripts/verify_bootstrap.py --matrix` | PASS: macOS universal, iOS device, tvOS device, iOS Simulator (`consumer`/`tests`/`library-build` все зелёные) |

### Матрица и известные флейки (не от этой карточки)

Итоговый прогон `--matrix` прошёл полностью зелёным. По пути (несколько
прогонов, собирая evidence) дважды встретился уже задокументированный флейк
`m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping`
(#60, macOS и iOS Simulator) и один раз — новый флейк того же класса,
`m06_contentChangeInFlightClearsTheStaleBitmapWithoutDisturbingTheRunningGeometryAnimation`
(зарегистрирован как #62, ранее уже замечен в R02 без отдельной записи). Ни
один не воспроизводился дважды подряд в изоляции; ни тот, ни другой не
относятся к коду, который меняет эта карточка (`TrellisFlux`/`hostBridge`/S32
не касаются `TransitionSession`/`TransitionGestureController`/M06's raster
пути). tvOS Simulator для этой карточки отдельно не прогонялся — код
platform-neutral (не касается UIKit/AppKit специфики), полная матрица уже
подтверждена в R02.

## Приёмка

Рабочая Flux-интеграция подтверждена на всех уровнях: примитивы (R02–R04's
unit-тесты на fake API), автоматический consumer-уровень
(`ExternalConsumerFeedTests`, реальное время), и ручной/визуальный уровень
(Playground S32, реальный `ControlNode`/`NodeHostBridge`/раскладка/рендер).
Результат A (R01–R05) закрыт.
