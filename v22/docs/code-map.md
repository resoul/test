# Карта кода v22 → документы

Здесь — связь между кодом и документами проектирования, которая **не пишется в
комментариях кода** ([AGENTS.md](../AGENTS.md#комментарии-в-коде)). Когда документы
удаляются, этот файл удаляется вместе с ними.

Формат строки: где в коде — что там сделано — на каком документе, решении или дефекте это
основано.

## `Sources/LayoutCore/FlexboxEngine.swift`

| Код | Что | Основание |
|---|---|---|
| `FlexboxEngine.layout(_:size:context:)` | корень получает frame хоста, раскладка всего дерева | [10-layout-engine.md](10-layout-engine.md#вход-и-выход); Trellis D13 (bounds хоста у корня) |
| `FlexboxEngine.measure(_:width:height:context:)` | размер дерева без внешнего размера — для `sizeThatFits`/`intrinsicContentSize` | [05-platform-adapters.md](05-platform-adapters.md#что-адаптер-обязан-закрыть) |
| `Solver.cache` / `MeasureKey` | кэш измерений на один проход, без предела | Trellis ADR 0007, дефект #13 |
| `Solver.compute(..., contentOnly:)` | размер содержимого без собственных `width`/`height` узла | CSS §4.5 (content size suggestion); закрывает Trellis #101 |
| `clamp(_:_:_:_:)` | min побеждает max; не меньше padding | закрывает Trellis #100; решение border-box — [10](10-layout-engine.md#как-ведётся-работа), п. 3 |
| `DefiniteAxes`, `OwnSize.definiteWidth/Height` | ширина definite, как только известна; высота — по §9.8 | дефекты #109, #113 |
| `Axis`, `compute(..., contentOnly:)` | размер содержимого по одной оси | дефекты #110, #115 |
| `leafSize` / `ratioDependent` | пропорция: перенос min/max, автоминимум по зависимой оси | дефект #112 |

## `Sources/LayoutCore/LayoutNode.swift`

| Код | Что | Основание |
|---|---|---|
| `LayoutID` | непрозрачный id, сопоставляет адаптер | [10](10-layout-engine.md#вход-и-выход): модуль не знает про ноды |
| `LayoutResult.duplicateIDs` | дубликаты id — диагностика в результате | Trellis weave-analysis §3.1; AGENTS.md v22 «Печать» |
| `LayoutContext` / `LayoutCancelled` | отмена через `throws`, без частичного результата | Trellis D09, D10 |
| `LayoutContext.checkpoint()` и вызовы в `flexLayout` (каждый контейнер, каждые 256 item) | точки отмены | Trellis D09, дефект #16 |

## `Sources/LayoutCore/LeafContent.swift`

| Код | Что | Основание |
|---|---|---|
| `ContentMeasurer` | min-/max-content ширина и высота при ширине | [10](10-layout-engine.md#статус-e2-текст); три запроса к листу — [10](10-layout-engine.md#ключевые-структуры) |
| `LeafContent.size(knownWidth:available:)` | ширина по ограничению, высота при ней | [10](10-layout-engine.md#статус-e2-текст) |

## `Sources/LayoutCore/DSL`, `Sources/LayoutUIKit`, `Sources/LayoutAppKit`

| Код | Что | Основание |
|---|---|---|
| `LayoutSpec`, `FlexContainer`, `LayoutBuilder` | DSL | [03](03-layout-api.md), [04](04-conditionals-and-responsive.md) |
| `padding` на элементе — обёртка `init(insetting:)` | порядок модификаторов как в SwiftUI | [03](03-layout-api.md#метод-раскладки) |
| `apply(in:direction:scale:spacing:)` | привязка краёв к пикселям, шкала отступов | [05](05-platform-adapters.md#что-адаптер-обязан-закрыть), [09](09-theme.md) |
| `StylePatch`, `resolvedStyle(_:)`, `from:` у модификаторов | правки по порядку, варианты по ширине | [04](04-conditionals-and-responsive.md#6-адаптивные-значения--смена-параметра-по-размеру) |
| `LayoutTree`, `.alternatives` | `Breakpoint`: обе ветки в списке родителя, каждая видна по свою сторону порога | [04](04-conditionals-and-responsive.md#5-breakpoint--смена-структуры-по-размеру) |
| `hidden`, `invisible`, `applyLayoutVisibility` | видимость | [04](04-conditionals-and-responsive.md#3-видимость) |
| `Tokens.swift` | `Spacing`, `SpacingScale`, `BreakpointWidth` | [09](09-theme.md), [04](04-conditionals-and-responsive.md#именованные-пороги) |
| `Display`, `StyleVariant`, `Solver.style(_:parentWidth:)` | движок: `display: none`, выбор варианта по ширине родителя | [10](10-layout-engine.md#этапы) (E4) |
| `UIView`/`NSView: LayoutElement`, `ViewMeasurer` | измерение view | [05](05-platform-adapters.md#что-адаптер-обязан-закрыть) |
| `LayoutView`, `LayoutNSView`, `applyLayoutSpec()` | базовые классы и протокол с одной строкой | [05](05-platform-adapters.md#как-вызывается-раскладка) |
| `NSView.applyLayoutFrame` — отражение y | неперевёрнутый родитель | [05](05-platform-adapters.md#что-адаптер-обязан-закрыть) |

## `Sources/LayoutCore/FlexStyle.swift`

| Код | Что | Основание |
|---|---|---|
| `FlexStyle` целиком | поля и значения по умолчанию как в CSS | [06-flexbox-conformance.md](06-flexbox-conformance.md#цель) |
| `Length` (не `Dimension`) | имя: `Dimension` занят в Foundation | [07-naming.md](07-naming.md#прочие-имена) |
| `Length.fraction` | доля, `0.5` = 50 % | [03-layout-api.md](03-layout-api.md) (пример `.percent(0.5)`), [07](07-naming.md#прочие-имена) |
| `Margin.auto` | auto-margin | закрывает `unsupported` Trellis (`margin: auto`) |
| `FlexStyle.order` | CSS `order` | закрывает `unsupported` Trellis (`order`) |
| `Edges` (leading/trailing) | логические стороны, как в Trellis | [03](03-layout-api.md) |

## `Sources/LayoutCore/FlexAlgorithm.swift`

| Код | Что | Основание |
|---|---|---|
| `ContainerAxes.reversedMain/reversedCross` | логические координаты до самого конца | закрывает Trellis #102 (`wrap-reverse`) |
| `FlexItem.marginMainStart…`, `outerHypotheticalMain`, `outerTarget` | внешний размер = размер + margin во всех шагах | закрывает Trellis #95, #96 |
| `makeItem` — `crossForBasis` | stretch-размер definite до main-размера | CSS §9.8; закрывает Trellis #106 (aspect-ratio при stretch) |
| `makeItem` — автоматический минимальный размер | `min-width: auto` | CSS §4.5; закрывает Trellis #101 |
| `resolveFlexibleLengths` | цикл заморозки, сумма факторов < 1 | CSS §9.7; закрывает Trellis #98, #99 |
| `flexLayout` — intrinsic row (`rawContribution`, `plainContribution`, `flexedContribution`) | собственная ширина row по вкладам детей, как в Blink | дефект #111 |
| `flexLayout` — `wrap` без переноса при неизвестной ширине column | ширина column-wrap по самому широкому элементу | дефект #116 |
| `flexLayout` — пропорция без размеров | ширина по содержимому, высота из пропорции | дефект #115 |
| `FlexItem.stretches`, `mainIsDefinite` | stretch только при `auto`; definite после flex | дефекты #108, #114 |
| `flexLayout` — used cross size | stretch минус cross-margin, затем min/max | закрывает Trellis #96, #97 |
| `flexLayout` — fit-content ветка inner main | контейнер без размера в definite-пространстве | [10](10-layout-engine.md#что-пишется-заново-алгоритм-по-шагам-css-9) |
| `alignMain` | auto-margin, затем `justify-content`, курсор с margin | закрывает Trellis #95 и `unsupported` `margin: auto` |
| `distribute` | safe-fallback к началу по направлению письма | CSS Box Alignment §5.1; дефект #107 |

## `Sources/LayoutCore/AbsoluteLayout.swift`

| Код | Что | Основание |
|---|---|---|
| `layoutAbsoluteChildren` — containing block = padding box | | закрывает Trellis #104 |
| растяжение между `leading`+`trailing` / `top`+`bottom` | | закрывает Trellis #103 |
| `absoluteStaticPosition` | статическая позиция по `justify-content`/`align-self` | CSS §4.1; закрывает Trellis #105; дефект #117 |
| auto-margin при обоих отступах, RTL при переопределении, `heightIsDefinite` | | дефект #117 |

## `Tests/LayoutCoreTests`

| Код | Что | Основание |
|---|---|---|
| `CSSConformanceTests` | сравнение с Chromium, baseline `expectations/engine.json` | [06](06-flexbox-conformance.md), [10](10-layout-engine.md#как-ведётся-работа) |
| `EngineContractTests` | отмена, дубликаты, `measure` | Trellis D09; [10](10-layout-engine.md#этапы) |

## `Package.swift`

| Код | Что | Основание |
|---|---|---|
| отдельный пакет | не затрагивает Trellis | [10](10-layout-engine.md#решено) |
| модуль `LayoutCore` (не `Layout`) | `Layout` — протокол SwiftUI | [02-modules.md](02-modules.md), [07](07-naming.md#прочие-имена) |
