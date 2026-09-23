# ADR 0025 — S32 external consumer scene + screenshot baseline

Дата: 2026-09-14. Карточка R05 (`docs/implementation-plan-6.md`, закрытие результата A).
Зависимость: R04, ADR 0024.

## Изменение

`Playground/Shared/Scenarios/S32_FluxFilterFeed.swift` — новая сцена: три кнопки
фильтра (All/Even/Odd), реальная имитация сети (`Task.sleep`, 700 мс),
гарантированный один сбой на "Even" с восстановлением через Retry, список
результатов, всё поверх настоящего `NodeHostBridge.bindFlux`/`EffectOwner`/Flux
`CurrentValue`. `docs/validation/screenshots/macOS/S32_FluxFilterFeed{,_overlay}.png`
— новый эталон (63-я сцена; ни один из 62 существующих не изменился).

## Почему это внешний consumer, а не ещё один unit-тест

R05's приёмка буквально требует "рабочую Flux-интеграцию, не только операторы в
unit tests". `Tests/TrellisFluxTests/EffectOwnerTests.swift`/
`FluxStateBindingTests.swift` (R03/R04) проверяют примитивы управляемым fake
service — этого достаточно для их собственных карточек, но не показывает, что
итоговая связка реально работает в дереве узлов с настоящими `ControlNode`,
раскладкой и рендером. S32 — именно это дерево: обычная Playground-сцена,
подключаемая через `TrellisHostView.hostBridge` (ADR 0024), без специального
тестового окружения.

## Почему ещё и дублирующий набор автотестов (`ExternalConsumerFeedTests.swift`)

Playground-сцены в этом кодбейсе не имеют собственного юнит-теста — они
проверяются вручную/скриншотами (`check_screenshots.py`), как и все остальные
S01–S31. Но R05 также явно требует "C29 regression, memory/cancellation" —
воспроизводимую, а не разовую проверку. `Tests/TrellisFluxTests/
ExternalConsumerFeedTests.swift` — та же форма модели/экрана (фильтры, реальная
задержка `Task.sleep`, один гарантированный сбой, retry, реальный `ControlNode`,
активированный через настоящий `PointerSessions`-пайплайн — не прямой вызов
метода), но как автоматический, повторяемый тест с настоящим временем, а не
управляемыми continuation-ами (`EffectOwnerTests.swift`'s стиль). Это не
дублирует R03/R04's тесты примитивов — это отдельный уровень: "весь стек вместе,
с реальным временем", соответствующий тому же самому дереву кода, что и S32.

## Найденное при подготовке evidence

**Дефект #61** (`docs/defects.md`): слово «Odd» в auto-width `TextNode` внутри
`Row(align: .center)` обрезалось многоточием на macOS (та же платформа, где #48
явно НЕ воспроизводился), независимо от того, насколько широк контейнер —
подтверждено A/B с «XYZ»/«odd» (нижний регистр), которые не обрезались в той же
позиции/весе/размере. Обойдено тем же способом, что #48: явная `TextNode.style.
width` с запасом вместо auto-width. Дефект остаётся открытым — не диагностирован
до точной причины, не эта карточка.

**Ownership.hostBridge** (ADR 0024, тот же коммит): единственный способ достать
`NodeHostBridge` из `TrellisHostView` для вызова `bindFlux` — новый public
accessor на `TrellisAppKit`/`TrellisUIKit`, без зависимости этих модулей от
`TrellisFlux`.

## Решение

Baseline обновлён через `check_screenshots.py --update --review-note
docs/adr/0025-flux-external-consumer-scene.md`.
