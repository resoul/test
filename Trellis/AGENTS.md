# Правила работы в Trellis

## Прежде чем править код

1. [docs/decisions.md](docs/decisions.md) — принятые контракты. Они не
   пересматриваются по ходу задачи; расхождение с решением — повод остановиться
   и обсудить, а не повод «сделать как удобнее здесь».
2. План по префиксу карточки: C/F — [план 1](docs/implementation-plan.md),
   H — [план 2](docs/implementation-plan-2.md), A — [план 3](docs/implementation-plan-3.md),
   T — [план 4](docs/implementation-plan-4.md), M — [план 5](docs/implementation-plan-5.md),
   R — [план 6](docs/implementation-plan-6.md). Прочитать карточку, её зависимости,
   чек-лист, приёмку и evidence. Предложения P6 не становятся D-решениями автоматически.
   У карточек C05–C20 две приёмки:
   «срез» и «полная». Минимальная не закрывает карточку.
3. [docs/weave-analysis.md](docs/weave-analysis.md) — что и откуда
   переносится, какие в источнике известные дефекты.

## Ориентация в дереве

Минимальный пакет появился в C02; проверки политики и сборки — в C03.
Полный Node/layout/render-конвейер появляется в следующих карточках.

```
Sources/TrellisCore    Node, LayoutStyle, снимок, flex, планировщик, Log
                      импорты: только Foundation
Sources/TrellisRender  RenderCoordinator, LayerRenderer, NodeHostBridge
                      импорты: QuartzCore, CoreGraphics — НЕ UIKit, НЕ AppKit
Sources/TrellisCore/Semantics, Focus  metadata, SemanticSnapshot, AccessibilityTree, FocusEngine
Sources/TrellisUIKit   UIView-обвязка. iOS, iPadOS, tvOS; NativeProxies — focus items + VoiceOver
Sources/TrellisAppKit  NSView-обвязка. macOS; AccessibilityElements — NSAccessibilityElement
Playground/           приложения для проверки на устройствах
Scripts/              линтер политики, API baseline, проверка сборки
```

Рендерер — **один и платформо-нейтральный**. В Weave два платформенных
рендерера по 506 строк расходились друг с другом и различались одной строкой;
повторять это не надо. Если для правки требуется UIKit или AppKit в
`TrellisRender` — значит правка не там.

Текст в `TrellisRender` — `CoreTextRenderer`/`CoreTextTypesetter`
(`Sources/TrellisRender/Text/`): CoreText приходит через `CoreGraphics`
(разрешённый импорт), не через UIKit/AppKit — тот же платформо-нейтральный
рендерер, не третий движок. Измерение и рисование обязаны идти через одну
`makeAttributedString` (см. дефект #37 в defects.md — расхождение
измерения/рисования); `PortableFallbackMeasurer` (`TrellisCore`) — не
типографика, только headless-заглушка для тестов `TrellisCore` без
`TrellisRender`. `TextRendererKey`/`LocaleKey`/`ThemeKey` — environment-ключи
(`Node.setEnvironment`/`EnvironmentScope`), которые `TrellisAppKit`/
`TrellisUIKit`'s `TrellisHostView.attach(root:)` выставляет на корне сам;
правка, которая добавляет новый способ получить `TextRenderer`/locale/theme
в узел, должна идти тем же путём, не отдельным параметром на `TextNode`.

## Обязательные правила

**Изоляция.** Дерево нод и нативные объекты — `@MainActor`. В фоновые задачи
уходят только иммутабельные `Sendable`-снимки. `@unchecked Sendable`,
`nonisolated(unsafe)` и `@preconcurrency` запрещены — не как стиль, а потому
что вся модель актуальности результата держится на этой границе.

**Платформа.** UIKit/AppKit/Cocoa/SwiftUI/Metal — только в `TrellisUIKit` и
`TrellisAppKit`, под узким `#if canImport(...)` в самих файлах хостов. В общем
коде платформенных веток нет. `#if os(...)` запрещён везде — платформенное
поведение внутри адаптера выбирается по runtime-признаку
(`traitCollection.userInterfaceIdiom == .tv`). Native focus/AX-объекты
(`TrellisNodeProxy`, `TrellisAccessibilityElement`) хранят только `NodeID` и
никогда не читают live `Node` — значения приходят из опубликованного снимка.

**Владение и отмена.** У каждой задачи и подписки есть владелец, точка отмены и
детерминированный тест. Отменённая работа не коммитится: внутренний контракт
солвера — `throws -> LayoutResult`, пустой или частичный результат отменой не
является (D09).

**Документация публичного API.** Каждое `public`/`open` объявление несёт
секции `Ownership:`, `Isolation:`, `Errors:`, `Cancellation:`. Это проверяет
линтер, и это причина, по которой код остаётся читаемым через месяцы.

**Диагностика.** Печать — через `Log.on(_:_:)`, не через голый `print`. Иначе
перестают работать области и `TRELLIS_LOG`. В строке конвейера всегда есть
`hostID`/`gen` и `#id` ноды: вывод фонового солвера и MainActor перемешивается,
и без них лог на устройстве нечитаем.

**Именование.** Публичные имена короткие: `Node`, `LayoutStyle`, `Arrangement`.
Брендового префикса у типов нет — бренд живёт в именах модулей.
`LayoutContext` — контекст исполнения солвера, и ничто другое (D10).

## Формат и стиль

Форматирование — `swift-format` с `.swift-format` в корне. Единственное отличие
от конфига Weave: **`lineBreakBeforeEachArgument: true`**. При переносе строки
каждый аргумент уходит на свою строку, а закрывающая скобка — на отдельную:

```swift
let request = HostRenderRequest(
    hostID: hostID,
    generation: nextGeneration,
    treeRevision: root.layoutRevision,
    bounds: bounds,
    scale: scale
)
```

Это заметно на инициализаторах с многими параметрами, которых здесь много
(`LayoutStyle` — 23 поля, `LayoutInputSnapshot` — 7). Настройка срабатывает
только когда вызов не помещается в `lineLength: 100`; короткие вызовы остаются
в одну строку.

### Пустые строки

`maximumBlankLines: 1` и `respectsExistingLineBreaks: true` означают, что
одиночные пустые строки внутри функции **сохраняются как написаны**: формат
их не добавляет и не удаляет, только сжимает две и более до одной. Проверено
прогоном `swift-format format` и `lint` на обоих вариантах. Значит расстановка
пустых строк — ответственность автора, а не инструмента.

**1. `guard` отделяется пустой строкой от следующего `if`.** `guard` защищает и
прерывает поток, `if` начинает новую ветку действий — это два разных
намерения, и их не надо склеивать.

```swift
guard let placement = result.placement(for: node.id) else { return }

if placement.frame.width > 0 {
    …
}
```

Это машинно проверяемое правило — `GUARD_IF_BLANK_LINE` в `check_policy.py`.
Замер по 21.5k строк Weave: 30 нарушений в 18 файлах, то есть кодовая база
почти везде уже так и написана.

Обычный оператор после `guard` пустой строки **не требует** — там поток
продолжается, а не ветвится. Обобщённый вариант правила («guard отделяется от
всего») замерен на Weave и даёт 456 попаданий: это не то правило, которое
здесь действует.

**2. `return` отделяется пустой строкой, если перед ним закрывается
многострочный составной блок** — `if`/`for`/`while`/`switch`/`do`. После
такого блока `return` — это результат функции, а не следующая строка внутри
логики.

```swift
switch phase {
case .began: state = .active
default: break
}

return .ignored
```

Это **конвенция, а не правило линтера**, и намеренно. Машинно проверяемая
формулировка («`return` после любой закрывающей `}` многострочного блока»)
даёт на Weave 84 попадания, и при просмотре часть из них — нормальный код:
например `return` сразу после `guard … else { throw }`. «Составной» и
«сложный» — суждение автора; линтер, который срабатывает 84 раза на твоём же
идиоматичном коде, навязывает не это правило, а более строгое. Поэтому пункт
живёт здесь и проверяется на ревью.

## Перенос из Weave

- Weave **не изменяется** ради Trellis. Нужная там правка записывается в
  [docs/source-provenance.md](docs/source-provenance.md), а не вносится в
  источник.
- Строка в таблице источников добавляется в том же коммите, что и файл.
  Отдельного прохода по документации в конце не будет.
- Перенесённые тесты раскладки сохраняют прежние ожидания. Изменение
  математики оформляется отдельным bugfix с воспроизведением; изменение
  управления отменой математикой не считается.
- Код из `old/Texture` не копируется. Texture — справочник, см.
  `docs/source-provenance.md` §3.2.

## Проверки

`python3 Scripts/check_all.py` — обычный прогон: policy, фикстуры, toolchain,
swift-format, сборка, Swift-тесты, внешний consumer, API baseline
(`Scripts/check_api.py --tvos`) и `TRELLIS_LOG` в реальном процессе
(`Scripts/check_log_env.py`). `--matrix` дополнительно собирает macOS
arm64/x86_64 и iOS/tvOS device destinations (build-only — нет подключённого
устройства) и реально запускает (`xcodebuild test`) весь набор тестов на
конкретном iOS и tvOS Simulator нужной SDK (C27) — не только сборку. UIKit-тесты
(`Tests/TrellisRenderTests/UIKit*.swift`, под `canImport(UIKit)`) выполняются только
там — на macOS `TrellisUIKit` пустой модуль; карточка, меняющая адаптер UIKit, не
закрыта без прогона на Simulator. `--skip-api`
пропускает API baseline, если под рукой нет iOS/tvOS SDK для `xcodebuild`.
API baseline снят отдельно на SDK каждой платформы (`api/*.json`); обновление
baseline — отдельная команда `check_api.py --update --review-note <файл>`,
не совмещённая с обычной проверкой. Подробности правил и ограничения
лексического анализа — в `policy.json`.

Диагностика — `Log.on(_:_:host:generation:node:parent:_:)` из
`Sources/TrellisCore/Log.swift`, не голый `print`. Формат строки одинаков
для всех областей: `[trellis.<area>] <event> host=<h> gen=<g> #<node>
parent=#<parent> <details>`; отсутствующее значение печатается как `none`,
а не опускается — позиция поля должна быть одной и той же независимо от
того, что известно на момент вызова. `host`/`generation` — явные параметры,
не глобальная «текущая генерация»: у двух хостов generation может совпасть.
Перед сдачей карточки — приёмка из её текста, а не «зелёная сборка».

Проверка на симуляторе не выдаётся за проверку на устройстве. Недоступное
устройство отмечается «нет доступа», а не «пройдено».

## Отчётность

Незакрытые пункты называются незакрытыми. Если часть карточки не сделана —
это пишется явно, вместе с причиной. Приёмка «срез» отмечается как срез, а не
как выполненная карточка.

Каждый найденный дефект — строка в [docs/defects.md](docs/defects.md) в момент
обнаружения, до исправления: компонент, что было не так, как найден, статус.
Исправление дописывает коммит; неисправленное остаётся «открыт» с карточкой,
где закрыть. Отчёт карточки ссылается на реестр, а не пересказывает его.
