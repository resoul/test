# Карта кода Espalier → документы

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
| `SolveStatistics`, `LayoutResult.statistics` | счётчики работы прохода для тестов | [10](10-layout-engine.md#статус-e3-производительность) |
| `FlatNode.dependsOnParent`, `FlexStyle.hasPercentageSize` | размер родителя в ключе кэша только когда влияет | дефект #125 |
| `MeasureKey.hash(into:)`, `HashMix` | хэш ключа — одно слово | [10](10-layout-engine.md#статус-e3-производительность) |
| `@inline(never)` у шагов и помощников | кадры шагов не лежат на стеке при рекурсии | дефект #124 |
| `Solver.baseline(_:size:parent:)`, `wantsBaseline`/`lastBaseline` | базовая линия узла при заданном размере; контейнер отдаёт её из того же прохода | CSS §8.5; [10](10-layout-engine.md#статус-e2-текст) |
| `leafSize` / `ratioDependent` | пропорция: перенос min/max и вертикального padding, автоминимум по зависимой оси (ширина — min-content; высота — только при `height: auto`) | дефекты #112, #144, #152 |

## `Sources/LayoutCore/LayoutNode.swift`

| Код | Что | Основание |
|---|---|---|
| `LayoutID` | непрозрачный id, сопоставляет адаптер | [10](10-layout-engine.md#вход-и-выход): модуль не знает про ноды |
| `LayoutResult.duplicateIDs` | дубликаты id — диагностика в результате | Trellis weave-analysis §3.1; AGENTS.md Espalier «Печать» |
| `LayoutNode.dismantle`, `LayoutTreeOwner`, `PreparedLayout.tree` | глубокое дерево освобождается по уровню за раз | дефект #140 |
| `LayoutContext` / `LayoutCancelled` | отмена через `throws`, без частичного результата | Trellis D09, D10 |
| `LayoutContext.stackBudget`, `currentThreadStackBudget`, `LayoutStackExhausted`, `Solver.checkStack`/`stackAddress`, проверка в `flatten` и `flexLayout` | бюджет стека вместо падения | дефект #124; [10](10-layout-engine.md#статус-e3-производительность) |
| `LayoutContext.checkpoint()` и вызовы в `flexLayout` (каждый контейнер, каждые 256 item) | точки отмены | Trellis D09, дефект #16 |
| `LayoutResult.variantsWithoutWidth`, `Solver.variantsWithoutWidth` (`NodeSet`), запись в `Solver.style` | вариант выбран без определённой ширины | [04](04-conditionals-and-responsive.md#5-breakpoint--смена-структуры-по-размеру), [10](10-layout-engine.md#диагностика) |

## `Sources/LayoutCore/LayoutTrace.swift`

| Код | Что | Основание |
|---|---|---|
| `LayoutTraceRequest`, `LayoutTraceEvent`, `LayoutContext.trace`, `LayoutResult.trace`, `Solver.traceMeasure` | трассировка — значение в результате, не объект | [10](10-layout-engine.md#диагностика): решение 2026-09-25 (нет `Mutex` на macOS 14) |

## `Sources/LayoutCore/LeafContent.swift`

| Код | Что | Основание |
|---|---|---|
| `ContentMeasurer` | min-/max-content ширина и высота при ширине | [10](10-layout-engine.md#статус-e2-текст); три запроса к листу — [10](10-layout-engine.md#ключевые-структуры) |
| `LeafContent.size(knownWidth:available:)` | ширина по ограничению, высота при ней | [10](10-layout-engine.md#статус-e2-текст) |
| `LeafContent.minContentWidth` | автоминимум ширины листа с пропорцией | дефект #144 |
| `LeafContent.proportional`, `naturalRatio`, `isProportional` | содержимое с собственным размером и пропорцией, как картинка (заменяемый элемент CSS) | дефект #157; [11](11-image.md) |
| `FlexboxEngine.style(_:parentWidth:)` (собственная пропорция), `leafSize` (`automaticMinimum`) | пропорция содержимого как `aspect-ratio: auto`; сторона по пропорции без минимума по содержимому (CSS Sizing 4 §5.2.1 — только незаменяемые) | дефект #157 |
| `BoxRatio`, `FlexboxEngine.boxRatio`, `FlexStyle.aspectRatioIsContentBox`; все переносы через пропорцию (`leafSize`, `ownSize`, `ratioLayout`, `ratioContent`, flex-база `FlexItem.ratio`) | собственная пропорция — по области содержимого, из стиля — по рамке | дефект #169; CSS Sizing 4 §5 (`aspect-ratio: auto`) |
| `AbsoluteLayout` — `stretches` | пропорциональное содержимое не растягивается между отступами | дефект #171; CSS Position 3 §4 |
| `ContentMeasurer.firstBaseline(forWidth:)`, `LeafContent.baseline(width:)` | первая базовая линия листа; без неё — низ содержимого | [10](10-layout-engine.md#статус-e2-текст) |

## `Sources/LayoutCore/DSL`, `Sources/LayoutUIKit`, `Sources/LayoutAppKit`

| Код | Что | Основание |
|---|---|---|
| `LayoutSpec`, `FlexContainer`, `LayoutBuilder` | DSL | [03](03-layout-api.md), [04](04-conditionals-and-responsive.md) |
| `padding` на элементе — обёртка `init(insetting:)` | порядок модификаторов как в SwiftUI | [03](03-layout-api.md#метод-раскладки) |
| `apply(in:direction:scale:spacing:)` | привязка краёв к пикселям, шкала отступов | [05](05-platform-adapters.md#что-адаптер-обязан-закрыть), [09](09-theme.md) |
| `StylePatch`, `resolvedStyle(_:)`, `from:` у модификаторов | правки по порядку, варианты по ширине | [04](04-conditionals-and-responsive.md#6-адаптивные-значения--смена-параметра-по-размеру) |
| `LayoutTree.nodes(for:place:)`, `Frame`, `visit`, `finish` | сборка спеки явным стеком, в порядке рекурсии | дефект #139 |
| `LayoutTree`, `.alternatives` | `Breakpoint`: обе ветки в списке родителя, каждая видна по свою сторону порога | [04](04-conditionals-and-responsive.md#5-breakpoint--смена-структуры-по-размеру) |
| `hidden`, `invisible`, `applyLayoutVisibility` | видимость | [04](04-conditionals-and-responsive.md#3-видимость) |
| `PreparedLayout.elementsPlacedMoreThanOnce(in:)` | кадр в двух местах — ошибка спеки | [03](03-layout-api.md#управление-subnodes): проход отклоняется |
| `PreparedLayout.element(for:)`, `ids(of:)`, `ids(where:)`, `LayoutTree.owners` | id движка ↔ элемент, контейнер ↔ его владелец | отчёт и трассировка по нодам |
| модификаторы с опциональным значением, `nil` — спека без изменений; `padding(top:…)` без сторон не оборачивает элемент | опционалы | [04](04-conditionals-and-responsive.md#4-условный-модификатор); дефект #137 |
| `if(_:_:)` | условный модификатор | [04](04-conditionals-and-responsive.md#4-условный-модификатор) |
| `collapsesWhenEmpty()` — `display: none` при пустом списке элементов | пустой контейнер | [04](04-conditionals-and-responsive.md#8-пустой-контейнер) |
| `Tokens.swift` | `Spacing`, `SpacingScale`, `BreakpointWidth` | [09](09-theme.md), [04](04-conditionals-and-responsive.md#именованные-пороги) |
| `Display`, `StyleVariant`, `Solver.style(_:parentWidth:)` | движок: `display: none`, выбор варианта по ширине родителя | [10](10-layout-engine.md#этапы) (E4) |
| `UIView`/`NSView: LayoutElement`, `ViewMeasurer` | измерение view | [05](05-platform-adapters.md#что-адаптер-обязан-закрыть) |
| `LayoutView`, `LayoutNSView`, `applyLayoutSpec()` | базовые классы и протокол с одной строкой | [05](05-platform-adapters.md#как-вызывается-раскладка) |
| `LayoutSpec.apply(…, reporting:)`, `LayoutSpecReporting`, `LayoutSpecReport`, `LayoutReportFormat`; `LayoutView.onLayoutReport`, `traceAreas`, `tracedElements`; `LayoutReportLog` | отчёт прохода спеки view — поля и строки как у нод; элемент в двух местах отклоняет проход | [10](10-layout-engine.md#диагностика) |
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
| `appendItem` — `crossForBasis` | stretch-размер definite до main-размера | CSS §9.8; закрывает Trellis #106 (aspect-ratio при stretch) |
| `appendItem` — автоматический минимальный размер | `min-width: auto` | CSS §4.5; закрывает Trellis #101 |
| `resolveFlexibleLengths` | цикл заморозки, сумма факторов < 1 | CSS §9.7; закрывает Trellis #98, #99 |
| `flexLayout` — intrinsic row (`rawContribution`, `plainContribution`, `flexedContribution`) | собственная ширина row по вкладам детей, как в Blink | дефект #111 |
| `beginContainer` — `wrap` без переноса под min-content шириной column | min-content ширина column-wrap — самый широкий элемент | дефекты #116, #145 |
| `flexLayout` — `lineLimit` | column рвёт линии по своей высоте, иначе `max-height`, иначе одна линия | дефект #145 |
| `placeLines` — `crossContent` | ширина column-wrap — линии рядом, fit-content в определённом месте | дефект #145 |
| `fitToLines` | элемент многолинейного column без stretch — ширина в своей линии | дефект #145 |
| `flexLayout` — пропорция без размеров (`ratioLayout`) | ширина по содержимому, высота из пропорции | дефект #115 |
| `ratioLayout` — автоматический минимум, `percentHeight` | зависимая сторона не ниже содержимого; проценты детей — от высоты пропорции | CSS Sizing 4 §5.2.1; дефекты #144, #152 |
| `ratioContent`, `RatioTransfer.definiteSize` | размер содержимого по оси: max(перенесённый, содержимое); содержимое — при высоте пропорции | дефект #144 |
| `hypotheticalCross` — пропорция в column без ширины | вклад по содержимому или от заданной высоты | дефекты #144, #152 |
| `crossSizes` — stretch по `crossForBasis` | растягиваемый элемент берёт высоту пропорции, пока своя не решена | дефект #144 |
| `flexLayout` — `FlatNode.sizesWidthFirst` | ширина до детей: проценты ширины детей, перенос row | дефекты #148, #151 |
| `layoutItems` — высота row-элемента с пропорцией | не передаётся: её выводит `ratioLayout` | дефект #152 |
| `FlexItem.stretches`, `mainIsDefinite` | stretch только при `auto`; definite после flex, в том числе при `flex-basis`-длине | дефекты #108, #114, #143 |
| `flexLayout` — used cross size | stretch минус cross-margin, затем min/max | закрывает Trellis #96, #97 |
| `flexLayout` — fit-content ветка inner main | контейнер без размера в definite-пространстве | [10](10-layout-engine.md#что-пишется-заново-алгоритм-по-шагам-css-9) |
| `alignMain` | auto-margin, затем `justify-content`, курсор с margin | закрывает Trellis #95 и `unsupported` `margin: auto` |
| `distribute` | safe-fallback к началу по направлению письма | CSS Box Alignment §5.1; дефект #107 |
| `ContainerRun`, `flexLayout` как последовательность шагов (`beginContainer`, `innerMainSize`, `crossSizes`, `placeLines`, `layoutItems`) | в кадре на уровень — только компактное состояние контейнера | дефект #124 |
| `appendItem` / `measureItem` | элемент собирается без рекурсии, замеры — в маленьком кадре | дефект #124 |
| `crossSizes` — растягиваемый элемент одной строки с известным cross | гипотетический cross не меряется | дефект #125 |
| `SizeRequest`, `defersMinimum`, `resolvePendingMinimums` | автоматический минимум — только при переполнении строки | CSS §4.5; дефект #125 |
| checkpoints в `crossSizes`, `layoutItems` (каждые 256) | задержка отмены на длинной строке | [10](10-layout-engine.md#статус-e3-производительность) |
| `flexLayout` — `FlexItem.baseline`, `FlexLine.ascent`, `crossOffset(_:lineCross:ascent:)` | выравнивание по базовой линии; column — синтезированная по краю; `wrap-reverse` — от низа | CSS §8.3, §9.4 шаг 8; дефекты #121, #122 |
| `containerBaseline` | базовая линия контейнера: физически верхняя строка; в `-reverse` — элемент с конца | CSS §8.5; дефекты #120, #147 |
| `placeLines` — ascent/descent от −∞ | базовая линия вне элемента | дефект #147 |

## `Sources/LayoutCore/AbsoluteLayout.swift`

| Код | Что | Основание |
|---|---|---|
| `layoutAbsoluteChildren` — containing block = padding box | | закрывает Trellis #104 |
| растяжение между `leading`+`trailing` / `top`+`bottom` | | закрывает Trellis #103 |
| `absoluteStaticPosition` | статическая позиция по `justify-content`/`align-self` | CSS §4.1; закрывает Trellis #105; дефект #117 |
| auto-margin при обоих отступах, RTL при переопределении, `heightIsDefinite` | | дефект #117 |
| `verticalAlignment`, сдвиг в containing block | `align-self` между `top` и `bottom` | CSS Align §5.1; дефекты #146, #150 |
| пропорция: ширина первой, `minContentWidth` | порядок Chromium для absolute с `aspect-ratio` | дефект #149 |
| `staticStart` | место без горизонтальных вставок — от статической позиции | дефект #150 |
| `absoluteStaticPosition` — `baseline` в `wrap-reverse` | начало письма | дефект #147 |

## `Tests/LayoutCoreTests`

| Код | Что | Основание |
|---|---|---|
| `cssFlexboxLab` (`CSS_CONFORMANCE_LAB`) | движок на произвольном файле кейсов — проверка уменьшенных деревьев | дефект #118 |
| `CSSConformanceTests` | сравнение с Chromium, baseline `expectations/engine.json` | [06](06-flexbox-conformance.md), [10](10-layout-engine.md#как-ведётся-работа) |
| `EngineContractTests` | отмена, дубликаты, `measure` | Trellis D09; [10](10-layout-engine.md#этапы) |

## `Package.swift`

| Код | Что | Основание |
|---|---|---|
| отдельный пакет | не затрагивает Trellis | [10](10-layout-engine.md#решено) |
| модуль `LayoutCore` (не `Layout`) | `Layout` — протокол SwiftUI | [02-modules.md](02-modules.md), [07](07-naming.md#прочие-имена) |

## `Sources/StateCore`

| Код | Что | Основание |
|---|---|---|
| модуль `StateCore` (не `State`) | модуль и тип с одним именем ломают квалификацию | [08](08-open-questions.md#состояние-и-реактивность), как `LayoutCore` |
| `Tracking`, `Reads`, `Dependents` | запись чтений с версиями; зависимые — слабые ссылки | [08](08-open-questions.md#состояние-и-реактивность): автоматическая подписка по чтению |
| `Computed.refresh` | «возможно изменилось» вниз сразу, проверка версий — лениво; равный результат не распространяется | там же |
| `Observer.track` — проверка после подписки | запись в прочитанное во время самого прогона | тест `aFlushOfObserversThatFeedEachOtherEnds` |
| `StateUpdates.flush`, `scheduler`, `roundLimit` | слияние записей до flush; flush «перед кадром» подставит слой нод | как D14 Trellis: burst → одна доставка |
| `StateTransaction` | «как выполнить запись» — чтобы адаптер писал с анимацией, не зная про `Nodes` | [08](08-open-questions.md#состояние-и-реактивность); реализует `Animation` в `Nodes` |

## `Sources/StateAsyncRay`

| Код | Что | Основание |
|---|---|---|
| `AsyncRay.bind(to:)` | значения потока → `State` на MainActor, состояние держится слабо | [08](08-open-questions.md#состояние-и-реактивность): AsyncRay — адаптер на границе |
| `AsyncRay.bind(to:animation:)` | то же, каждое значение — в своей `StateTransaction` (анимации) | аналог `bindFlux(animation:)` Trellis |
| `State.asyncRay` | текущее значение, затем значения после flush; `bufferingNewest(1)` | состояние — последнее значение, не события |
| `Watch` | остановка, пришедшая раньше старта, побеждает | порядок двух задач MainActor не обещан |

## Встраивание раскладки (`LayoutCore/DSL`)

| Код | Что | Основание |
|---|---|---|
| `LayoutElement.embeddedLayout`, ветка `.element` в `LayoutTree` | элемент со своей раскладкой — flex-контейнер в том же проходе; стиль — его раскладки, поверх — модификаторы места | [03](03-layout-api.md#управление-subnodes): дерево нод — один проход |
| `LayoutTree.expanding` | элемент, встраивающий сам себя, там становится листом | защита от бесконечной рекурсии |
| `LayoutPlacement`, результат `apply` | кадр в координатах встроившего элемента; кто кого встроил | слой нод строит `subnodes` по размещениям |

## `Sources/Nodes`

| Код | Что | Основание |
|---|---|---|
| `Node` — `layoutSpec()`, `update()`, `layoutContent` | модель Texture: дети в свойствах, раскладка на них ссылается | [03](03-layout-api.md#модель-как-в-texture) |
| `Node.embeddedLayout` — `layoutObserver.track` | прочитанное в раскладке — зависимость раскладки | [08](08-open-questions.md#состояние-и-реактивность) |
| `Node.prepare`, `isInFirstUpdate` | `update()` до первого замера; его изменения уже в этом проходе | один проход при первом показе |
| `NodeHost.mount` | `subnodes` — ноды из размещений; не упомянутые — сняты, но живы; нода в обеих ветках `Breakpoint` — там, где раскладка её показала | [03](03-layout-api.md#управление-subnodes) |
| `NodeHost.layoutIfNeeded` | сначала `StateUpdates.flush()`, потом проход | порядок «update → раскладка» |
| `Appearance`, `NodeHost.setNeedsRender` | вид ноды — отдельно от раскладки: смена не запускает проход | Texture: свойства ноды, не раскладки |

## `Sources/NodesRender`, `Sources/NodesUIKit`, `Sources/NodesAppKit`

| Код | Что | Основание |
|---|---|---|
| `LayerRenderer` | один платформо-нейтральный рендерер, только QuartzCore | правило Trellis «рендерер один» (AGENTS.md корня) |
| `NodeNSView` — layer-hosting, `isGeometryFlipped` | AppKit не меняет геометрию своего слоя; начало координат — сверху слева | [05](05-platform-adapters.md#что-адаптер-обязан-закрыть) |
| `NodeView.layoutSubviews`, `NodeNSView.layout` | размер/масштаб/направление → `NodeHost`, проход, отрисовка | [05](05-platform-adapters.md#встраивание-нод) |
| `UIView/NSView.addSubnode` | нода в обычном view | [05](05-platform-adapters.md#встраивание-нод) |
| `LayerRenderer.sync`/`enter`/`attach`, `Level` | сверка слоёв явным стеком, в порядке рекурсии | дефект #141 |
| `LayerDrawing`, `LayerRenderer.draw` | содержимое ноды — bitmap в `contents`, всегда прямо | дефект #129 |
| `Text`, `TextMeasurer`, `TextLayout` | одна `TextLayout` для замера и рисования | правило Trellis: измерение и рисование — одна строка (дефект #37 Trellis) |
| `ImageLoadFailure`, `ImageLoadPhase.failed(_:)`/`failure`, `ImageCacheError.status` | причина ошибки загрузки для приложения | [11](11-image.md) |
| `Image`, `ImagePipeline`, `ImagePlaceholder`, `ImageLoadPhase` | статичная картинка как нода; placeholder и состояние загрузки; превью, декодирование под рамку × масштаб, общий ограниченный кэш bitmap и защита от запоздавшего результата | [11](11-image.md) |
| `DecodeGate`, `ImagePipeline.load` (очередь декодирования) | декодирования pipeline идут по одному вне актора; отменённый в очереди запрос уходит без работы; дефект #155 | [11](11-image.md), [defects](defects.md) |
| `HTTPValidators` (`read`/`write` — расширенный атрибут, `freshUntil`, `forbidsStoring`); `ImageCache.freshData`, условный запрос в `fetch`, 304 в `download`, свежесть в `stamp` | HTTP-кэширование: `Cache-Control`, `Expires`, `Age`, `ETag`/`Last-Modified` | [11](11-image.md#http-кэширование); RFC 9111 |
| `DownloadWatch` (приоритет задачи и предел размера), `ImageCache.load(_:urgency:)`, `Download.urgency`; `LoadUrgency.watch`, `SharedUrgency.watch`/`deinit` | загрузка картинки на экране — высокий приоритет, меняется на ходу | [11](11-image.md#приоритет-видимых) |
| `DecodeGate.release` — первый срочный; `LoadUrgency`, `SharedUrgency`, `InFlight.urgency`; `Image.urgency`, `screenChanged` | картинки на экране декодируются раньше запаса | [11](11-image.md#приоритет-видимых) |
| `Node.tracksScreen`, `isOnScreen`, `screenChanged`, `shownRect`, `updateScreen`; `NodeHost.screenTrackers` | видимость ноды — по запросу, после проходов и движений прокрутки | [11](11-image.md#приоритет-видимых) |
| `ImagePipeline.init(..., decodeGate:)` (внутренний) | тест держит очередь сам, без расчёта на время | тест `thePipelineDecodesAnImageOnScreenBeforeOnesQueuedEarlier` |
| `Image.layoutContent`, `Image.scale` | размер в точках (`пиксели / scale`) как `LeafContent.proportional`: высота по ширине и ширина по высоте — как `<img>`; дефект #157 | [11](11-image.md), [defects](defects.md) |
| `ImagePipeline.load` (`digests`, `reuse`), `ImageCache.stamp`, `ImageFileStamp` | попадание в кэш памяти без чтения файла: отпечаток по штампу (размер, даты, свежие атрибуты — не `resourceValues`); дефект #160 | [11](11-image.md), [defects](defects.md) |
| `LayerDrawing.layerImage`, `LayerImage`, `LayerRenderer.show`, `fillCrop`, `Image.solidImage` | картинка в `contents` без копии под рамку; вписывание — gravity и `contentsRect`; placeholder — один пиксель | [11](11-image.md) |
| `LayerDrawing.prepareDrawing`, `LayerRenderer.draw` | рендерер сообщает размер и масштаб до рисования, чтобы нода могла обновить детализацию | [11](11-image.md) |
| `ImageCache`, `ImageCacheConfiguration` | дисковый кэш URL, предел/возраст, отдельные настройки метаданных и PNG-оптимизации | [11](11-image.md) |
| `ImageCache.load`, `ImageCache.download`, `leave` | одна загрузка на URL для одновременных запросов; последний ушедший отменяет её до записи; дефект #158 | [11](11-image.md), [defects](defects.md) |
| `ImageCache.session`, `maximumDownloadBytes`, `DownloadLimit` | сеть через переданную сессию; предел тела ответа по счётчикам байтов задачи (асинхронный `URLSession` не отдаёт делегату задачи колбэки данных); дефект #159 | [11](11-image.md), [defects](defects.md) |
| `ImageCache.removeAll`, `remove(for:)`, `removeExpired`, `entries`, `storedBytes` | только свои записи (имя — 64 hex); очистка; счётчик размера с пересчётом при лимите и раз в 64 записи; загрузка после `removeAll` не пишется; дефект #161 | [11](11-image.md), [defects](defects.md) |
| `ImageCache.policyTag`, `fileURL`, `Naming` | имя записи — метка политик и отпечаток URL; лимит и срок — по записям своих политик в общей папке; прежние имена удаляются; дефект #162 | [11](11-image.md), [defects](defects.md) |
| `Image.mountedChanged`, `isSuspended`, `startFirstLoad` | уход из дерева отменяет загрузки и отпускает bitmap, возвращение возобновляет; дефект #163 | [11](11-image.md), [defects](defects.md) |
| `ImageCache.download(removalsAtStart:)` | счётчик `removeAll()` берётся при создании загрузки, не при старте её задачи; дефект #164 | [defects](defects.md) |
| `ImageCache.prepare` (метаданные), `exifAndTIFF` | метаданные источника передаются в copy-source (иначе Image I/O пишет пустые и теряет ориентацию); для XMP-политики — только EXIF/TIFF; дефект #166 | [11](11-image.md), [defects](defects.md) |
| `ImageCache.load` (`processingFailed`) | формат, к которому политика метаданных неприменима, показывается без записи на диск; дефект #156 | [11](11-image.md), [defects](defects.md) |
| `TextLayout(rightToLeft:)`, `Text.drawingRevision` с направлением хоста | `leading` у правого края в RTL; смена направления перерисовывает | [03](03-layout-api.md) |
| `Node.hitTest` (явный стек), `Node.walkVisible`, `frame(from:)`; `NodeHost.collect`/`collectFocus`/`collectSections`/`spokenText` через `walkVisible` | обходы без рекурсии | дефект #142 |
| `Node.hitTest`, `Node.onTap`, `pressChanged` | нажатия: ближайшая нода с действием, засчитывается над той же нодой | как `UIButton` (touch up inside) |
| `NodeHost.pointerDown/Up/Cancelled` | платформо-нейтральный путь событий; адаптер только передаёт точку | тестируется на Linux |
| `Button` (`NodesRender`) | текст на фоне, затемнение при нажатии | демо |
| `NodeCache`, `NodeCache.reserve`, `clearReserve()`, `NodeHost.passGeneration` | нода на id модели; ушедшие отпускаются на следующем проходе или ждут в запасе | [04](04-conditionals-and-responsive.md#7-кэш-нод-для-динамических-списков) |
| `LayoutSpec.prepare`, `PreparedLayout` | подготовка (MainActor) / расчёт (где угодно) / применение (MainActor) | фоновый расчёт |
| `ContentMeasurer.requiresMainThread` | view меряются только на главном: такая раскладка решается там | `ViewMeasurer` |
| `NodeHost.mainThreadStackBudget`, `SolveOutcome`, `reject`; `LayoutReport.Stack` | проход не поместился в стек главного — на поток хоста или отклонён | дефект #124 |
| `Node.pendingHost`, `NodeHost.pending`/`releasePending` | изменение ноды, которую монтирует проход в полёте | дефект #138 |
| `NodeHost.solvesInBackground`, `solve`, `adopt` | поток со стеком 8 МиБ; поток регистрируется изнутри тела; обогнанный расчёт отменяется и выбрасывается | дефекты #124, #22 (Trellis) |
| `AccessibilityEntry`, `AccessibilityList` (`rowCount`, `columnCount`, `position(ofItem:)`, `item(row:column:)`), `AccessibilityListItem`; `NodeHost.accessibilityEntries`, `accessibilityList`, `accessibilityFrame(ofItem:in:)`, `revealItem`; `AccessibleList` (`LazyStack`) | ленивый стек для VoiceOver — список со всеми строками | [03](03-layout-api.md) (десятый срез, VoiceOver) |
| `ListAccessibilityElement`, `ListRowAccessibilityElement`, `ShowableAccessibilityElement` (AppKit); `NodeNSView.parentSpace(_:in:)`, `accessibilityReveal` | Mac: список со строкой на каждый элемент данных, `AXScrollToVisible` раскладывает строку; рамки от низа родителя | [03](03-layout-api.md) (десятый срез, Mac); дефекты #190, #191; UI-тест `Demo/MacUITests` |
| `ListAccessibilityContainer`, `ListItemStandIn` (UIKit) | контейнер-таблица (`.dataTable`: ряд и столбец каждой строки) с элементом на каждую строку; заглушка раскладывает строку, когда на неё встаёт VoiceOver | [03](03-layout-api.md) (десятый срез, VoiceOver); как `UICollectionView`; UI-тест `Demo/iOSUITests` |
| `Accessibility`, `NodeHost.accessibilityItems`, `activate` | элементы доступности из дерева: текст, кнопки с подписью из текста внутри | как UIKit: `UIButton` читается подписью |
| `NodeAccessibilityElement` (UIKit, AppKit) | хранит `NodeID` и слабый хост, не ноду | правило Trellis о нативных AX-объектах |
| `Table`, `TableSection`, `SwipeAction`, `TableRow`, `Cell`, `ActionButton`, `SectionHeader` | таблица с секциями и swipe-действиями поверх `LazyStack` | [03](03-layout-api.md) (таблица) |
| `Table.isEditing`, `selection`, `onMove`, `TableMove`, `TablePosition`, `Table.follow`/`drop`/`advance`/`stackLaidOut`, `SelectionMark`, `MoveHandle`; `Appearance.zIndex`, `LazyStack.setItemsHoldingScroll`, `onLayoutApplied`; `NodeNSView.mouseDragged` | режим правки таблицы: выбор нескольких строк, перестановка перетаскиванием с прокруткой у края | [03](03-layout-api.md) (режим правки); дефекты #194, #195 |
| `Table.allowsMultipleSelection`, `Table.tapped`, `Cell.isSelected` | выбор нескольких строк касанием вне правки | [03](03-layout-api.md) (режим правки) |
| `Node.onMoveCommand`, `NodeHost.moveCommand`, `NodeFocusItem.shouldUpdateFocus`, `NodeView.takesMove` (UIKit), `NodeNSView.arrow`; `Table.pickUp`/`putDown`/`command`, `MoveHandle.focusLost`; `Demo/TV/MoveProbe` | стрелки ноде с фокусом; перестановка строк пультом и клавиатурой | [03](03-layout-api.md) (режим правки); дефекты #205, #206 |
| `Command`, `Shortcut`, `Key`, `KeyModifiers`, `Node.handle`/`removeHandler`, `NodeHost.canPerform`/`perform`/`availableCommands`/`handlesCommands`, `commandOrigin`; `MenuBar`, `Menu`, `MenuItem`, `Divider`; `NSMenu(_:)`, `NSMenuItem(_:)`, `NodeNSView.performCommand`/`validateMenuItem`, `Shortcut(NSEvent)` (AppKit); `UIMenu(_:)`, `NodeView.keyCommands`/`performCommand`/`performShortcut`/`canPerformAction`, `NodeView.pressesBegan`/`take`/`release`/`startHolding` (UIKit); `Demo/TV/CommandProbe` | единая модель команд: меню, сочетания клавиш, кнопки пульта | [03](03-layout-api.md) (команды) |
| `CommandResponder` (`outer`, `enabledHandler`), `NodeHost.outerResponder`, `Command.cancel`, `Command.back` на Cmd-[; `[CommandHandler].set` | команды за корнем дерева: экран, контейнер, окно, приложение | [03](03-layout-api.md) (команды); [12](12-app-layer.md) (решение 6, «Что нужно от нижних модулей», п. 1) |
| `NodeHost.isShown`, `Node.isShown`/`shownChanged`/`setShown`; `NodeView.updateShown` (UIKit), `NodeNSView.updateShown` (AppKit); `Image.shownChanged`/`suspend`, `Table.shownChanged` | показ дерева отдельно от монтирования: задачи показа скрытого экрана | [03](03-layout-api.md) (показ дерева); [12](12-app-layer.md) («Что нужно от нижних модулей», п. 5) |
| `Node.dragAxis`, `onDrag`, `Drag`; `NodeHost.canDrag`, `dragBegan/Moved/Ended/Cancelled`; `NodeView.dragPan` (UIKit); трекпад в `NodeNSView.scroll(by:)` (AppKit) | перетаскивание ноды по оси; пан прокруток ждёт его отказа | [03](03-layout-api.md) (таблица) |
| `Appearance.offset`; `Node.accessibilityActions`, `AccessibilityAction`, `AccessibilityItem.actions`, `NodeHost.performAccessibilityAction` | сдвиг рисунка без раскладки; действия элемента доступности | [03](03-layout-api.md) (таблица) |
| `BreakpointCase`, `Breakpoint(_:otherwise:)`; `LayoutTree.branches`, `shown(_:within:fills:)`, `Widths` | `Breakpoint` с несколькими ветками; вложенный `Breakpoint` в пределах ветки | [04](04-conditionals-and-responsive.md) (п. 5); дефект #193 |
| `Transition`, `Transition.Effect`, `Node.transition`; `LayerRenderer.comeIn`, `goOut`, `transform(_:size:base:rightToLeft:)`, `applyVisibility` | как нода приходит и уходит: эффект «вдали» — прозрачность и трансформация слоя; уходящий слой держит анимацию прозрачности | [04](04-conditionals-and-responsive.md#появление-и-исчезновение-с-анимацией); как SwiftUI `.transition` |
| `Animation`, `withAnimation` | анимация — у изменения, не у ноды; `withAnimation` сразу выполняет обновления состояния, чтобы раскладка узнала свою анимацию | как SwiftUI `withAnimation` |
| `NodeHost.renderAnimation`, `pendingAnimation`, `solvingAnimation` | анимация идёт от запроса к проходу (и через фоновый расчёт) к отрисовке; обогнавший проход её наследует | — |
| `LayerRenderer.transition`, `Look` | явные `CABasicAnimation`/`CASpringAnimation` от показанного сейчас к новому; без анимации — снимается только анимация изменившегося свойства | прерывание посреди анимации |
| `LayerRenderer.draw` — анимация `contents` | новое содержимое проявляется поверх прежнего при анимированном проходе | [03](03-layout-api.md) |
| `Pass.shownOrigins`, `formerSuperlayers`, `shownOrigin(of:)` | нода, перешедшая к другому родителю, начинает анимацию там, где была показана | [03](03-layout-api.md) |
| `LayerRenderer.settle`, `leaving` | ушедшая нода гаснет на месте; слой отпускается на первой отрисовке после конца анимации; вернувшаяся — тот же слой | без колбэков завершения CA |
| `Node.mountedChanged`, `mount`, `unmount` | событие входа в дерево и выхода — только на переходах: `mount` зовётся на каждом проходе | дефект #163 |
| `Node.isFocusable`, `isFocused`, `focusChanged` | фокусируема нода с `onTap` (или по флагу), целиком — без вложенных | как `UIButton` на tvOS |
| `NodeHost.focusItems`, `focus`, `focusedNode`, `focusAnimation` | куда идёт фокус, решает система платформы; хост только узнаёт и сообщает ноде в анимации | правило Trellis: платформенный фокус на tvOS — единственный владелец |
| `NodeHost.selectBegan/Ended` | кнопка Select пульта нажимает сфокусированную ноду | как `pointerDown/Up` |
| `NodeFocusItem` (UIKit), `NodeView.focusItems(in:)`, `didUpdateFocus`, `presses*` | один `UIFocusItem` на ноду, живёт пока нода; хранит `NodeID` и кадр; view — first responder, чтобы получить нажатия | Trellis `TrellisNodeProxy` |
| `Appearance.scale`, `Shadow`; `LayerRenderer` — `position`/`bounds`/`transform` | увеличение и тень для фокуса; кадр — через position/bounds, т.к. `frame` при transform не определён | — |
| `Node.isFocusSection`, `NodeHost.focusSections`, `SectionGuide` (UIKit) | `UIFocusGuide` на площади ноды, цель — последняя фокусированная внутри, иначе первая; выключен, пока фокус внутри | SwiftUI `.focusSection()` (tvOS) |
| `SectionEntry` (UIKit), `NodeView.updateSections`, ветка входа в `didUpdateFocus` | секция внутри прокрутки — вход во всю её рамку среди элементов контейнера прокрутки; фокус со входа переводится запросом к `NodeView`, не к элементу ноды | дефект #168 |
| `FocusLook`, `NodeHost.focusLook`, `FocusRing` | TV — нода приподнимается; iPad/Mac — рамка от адаптера, нода не меняется | системный вид фокуса на каждой платформе |
| `NodeHost.moveFocus`, `FocusMove`, `nearest` | Tab — порядок чтения, `false` на краю (дальше — следующий view); стрелки — вперёд ×1 + вбок ×2 | Trellis D38: стрелки по геометрии, tie по порядку |
| `NodeHost.requestFocus`, `onFocusRequest`; `NodeView.requestedFocus`, `applyFocusRequest` | приложение просит, система переводит, хост узнаёт через `didUpdateFocus` — одна дорога для всех переходов | правило Trellis: система фокуса — единственный владелец |
| `NodeNSView` `keyDown/keyUp`, `becomeFirstResponder` | AppKit без фокус-элементов: клавиатуру ведёт view; фокус при входе только от Tab | — |
| `Scroll.zoomRange`, `zoomScale`, `zoom(to:around:)`, `platformDidZoom`; `Scroll.placement(of:)`, `Node.stickyOffset(showing:)`, `Scroll.stuckLength`, `LazyStack.offset(showing:at:in:)` с масштабом; `Placement`, `Node.contentScale`, `placement(in:)`, `walkVisible`; `LayerRenderer.zoom(of:)`; `ScrollDriver.applyZoom` (UIKit); `NodeNSView.pinch`, `smartZoom` (AppKit) | масштаб содержимого прокрутки; пересчёт координат с масштабом | [03](03-layout-api.md) (масштаб) |
| `Scroll.onRefresh`, `refreshIndicator`, `beginRefresh`, `platformDidRelease`, `RefreshIndicator`; `RefreshSpinner`; `Appearance.spin` (`LayerRenderer.applySpin`); `ScrollDriver.applyInsets`, `follow` | потяни, чтобы обновить: место над содержимым, индикатор | [03](03-layout-api.md) (обновление); дефект #192 |
| `Scroll.isPaging`, `page`, `pageCount`, `scroll(toPage:)`, `pagingTarget(from:at:velocity:)`; `ScrollDriver.scrollViewWillEndDragging` (UIKit); `NodeNSView.turnPages`, колесо по странице (AppKit) | страницы: одно правило цели для всех платформ | [03](03-layout-api.md) (страницы) |
| `Scroll`, `ScrollAxis`, `ScrollRange`; `contentOffset` в `State` | окно на содержимое; чтение смещения — зависимость | [03](03-layout-api.md) (девятый срез) |
| `Scroll.layoutSpec` — `shrink 10⁶`, `grow 1` у вертикального, `min 0` вдоль оси | сжимается раньше соседей, явный размер при размещении работает; не `flex-basis: 0` — он сильнее `height` | [03](03-layout-api.md) |
| `Scroll.offsetRange`, `contentBounds` | диапазон от начала содержимого, в RTL — отрицательные x | дефект #90 Trellis |
| `Node.contentOrigin`; `hitTest`, `walkVisible` | подузлы прокрутки сдвинуты на её смещение — для касаний, фокуса, доступности | — |
| `NodeHost.reveal` в `focus` | фокус к ноде внутри прокрутки прокручивает к ней, внутреннюю первой | как `UIScrollView` с клавиатурой |
| `NodeHost.scrolledSinceRender`, `setNeedsScrollRender`; `LayerRenderer.renderScrolls` | прокрутка без анимации двигает только слои прокруток | 60 кадров в секунду при перетаскивании |
| `LayerRenderer.updateIndicator` | полоса — последний подслой; при движении — keyframe-анимация прозрачности, гаснет сама | без таймеров |
| `Scroll.overscroll`, `shownOffset`, `platformDidScroll(to:)` | отскок системной физики за краем — не часть `contentOffset` | iOS |
| `NodeHost.scrollItems`, `scrolls(at:)` | видимые прокрутки для адаптера; цепочка прокручиваемых под точкой, внутренняя первой | [05](05-platform-adapters.md#прокрутка) |
| `LayoutSpec.sticky`, `LayoutTree.Entry.sticky`/`flexParent`, `PreparedLayout.sticky(of:)`; `LayoutElement.applyLayoutSticky`, `StickyPosition` | sticky вне движка: элемент получает отступы и рамку ближайшего flex-контейнера | CSS `position: sticky` |
| `Node.stickyOffset`, `stick`, `shownOrigin` | сдвиг по CSS Positioned Layout §3.4 из смещения прокрутки, без прохода раскладки | [03](03-layout-api.md) |
| `Node.subnodesInDrawingOrder`; `hitTest`, `LayerRenderer.enter` | sticky поверх остальных элементов контейнера — как позиционированный блок в CSS | CSS painting order |
| `LayerRenderer.stickyNodes`, `position(of:)` | быстрый путь прокрутки двигает и слои sticky | — |
| `ScrollFocusContainer` (UIKit), `NodeFocusItem.parent`, `NodeView.topFocusItems` | прокрутка — `UIFocusItemScrollableContainer`: движок фокуса ищет по всему содержимому и двигает `contentOffset` | [05](05-platform-adapters.md#прокрутка); UI-тест `Demo/TVUITests` |
| `NodeHost.scrollPage`, `Scroll.scrollPage`, `ScrollPage`; `NodeHost.reveal` | прокрутка для технологий доступности: страница, «Page N of M», показ элемента | UIKit `accessibilityScroll` |
| `NodeView.accessibilityByNode`, `NodeAccessibilityElement.update` | элемент живёт, пока нода — элемент; VoiceOver держит место по объекту | прокрутка перерисовывает много раз в секунду |
| `NodeNSView.WheelPhase`, `pulled`, `stretch`, `springBack`, `glideIsSpent` | отскок трекпада: сопротивление `(1 − 1/(x·0.55/d + 1))·d`, возврат пружиной, инерция отскакивает раз | как `NSScrollView` |
| `NodeNSView.accessibilityByNode`, `NodeAccessibilityElement.update` (AppKit) | элемент живёт, пока нода | как в UIKit |
| `Scroll.contentOffset` — запись того же значения ничего не делает | не сбрасывает `overscroll` при вытягивании | — |
| `LazyStack`, `laidOutItems`, `layoutSpec` — отступы до и после окна | раскладываются только элементы у окна; остальное — место по измеренным или оценочным длинам | [03](03-layout-api.md) (десятый срез) |
| `LazyStack.lanes`, `line(_:)`, `lines(from:to:)`, `updateStarts` по рядам | сетка: ряды по `lanes`, равные доли и пустые доли в неполном ряду, длина ряда — наибольшая | [03](03-layout-api.md) (десятый срез, сетка) |
| `LazyStack.visibleSpan`, `reach`, `viewportMoved`, `covered` | окно — пересечение обрезающих предков и хоста; запас — экран, новый проход при выходе за пол-экрана | [03](03-layout-api.md) (десятый срез) |
| `LazyStack.rememberAnchor`, `layoutApplied`; `Scroll.shiftOffset` | якорь: видимое не прыгает при изменении длин до окна; у начала — не держит | как якорь прокрутки в браузерах |
| `LazyStack.anchorMoved`, `Anchor` (`start`, `index`) | окно берётся там, куда сдвинулся якорный элемент | дефект #172 |
| `Scroll.move`, `OffsetMove`, `advanceMove(to:)`, `stopMove`, `targetOffset`; `NodeHost.needsFrames`, `onNeedsFrames`, `advanceFrames(to:)`, `movingScrolls` | анимированный переход дальше запаса ленивого стека — покадрово | [03](03-layout-api.md) (десятый срез, переход) |
| `ViewportDependent.needsFrames(toMove:by:)`, `NodeHost.movesFrameByFrame` | покадрово — только переход длиннее экрана хоста; короче — анимация слоя | [03](03-layout-api.md) (десятый срез, переход) |
| `TextMeasurements`, `TextMeasurer.measurements`, `Text.measurements`; `TextLayout.font(for:)` с `FontCache` по потоку | измерения текста хранятся до смены текста или стиля; шрифты — по потоку | дефект #188; [03](03-layout-api.md) (третий срез) |
| `Benchmarks/Sources/ScrollBench` (`DemoScreen.swift` — ссылка на экран демо) | проход раскладки при прокрутке: движок, остальное, отрисовка | [10](10-layout-engine.md) |
| `NodeHost.laysOutNow` в `layOut()`, `setNeedsLayoutNow`; `LazyStack.mountedCover` в `viewportMoved` | проход кадра и проход для окна, ушедшего за смонтированное, — на главном потоке и при `solvesInBackground` | дефект #185; [03](03-layout-api.md) (десятый срез) |
| `OffsetMove.followsEnd`, `settled` в `advanceMove`; `shiftOffset(by:movesTarget:)`, `OffsetMove.progress` | к концу — до конца, как бы ни вырос список; якорь сдвигает цель за окном, перед окном — пересчитывает начало пути | [03](03-layout-api.md) (десятый срез, переход) |
| `Animation.progress(at:)`, `bezier`, `spring` | кривые покадрового движения — как у Core Animation | [03](03-layout-api.md) (десятый срез, переход); CSS Easing (cubic-bezier) |
| `ScrollAlignment`; `LazyStack.scroll(to:at:)`, `offset(showing:at:in:)`, `scrolledTo`, `keepScrolledTo`; `Scroll.scroll(to:following:)`, `OffsetMove.following`, `framesPast`, `settlingFrames` | переход к элементу: цель уточняется на каждом кадре и после проходов | [03](03-layout-api.md) (десятый срез, переход к элементу) |
| `Scroll.stuckLength(at:)`, `Node.stickyOffset(showing:)` | элемент встаёт после нод, прилипших к началу окна на целевом смещении | дефект #184; CSS `scroll-padding` по смыслу |
| `FrameTarget`, `startFrames`, `displayFrame` (UIKit, AppKit) | кадры дисплея для покадрового движения | [05](05-platform-adapters.md#прокрутка) |
| `untracked` в `LazyStack.layoutSpec` | смещение прокрутки не зависимость раскладки стека | иначе проход на каждом кадре; тест `scrollingWithinWhatIsLaidOutDoesNotLayOutAgain` |
| `ViewportDependent`, `NodeHost.viewportDependents`, `viewportMoved`, `settlingPasses`, `preparing`; `layOut()` | хост сообщает о проходах и движении; до 4 проходов подряд в `layoutIfNeeded` | [03](03-layout-api.md) (десятый срез) |
| `ScrollDriver.synced`, `catchUp` (UIKit) | сдвиг прокрутки кодом под пальцем и в инерции переносится на `UIScrollView` | [05](05-platform-adapters.md#прокрутка); тест `aMoveByCodeIsNotLostToTheFingersNextMove` |
| `ScrollDriver` (UIKit), `NodeView.hitTest`, `gestureRecognizerShouldBegin` | пустой `UIScrollView` — только физика; его пан на `NodeView` | [05](05-platform-adapters.md#прокрутка) |
| `ScrollDriver.whileFollowing`, `isFollowing` (UIKit) | вложенная защита от обратных вызовов `UIScrollView` восстанавливает прежнее значение | дефект #204 |
| `NodeView.accessibilityHitTest(_:event:)` (UIKit, iOS/tvOS 18+) | элемент доступности ищется так же, как касание: нода поверх другой скрывает её элементы | дефект #203 |
| `NodeNSView.scrollWheel`, `scroll(by:at:)`, `latched` | колесо/трекпад: внутренняя прокрутка, остаток — внешней; жест держится за начальные | [05](05-platform-adapters.md#прокрутка) |
| `NodeView` на iPad: `usesFocus`, `selects` | система фокуса iPadOS с клавиатурой; групп фокуса нет — свойство недоступно на tvOS | дефект #135 |
| `NodeView.zoom`, `contentLayer`, `zoomed` | дерево раскладывается в `bounds / zoom`, слой содержимого увеличен от левого верхнего угла; `host.scale` = экран × zoom, чтобы текст был чётким; `nil` — 2 на TV, 1 иначе | интерфейс для TV: размеры под телефон с 2–3 м читаются примерно вдвое крупнее |
| `NodeNSView.zoom`, `contentLayer` | то же на Mac; по умолчанию 1 | [03](03-layout-api.md) |
| `LayoutReport`, `NodeHost.onLayoutReport`, `number`, `traceAreas`, `tracedNodes`; `finish` — отклонение прохода | отчёт прохода, дубликаты | [03](03-layout-api.md#управление-subnodes), [10](10-layout-engine.md#диагностика) |
| `NodeView`/`NodeNSView` — `onLayoutReport` в `DEBUG`, `os.Logger` | вывод решает адаптер | [10](10-layout-engine.md#диагностика) |
| `Demo/Demo.xcodeproj` | одно демо: экран `Demo/Shared` в таргетах `LayoutDemoMac`, `LayoutDemoiOS` (с Catalyst), `LayoutDemoTV` и `LayoutDemoTVUITests`; папки таргетов — синхронизированные группы, пакет подключён локально (`..`) | решение пользователя 2026-09-26: один проект с разными таргетами |
| `NodeView.focusMovementFailed`, `reachTarget`, `score`, `continueReach`, `focusScrollMoved`; `Demo/TV/FocusProbe`, `Demo/TVUITests/FocusReachTests` | фокус пульта за пределами поиска UIKit: резервный переход и доводка прокрутки | [03](03-layout-api.md) (фокус пульта через высокий блок); дефект #198 |
| `ThemeCore`: `Theme`, `Palette`, `ThemeColor`, `Typography`, `ThemeFont`, `Radii`, `MotionSet`, `DisplayConditions`, `ResolvedTheme`, `ThemeOverride`, `ThemedLayout`, `Color` | тема и её разрешение для условий отображения | [09](09-theme.md) |
| `BreakpointWidth` (имя или число), `BreakpointScale`, `LayoutSpec.resolvedStyle(_:_:)`, `LayoutTree.branches(... breakpoints:)` | пороги — токены до подготовки раскладки | [09](09-theme.md#пороги) |
| `NodeHost.theme`, `conditions`, `resolvedTheme`; `Node.theme`, `themeOverride`; `Animation(Motion)` | тема в дереве нод, переопределения поддерева | [09](09-theme.md#распространение-по-дереву) |
| `TextStyle.role`, `colorRole`, `scalesWithText`, `resolved(in:)`; `Text.restyle`; `Button.fill`; тема в `Table`, `RefreshSpinner` | компоненты по теме | [09](09-theme.md) |
| `DisplayConditions(UITraitCollection/NSAppearance)`, `UIColor/NSColor(ThemeColor)`, `UIFont/NSFont.themed`; `NodeView/NodeNSView.updateConditions`; `LayoutView/LayoutNSView.layoutTheme` | условия системы и тема для обычных view | [09](09-theme.md#обычные-view); дефект #202 |

## `Sources/AppShell`, `Sources/AppShellUIKit`, `Sources/AppShellAppKit`

| Код | Что | Основание |
|---|---|---|
| `Screen`, `NodeScreen`, `Stack`, `StackEntryID`, `StackMove`, `StackPresenter`, `NavigationResult`, `NavigationRejection`, `PresentedStack` | экраны и стек: записи со своей идентичностью, один ход за раз, подтверждение платформой, возврат пользователя | [12](12-app-layer.md) (A0, A1; «Идентичность и согласование переходов») |
| `StackNavigationController` (`popViewController`/`popToViewController` override, `follow`, `matchStack`), `ScreenViewController`, `ControllerScreen` (UIKit) | стек в `UINavigationController`; возврат платформы ведёт стек | [12](12-app-layer.md) (A1) |
| `StackViewController` (`present`, `giveKeyboard`, `goBack`, `validateMenuItem`), `StackView`, `ScreenViewController`, `ControllerScreen` (AppKit) | свой стек Mac: сдвиг, Cmd-[, меню, возврат фокуса | [12](12-app-layer.md) (A1); дефект 209 |
| `CommandTarget`, `handle(_:isEnabled:isOn:perform:)`, `NodeHost.isOn`/`CommandResponder.isOn`, `nearestHandler`, `NodeHost.originChanges`; `CommandToolbarItem`, `Command(carriedBy:)`, `NSMenuItem.validate(with:)`, `NodeNSView.validateToolbarItem` (AppKit); `UIBarButtonItem(_:target:)`/`update`, `NodeView.validate(_:)` (UIKit) | галочка у пункта меню, кнопки из команд, наблюдаемая включённость | [03](03-layout-api.md) (галочка и получатель для кнопок) |
| `WindowToolbar`, `StackViewController.watchTop`/`validateToolbarItem`, `ScreenViewController.watchToolbar` (AppKit); `StackNavigationController.showTop`/`willShow` (UIKit); `Demo` `Command.flagMessage`, `Inbox.toggleFlag`, `MessageNode.showFlag` | `Screen.toolbar`: панель окна Mac, кнопки панели навигации UIKit | [12](12-app-layer.md) (A3, часть 1) |
| `Presentation` (`Phase`, `reconcile`, `begin`, `finish`, `showEnded`/`hideEnded`/`userDismissed`/`userDismissAttempted`), `PresentationStyle`, `PresentationPresenter`, `Screen.present`/`presentation`/`presentationPresenter`, `NavigationRejection.alreadyPresenting`; `Stack.release` (закрывает показ экрана); `ModalPresenter`, `PresentedViewController`, `contentController(for:)` (UIKit и AppKit); `Demo` `ComposeNode`, `Command.newMessage`, `DemoModel.compose`/`openCompose` | модальный показ: лист и на весь экран, закрытие пользователем, граница команд | [12](12-app-layer.md) (A3, часть 2) |
| `PresentationStyle` (`coversWindow`, `heights`, `sheet(heights:)`), `SheetHeight`, `Presentation.height`/`userMoved(to:)`; `SheetHeights` (недоступен на tvOS), `ModalPresenter: UISheetPresentationControllerDelegate`, `SheetHeight.identifier`/`detent` (UIKit); `Demo` `MessageInfoNode`, `Command.messageInfo` | лист на части высоты | [12](12-app-layer.md) (A3, часть 2б); дефект 210 |
| `Alert`, `AlertAction`, `AlertActionRole`, `AlertStyle`, `AlertActionBuilder`, `Screen.present(_: Alert)`, `PresentationContent`; `ModalPresenter.alertController`/`show(_:of:in:)`, `PopoverAnchoring` (UIKit, AppKit); `Demo` `Command.deleteMessage`, `MessageNode.delete`, `DemoModel.askToDelete` | предупреждения и меню действий | [12](12-app-layer.md) (A3, часть 2в) |
| `RouteTable`, `RoutePattern` (`match`, `fill`, `specificity`, `takesRest`), `RouteParameters`, `RouteError`, `RouteTableBuilder` | маршруты-URL: путь стека из URL и URL пути | [12](12-app-layer.md) («Маршруты-URL») |
| `Application`, `WindowScene`, `SceneBuilder`, `SceneContent`, `SceneSession`, `SceneActivation`, `Shell`, `OpenRequest`, `OpenResult`, `Command.closeWindow` | приложение и его сцены, цепочка команд до приложения, очередь ссылок | [12](12-app-layer.md) (A2) |
| `Application.main`, `ShellApplicationDelegate`, `ShellSceneDelegate` (UIKit); `Application.main`, `ShellApplicationDelegate`, `NSMenu(standardAround:)` (AppKit) | точка входа: сцены UIKit с отключением отдельно от уничтожения; окна и стандартные меню Mac | [12](12-app-layer.md) (A2) |
| `EmbeddedNode`, `EmbeddedItem`, `NodeHost.embeddedItems`/`keyboardInset`/`reveal`, `Node.keyboardInset`, `Scroll.keyboardDismissal`, `KeyboardDismissal`; `TextField`, `ReturnKey`, `TextContent` (NodesRender); `EmbeddedHolder`, `NodeView.placeEmbeddedViews`/`embeddedView(of:)`/`revealEditingField`, `FieldView`, `KeyboardFollowing`, `NodeView.keyboardProbe` (UIKit); `Demo` `FormNode`, `DemoRoute.form` | вложенный системный вид, поле ввода, клавиатура (прототип) | [13](13-controls.md) (прототип C2–C4); дефекты 208, 210 |
| `Control`, `ControlState`, `ToolTipItem`, `Node.toolTip`/`hoverChanged`/`isInteractive`/`shownToolTip`, `NodeHost.pointerMoved`/`toolTip(at:)`/`toolTipItems`/`canPerform(_:from:)`/`perform(_:from:)`; `Button` на `Control`, `Button(command:)` (NodesRender); `NodeNSView.mouseMoved`/`updateToolTips`, `NSViewToolTipOwner` (AppKit); `NodeView.followPointer`, `PointerTracker` (UIKit); `Demo` `FollowBadge` | общий контрол, наведение, подсказки | [13](13-controls.md) (C0) |

## `Sources/StorageCore`, `Sources/StorageFoundation`

| Код | Что | Основание |
|---|---|---|
| `PreferenceKey`, `PreferenceValue`, `PreferenceError` | типизированный ключ настройки: имя, умолчание, преобразование в значение, пригодное для property list; ошибка вместо подстановки умолчания | [14](14-storage-and-network.md#4-preferences-типизированные-userdefaults) |
| `PreferenceStore` (`value(for:)`, `set`, `remove`, `values(for:)`) | общий типизированный слой над тремя сырыми операциями; наблюдение без повторов, умолчание поверх пустого — не изменение | [14](14-storage-and-network.md#s1-результаты-на-2026-10-01-preferences) |
| `MemoryPreferences` | хранилище в памяти для тестов и превью | [14](14-storage-and-network.md#11-этапы-реализации) |
| `UserDefaultsPreferences` | хранилище в `UserDefaults`: suite, namespace, подписка на уведомление любого экземпляра домена | [14](14-storage-and-network.md#s1-результаты-на-2026-10-01-preferences) |
| `FilePath` | относительный путь только вниз: без `..`, абсолютных, пустых и точечных имён | [14](14-storage-and-network.md#5-files-управляемая-работа-с-filemanager), S2 |
| `FileError`, `FileError.init(_:path:)` (StorageFoundation) | ошибки файлов; POSIX внутри Cocoa-ошибки разбирается первым | [14](14-storage-and-network.md#5-files-управляемая-работа-с-filemanager) |
| `FileStore`, `MemoryFileStore` | протокол файлового хранилища и реализация в памяти с теми же правилами | [14](14-storage-and-network.md#5-files-управляемая-работа-с-filemanager) |
| `DiskFileStore` (`write`, `copy`, `importFile`, `url(for:)`, `removeLeftoverTemporaryFiles`) | корень, временный файл + замена, копирование кусками, отказ идти по ссылкам | [14](14-storage-and-network.md#5-files-управляемая-работа-с-filemanager) |
| `FileWorker`, `Cancellation` (в `DiskFileStore.swift`) | блокирующая работа на последовательной очереди; флаг отмены между кусками | [14](14-storage-and-network.md#5-files-управляемая-работа-с-filemanager) (iOS 16 — без исполнителя actor) |
| `Cache`, `CacheLookup`, `CacheError`, `CachePolicy`, `CorruptionHandling`, `CacheEvent` | кэш байтов: попадание, устаревшее и промах — разные исходы; повреждение по политике | [14](14-storage-and-network.md#6-cache-общий-кэш-и-существующие-изображения), S3 |
| `Cache.get(_:for:)`/`set(_:for:)` для `Codable` | JSON поверх байтов; не расшифровавшееся значение — промах | [14](14-storage-and-network.md#6-cache-общий-кэш-и-существующие-изображения) |
| `MemoryCache` | кэш в памяти: срок, предел байтов, вытеснение просроченных, затем LRU | [14](14-storage-and-network.md#6-cache-общий-кэш-и-существующие-изображения) |
| `DiskCache` (`loadIndex`, `acquire`/`release`, `encode`/`decode`, `fileName`) | кэш на `FileStore`: индекс из имён файлов, заголовок с ключом и суммой, версия, операции по одной | [14](14-storage-and-network.md#6-cache-общий-кэш-и-существующие-изображения) |
| `CachedLoader` (`value(for:)`, `invalidate()`, `dropWaiter`, `finish`) | общая загрузка с независимыми ожидающими; очистка отменяет загрузки и берёт назад позднюю запись | [14](14-storage-and-network.md#6-cache-общий-кэш-и-существующие-изображения) (поколение и отмена) |

## `Sources/StorageGRDB`

| Код | Что | Основание |
|---|---|---|
| `DatabaseStore.open(_:migrations:)`, `DatabaseMigration`, `DatabaseStoreError` | открытие, именованные миграции, отказ от базы новее приложения, откат упавшей миграции | [14](14-storage-and-network.md#7-sql-grdb), S4 |
| `DatabaseStore.read`/`write` | транзакция GRDB; отмена до commit откатывает, после commit — запись остаётся | [14](14-storage-and-network.md#7-sql-grdb) (отмена у commit), S4 |
| `DatabaseStore.observe(_:)` | снимки после каждого commit, ошибка — элемент потока | [14](14-storage-and-network.md#7-sql-grdb), [14 §14](14-storage-and-network.md#контракты-которые-необходимо-сохранить) |
| `DatabaseStore.backup(to:)`, `restore(from:to:)`, `Blocking` | штатный backup SQLite; проверка копии и удаление остатков журнала при восстановлении | [14](14-storage-and-network.md#7-sql-grdb) |

## `Sources/NetworkCore`, `Sources/NetworkFoundation`

| Код | Что | Основание |
|---|---|---|
| `HTTPRequest`, `HTTPResponse`, `HTTPHeaders`, `HTTPMethod`, `HTTPOrigin`, `HTTPError`, `TransportFailure` | значения запроса и ответа; ошибки, которые различают транспорт, статус, декодирование и отмену | [14](14-storage-and-network.md#8-http-тонкая-обвязка-urlsession), S5 |
| `HTTPClient.send` | ожидаемые статусы; повторы; обновление токена на 401; отмена в ожидании | [14](14-storage-and-network.md#8-http-тонкая-обвязка-urlsession) |
| `RetryPolicy` (`allowsRepeating`, `delay`), `HTTPResponse.retryAfter` | повтор только идемпотентного или с `Idempotency-Key`; задержка с потолком и джиттером; `Retry-After` | [14](14-storage-and-network.md#8-http-тонкая-обвязка-urlsession) |
| `HTTPAuthorizer`, `TokenAuthorizer` | токен только своему origin; одно общее обновление на одновременные 401; отметка подписи | [14](14-storage-and-network.md#8-http-тонкая-обвязка-urlsession) |
| `HTTPTransport`, `URLSessionTransport`, `RedirectDelegate` | лимит размера по заголовку и по ходу чтения; редиректы с учётными данными только в своём origin; сопоставление ошибок URLSession | [14](14-storage-and-network.md#8-http-тонкая-обвязка-urlsession) |
| `HTTPEvent`, `HTTPClient.diagnostics` | события без запроса, заголовков и тел | [14](14-storage-and-network.md#8-http-тонкая-обвязка-urlsession) |
| `WebSocketClient` (`connect`, `close`, `send`, `nextEvent`, `states`) | клиент WebSocket: сам держит соединение, события по одному, исходящие по одному, без очереди на время разрыва | [14](14-storage-and-network.md#9-websocket), S6 |
| `WebSocketClient.run`, `runSession`, `noteEnd`, `generation` | цикл подключения; причина окончания фиксируется до закрытия; поколения защищают от запоздавшего соединения | [14](14-storage-and-network.md#9-websocket) |
| `WebSocketClient.deliver`, `OverflowPolicy` | очередь с пределом: остановить чтение или сообщить `resyncRequired` и пересоздать соединение | [14](14-storage-and-network.md#9-websocket) |
| `ReconnectPolicy`, `Heartbeat`, `WebSocketConfiguration` | пауза с потолком и джиттером, сброс после устойчивого соединения, окончательные коды закрытия, ping | [14](14-storage-and-network.md#9-websocket) |
| `WebSocketTransport`, `WebSocketConnection`, `URLSessionWebSocketTransport` | соединение открыто после ответа на ping; отказ апгрейда — со статусом HTTP | [14](14-storage-and-network.md#9-websocket) |
| `NetworkEnvironment` | часы, ожидание и случайность, общие для HTTP и WebSocket | [14](14-storage-and-network.md#9-websocket) |

## `Sources/DataAsyncRay`, `Sources/SyncDemo`, `Demo/Shared/SyncProbe.swift`

| Код | Что | Основание |
|---|---|---|
| `DatabaseStore.observeRay`, `PreferenceStore.valuesRay`, `WebSocketClient.statesRay`, `forward(from:)` | холодные потоки AsyncRay над наблюдениями; отмена подписки снимает наблюдение; ошибка — элемент `Result` | [14](14-storage-and-network.md#14-уточнение-роль-asyncray--2026-09-29) (контракты 1, 3, 5), S7 |
| `ItemsRepository` (`apply`, `performRefresh`, `handle`) | база — единственный источник; событие только со следующим номером, курсор в той же транзакции; старый снимок отбрасывается | [14](14-storage-and-network.md#10-как-использовать-вместе) |
| `ItemsRepository.signOut`, `syncState.epoch`, `syncState.synced` | эпоха в базе; поздний ответ после выхода ничего не пишет; подписка по сокету после первого снимка | [14](14-storage-and-network.md#10-как-использовать-вместе) |
| `ItemsModel`, `LoadPhase`, `ConnectionStatus` | модель окна на `State`: строки из базы, сортировка из Preferences, отмена не ошибка, явный `stop()` | [14](14-storage-and-network.md#10-как-использовать-вместе) |
| `DemoServer`, `DemoSocket`, `Snapshot`, `ServerMessage`, `Subscribe` | сервер демо в памяти: снимок с курсором, пронумерованные события, повтор по `subscribe(since:)`, `resync`, идемпотентный `POST` | [14](14-storage-and-network.md#10-как-использовать-вместе) |
| `DemoSession` | сборка репозитория, клиентов, базы и сервера для приложения | [14](14-storage-and-network.md#12-проверки-и-приёмка) |
| `SyncProbe` (`SYNC_PROBE=1`), `iOSUITests/SyncTests` | экран демо и его UI-тест на iOS | [14](14-storage-and-network.md#12-проверки-и-приёмка) |

## `Sources/PermissionCore`, `Scripts/permission-sdk-probe.py`, `Demo/Shared/PermissionProbe.swift`

| Код | Что | Основание |
|---|---|---|
| `PermissionKind` (`usageDescriptionKeys`), `PermissionStatus`, `PermissionError`, `PermissionProvider` | виды с уровнями, статус с формами доступа, ошибки, протокол поставщика | [18](18-permissions.md#5-контракт-направление-api), P1; ключи — [18 §11](18-permissions.md#11-p0-результаты-на-2026-10-02) |
| `Permissions.request`, `takeTurn`/`endTurn`, `jobs` | окно только при `notDetermined`; запросы одного вида объединены; разные виды по одному; отмена вызывающего не отменяет окно | [18](18-permissions.md#5-контракт-направление-api) |
| `Permissions.statusChanges`, `refresh`, `publish` | текущий статус, затем различающиеся; чтение заново, не журнал | [18](18-permissions.md#наблюдение) |
| `InMemoryPermissionProvider` | подмена для тестов: статусы, ответ человека, удержание окна, счётчики | [18](18-permissions.md#9-проверки) |
| `Scripts/permission-sdk-probe.py` | матрица видов по SDK четырёх платформ из ответов компилятора; ключи в заголовках | [18 §11](18-permissions.md#11-p0-результаты-на-2026-10-02), P0 |
| `PermissionProbe` (`PERMISSION_PROBE=1`), `iOSUITests/PermissionProbeTests` | сырые статусы системы, запрос по кнопке, журнал `PERMISSIONPROBE` | [18 §11](18-permissions.md#11-p0-результаты-на-2026-10-02), P0 |

## `Sources/NodesRender` (Video, V5)

| Код | Что | Основание |
|---|---|---|
| `Video.seek(toSeconds:)`, `Video.currentSeconds`, `resumeSeconds` | место запоминается без сессии и применяется при чтении; обрезка длиной; прямая трансляция без мест | [16](16-video.md#14-v5-результаты-на-2026-10-02) |
| `Video.revealAnimation`, `lastRevealAnimation`, `.firstFrame` в `handle` | заглушка уходит движением темы; при Reduce Motion — сразу | [16](16-video.md#14-v5-результаты-на-2026-10-02) |
| `AVVideoSession.interruption`, `routeChanged`, `isInterrupted`, `VideoSessionEvent.stoppedByRoute` | пауза на звонок с возобновлением по `shouldResume`; уход маршрута сбрасывает желание играть | [16](16-video.md#14-v5-результаты-на-2026-10-02) |
| `VideoPreload`, `Video.preload`, `prepareIfWanted`, `startMetadata`, `holdsPreparation`, `preparationFailed` | подготовка без спиннера и таймаута, тихая неудача, Play на подготовленном видео | [16 §4.1](16-video.md#41-placeholder-предзагрузка-и-первый-кадр--согласованное-уточнение), V5 |
| `VideoPreparationBudget` (`claimForPlay`, `claimForPreparation`, `setActive`, `release`, `offer`) | места на сессии: Play вытесняет самую давнюю подготовку, играющие не вытесняются, подготовка места не отбирает | [16](16-video.md#14-v5-результаты-на-2026-10-02) |
| `AVVideoSession.readMetadata(of:)` | размер и длина файла без плеера | [16](16-video.md#14-v5-результаты-на-2026-10-02) |

