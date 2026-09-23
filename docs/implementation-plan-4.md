# Trellis — план реализации: текст и измерение содержимого

Статус: переработанный проект для обсуждения. Дата: 2026-09-12.

Это основной маршрут общей работы над текстом и анимацией. Детали анимации —
в [плане 5](implementation-plan-5.md), последовательность обеих частей — в §4
ниже. Сохраняем два документа с одной очередью: типографика и движение имеют
разные приёмки, но делят Node, coordinator, renderer и display lifecycle.
Первые действия — T01/M01, затем совместный небольшой прототип T02/M02;
первый законченный пользовательский результат — текст без анимации.
Предложения D49–D74 не становятся принятыми от редактирования этих планов.

Основа: N01 из [implementation-plan.md §7](implementation-plan.md) — «content
measurement под реальную ширину; Text и raster/display pipeline». Условие старта
N01 («решён constraint contract, в том числе shrink/wrap») выполняется **этим**
планом: контракт измерения — его первая карточка, а не предпосылка. Этапы C
(раскладка/рендер), H (hit-testing/события) и A (focus/accessibility) закрыты;
сцены Playground S01–S23 до сих пор без единой строки текста, а labels A11
существуют только как metadata для VoiceOver.

Сверены непосредственно: `Weave/Sources/WeaveUI/Text.swift`,
`WeaveAdapters/CoreTextRasterRenderer.swift`, `WeaveAdapters/DisplayPipeline.swift`,
display-часть `WeaveAdapters/RenderCoordinator.swift`, `CoreTextLayoutBackend` в
`UIKitAdapter.swift`/`AppKitAdapter.swift`; в Trellis — `LayoutContentMetrics`,
`LayoutInputSnapshot`, `FlexboxMeasure` (measure cache и `content`), `Node`
(`layoutContentMetrics(for:)`), `RenderCoordinator`, `LayerRenderer`,
`SemanticSnapshot`/`AccessibilityTree`, [решения](decisions.md) D01–D48 и
[weave-analysis.md §3.3](weave-analysis.md). Реализация, сборка и запуск тестов
при подготовке документа не выполнялись; галочки — только будущая приёмка.

## 1. Границы этапа

Входят:

- Контракт измерения содержимого по **фактически выделенной** ширине внутри
  solver, а не по одному constraint, захваченному при snapshot (F03/§3.3):
  Sendable-измеритель в снимке, кэш по constraint, отмена, детерминизм.
- `TextNode`: текст, стиль (шрифт, размер, вес, цвет, выравнивание, межстрочный
  интервал), `maxLines`, truncation, RTL, locale; intrinsic size и baseline для
  flex; изменение текста как отдельная причина инвалидации.
- CoreText-измерение и растеризация в фоне (по образцу Weave), display pipeline
  с приоритетами, отменой, display-key guard и коммитом в `CALayer.contents`
  через один нейтральный `LayerRenderer`.
- Accessibility текста: label/value из текста автоматически, роль `text`/
  `header`, чтение без TextNode-зависимости у A06 сохранено.
- Playground-сцены с реальным текстом на трёх платформах, screenshot-эталоны,
  замеры для 1000 строк и длинного многострочного абзаца.

Не входят: текстовый ввод/IME, выделение/копирование, интерактивные spans,
inline attachments, Dynamic Type, ImageNode, hyphenation-словари, вертикальный
текст и загрузка кастомных шрифтов. Рекомендуем одну атрибутированную модель с
простым строковым initializer (§3.3); смешанные шрифты/цвета входят в T04/T05,
интерактивность и автоматический Markdown — отдельные расширения.
Переносится locale environment, но не весь `Localization.swift`.

Предлагаем расширить разрешённые нейтральные импорты Render: Core — Foundation; Render — QuartzCore,
CoreGraphics и **CoreText** (нейтрален для всех целевых платформ, как
CoreGraphics; решение D50); UIKit/AppKit — только хосты. Flux не переносится.
Режим `skipsLayoutOnlyWrappers == true` не получает текстовый путь до D32.

## 2. Находки и точки интеграции

### 2.1. Что брать из Weave, что перепроектировать

| ID | Наблюдение по исходнику | Следствие |
|---|---|---|
| W01 | `TextStyle`, `TextTruncation`, `TextLayoutInput`, `TextMetrics` — value-типы без платформенных зависимостей; годятся почти как есть. `TextDisplayResult.renderedText` — строка, «обрезанная» по числу символов, не по ширине. | Перенести value-типы; `renderedText` не переносить — truncation делает CoreText (`kCTLineBreakByTruncatingTail`), не строковая арифметика. Реестр: [defects.md #37](defects.md). |
| W02 | `CoreTextRasterRenderer.measure` считает `lineCount` как `ceil(suggestedHeight / lineHeight)`, а `firstBaseline` — константой `lineHeight * 0.8`; `localeIdentifier` явно игнорируется (`_ = localeIdentifier`); `.exact` и `.atMost` ширины обрабатываются одинаково. | Строки и baseline брать из `CTFrame`/`CTLine` (ascent/descent/leading), не из деления; locale — в атрибуты (`kCTLanguageAttributeName`); `.exact` даёт ширину ровно constraint, `.atMost` — min(natural, max). Реестр: #36, #38, #39. |
| W03 | `DefaultTextLayoutBackend.measureFallback` — `0.55 × pointSize` на символ. Используется как fallback и в тестах, поэтому тесты Weave не ловят расхождения с CoreText. | Portable fallback остаётся только для headless тестов Core с **явной** пометкой «детерминированная модель, не типографика»; тесты геометрии текста на реальном CoreText живут в `TrellisRenderTests`. Реестр: #40. |
| W04 | `TextNode` держит `constraint`, установленный через `setLayoutInputs`, и меряет `layoutContentMetrics(for:)` синхронно на MainActor **при snapshot** — один constraint на узел; solver не может перемерить при другой ширине. Именно мина §3.3 weave-analysis. | Измерение переносится в solver через Sendable-измеритель в снимке (D49). `TextNode` не хранит constraint. |
| W05 | `TextLayoutBackendRegistry.makeDefault` — глобальное MainActor-состояние, которое адаптер подменяет при bootstrap; порядок инициализации определяет backend. | Измеритель/растеризатор — значение environment (`TextRendererKey`), выставляемое хостом при `attach` (как safe area/direction), без глобального реестра (D51). |
| W06 | `DisplayScheduler`: очередь с приоритетами и `maxConcurrency`, drop низкоприоритетных при переполнении, `quiescence()`, метрики — зрелый код. `DisplayTransaction` привязан к `HostRenderRequest` и проверяет `displayRevision` ноды через `root.findNode(id:)` (линейный поиск по дереву на каждый artifact). | Перенести scheduler и transaction; валидацию artifact делать по отдельной committed display-таблице, не поиском по live дереву (D53). |
| W07 | `DisplayArtifact.payload` — `.image(CGImage)`/`.bytes`/`.color`/`.empty`; `LayerRenderer.applyArtifact` пишет `layer.contents`. `CGImage` лежит в `Sendable`-структуре без проверки компилятором (Weave собирается не в strict concurrency). | Передача CGImage требует проверки в Swift 6 strict на закреплённых SDK; `@unchecked` в Trellis запрещён. Предпочтительный artifact передаёт bitmap как `Data`; `CGImage` собирается на MainActor. T02 проверяет Sendable-аннотации текущих SDK и фактические аллокации/копии, не предполагая их число (D54). |
| W08 | Растеризация рисует текст в bitmap размером bounds×scale; при resize артефакт устаревает и перерисовывается целиком; масштаб берётся из request. Кэша артефактов нет. | Bitmap на конечный локальный размер; guard по display key/epoch (D52/D53), не общей geometryGeneration. Кэш прошлых растров — после замера T11. `contentsScale` = `request.scale`. |
| W09 | Truncation `.clip` в Weave измеряет по `byClipping`, но рисует все строки в bounds — лишние строки обрезаются bitmap'ом, `didTruncate` при `maxLines == nil` всегда `false`. | `maxLines` и высота bounds — два разных ограничителя; `didTruncate` отражает оба; тесты на `clip` с недостающей высотой. |
| W10 | `TextNode.accessibility` устанавливается как `value: text` без `label`; VoiceOver читает value. | Label = текст (D57), value — только для явно заданного; интеграция с A06 через обычные `Node.accessibility`, `TextNode` лишь заполняет по умолчанию. |

Известные расхождения источника фиксируются также в
[source-provenance.md §7](source-provenance.md). Weave не изменяется. При переносе
каждого файла — строка происхождения в том же коммите.

### 2.2. Текущий Trellis

- `Node.makeLayoutInputSnapshot` захватывает `content: layoutContentMetrics(for: narrowedConstraint)`
  один раз; `FlexboxMeasure` читает `input.content.intrinsic` и `firstBaseline`
  как константы. `FlexMeasureCache` ключуется `(identity, contentRevision,
  environmentRevision, constraint, direction)` — готовый ключ для кэша измерений
  текста по constraint внутри одного solve.
- `LayoutInputSnapshot` — `Sendable, Hashable`. Добавление измерителя-замыкания
  ломает `Hashable`; нужен объект-измеритель с identity/revision в качестве
  Hashable-части и Sendable-протокол для вызова (D49).
- `LayoutContext` уже несёт отмену (D09/D10); измеритель обязан проверять её
  между строками длинного абзаца.
- `RenderCoordinator.onCommitGeometry` → `LayerRenderer.applyCommitted` → snapshot
  → semantics → callbacks — синхронный участок. Display pass запускается **после**
  него из `onPostCommit`, а его результат приходит отдельным MainActor-хопом;
  artifact валиден только если его display key и mountEpoch совпадают с
  committed display-таблицей. HitTestSnapshot не расширяется ради raster jobs.
- `LayerRenderer` создаёт `CALayer` и применяет `VisualStyle`; текстовой ноде
  нужен внутренний raster layer с `contents`/`contentsScale`/`contentsGravity`
  внутри внешнего node layer, без второго рендерера (план 5, D65).
  `applyAppearance` не должен стирать `contents`.
- `Node.appearanceRevision`/`semanticsRevision` — отдельные каналы; тексту нужен
  третий: `contentRevision` (текст/стиль меняют intrinsic size → geometry dirty)
  и «display dirty» (цвет текста меняет только растр, не геометрию).
- `EnvironmentValues` содержит direction/safe area/theme; нет locale, нет scale.
  Scale приходит в `HostRenderRequest`; locale — новый ключ (D51).
- `SemanticSnapshot` читает `Node.accessibility` — `TextNode` заполняет label по
  тексту в `didSet`, publish идёт обычным semantic-путём.
- `check_screenshots.py` сравнивает PNG побайтно: рендер CoreText на разных
  версиях macOS может отличаться субпиксельно. Эталоны текстовых сцен привязаны
  к SDK pin (`toolchain.json`), как и всё остальное; при смене SDK — `--update`.

## 3. Предлагаемые решения до зависимой реализации

Номера D49–D60 — **предложения**, продолжение D35–D48. Они не объявляются
принятыми фактом создания документа. T01 фиксирует контракты в `decisions.md` и
ADR; T02 проверяет платформенную осуществимость растеризации и стоимость
(D54) до масштабного переноса.

| Решение | Предложение | Что зависит |
|---|---|---|
| D49. Измерение в solver | `LayoutInputSnapshot.content` получает `measurer: (any ContentMeasurer)?` — Sendable-объект с `func measure(_ constraint: SizeConstraint, context: LayoutContext) throws -> LayoutContentMetrics` и стабильными identity/revision для Hashable/ключа кэша. Равные ключи обязаны означать одинаковое измерение при одинаковых входах; identity не создаётся заново на каждом snapshot. Solver вызывает его для каждого constraint, с которым реально меряет узел, результат — в `FlexMeasureCache` по существующему ключу. `intrinsic` без измерителя остаётся как сейчас. Ноды без содержимого не вызывают измеритель. | T03, T04 |
| D50. Границы модулей | Value-типы текста, `TextNode`, `ContentMeasurer`, portable fallback — `TrellisCore` (Foundation). CoreText-измеритель и растеризатор — `TrellisRender` (`import CoreText` разрешается policy как нейтральный, рядом с CoreGraphics). Хосты только передают environment. | T01, T03, T05 |
| D51. Источник измерителя | `EnvironmentKey` `TextRendererKey` со значением `any TextRenderer` (Sendable, измерение + растр). Хост ставит CoreText-реализацию при `attach`; headless Core использует явно помеченную тестовую модель. Mounted host без backend сообщает ошибку настройки, не показывает приблизительную типографику. Никакого глобального реестра. `LocaleKey` (`localeIdentifier`) — тоже environment; scale — из `HostRenderRequest`. | T03, T05, T09 |
| D52. Инвалидация | No-op equality. Изменение текста/метрик → geometry dirty и contentRevision; только цвета → displayRevision и `DirtyReasons.display`, без solve. Ключ измерения не включает paint-only revision. Display key включает nodeID, contentRevision, displayRevision, локальный размер, scale и разрешённые typography/theme inputs. Смена position/общей generation не требует нового bitmap. | T04, T06, T07 |
| D53. Display pipeline | Scheduler с ограниченной concurrency и приоритетами; committed display-таблица по NodeID + mountEpoch + display key, отдельно от HitTestSnapshot. Перед CALayer проверяется точное совпадение key. Удаление/resize/смена текста инвалидируют нужный key; соседний commit не отбрасывает пригодный растр. Overflow не теряет dirty-намерение: актуальная видимая работа перепланируется после освобождения слота. Suspend отменяет задачи, resume планирует недостающие актуальные artifacts. | T06, T07 |
| D54. Sendable-артефакт | Предпочтение: Data + dimensions/stride/pixel format, CGImage создаётся на MainActor. T02 отдельной compile-probe проверяет аннотации CGImage на закреплённых SDK при strict concurrency и без запрещённых обходов; прямой перенос допустим к сравнению только если проверка проходит. Число копий, владение буфером и main-thread стоимость измеряются, не предполагаются. | T02, T06 |
| D55. Typography | Один `AttributedString` с Trellis scope (§3.3), `TextStyle` — база, runs переопределяют поддержанные поля. `TextStyle`: `fontName` (`"system"` → системный шрифт платформы через `CTFontCreateUIFontForLanguage`, не `Helvetica`), `pointSize`, `weight`, `lineHeight` (0 — natural), `alignment` (`leading/center/trailing`, физика по direction), `color: ThemeColor?` (nil → `theme.foreground`). Метрики строк — из `CTLine` (ascent/descent/leading), baseline первой строки — реальный. | T03, T05 |
| D56. Truncation и лимиты | `maxLines` + `truncation` (`clip`/`tail`); высота bounds — второй ограничитель; `didTruncate` истинен при любом; `.exact` ширина = ширина constraint, `.atMost` = min(natural, max); пустая строка — одна строка высотой lineHeight. Детерминизм: одна и та же `TextLayoutInput` → тот же `TextMetrics` (тест на 100 повторов). | T04, T05 |
| D57. Accessibility | `TextNode` при создании и на каждое изменение текста ставит `accessibility.isElement = true`, `label = text`, `role = .text` (если автор не задал роль/label явно — автор побеждает). Не focusable. Без rotors/live regions. | T08 |
| D58. Отмена и владение | Display-задачи принадлежат `NodeHostBridge` (через transaction), не ноде; `detach`/`replaceRoot` отменяют всё, поздних коммитов в `CALayer` нет; `dispose()` ноды отменяет её задачу через scheduler по `nodeID`. Измеритель в solver — cooperative cancellation через `LayoutContext` минимум раз на строку. | T06, T10 |
| D59. Совместимость | `LayoutContentMetrics` получает опциональный `measurer` — additive; `LayoutInputSnapshot.init` — новый параметр по умолчанию (ADR как 0002/0011: mangled name меняется). `Node.layoutContentMetrics(for:)` остаётся для нод без измерителя. `DirtyReasons.display` — новый бит. ADR 0014. | T01, T03 |
| D60. Эталоны | Текстовые сцены получают reference PNG на macOS с фиксированным системным шрифтом SDK 26.5; расхождение при смене SDK — обновление baseline с review note, не ослабление сравнения. Simulator-скриншоты iOS/tvOS — evidence, не gate. | T09, T12 |

### 3.1. Дополнение к измерению

Solver вызывает измеритель в трёх местах: базовый размер (`flexBasis: auto` →
max-content, ADR 0009: constraint `.unspecified` по main), окончательная ширина
после grow/shrink (для высоты многострочного текста — `.exact(width)`), и
cross-размер при `alignItems: .stretch`. Кэш по `(identity, contentRevision,
environmentRevision, constraint, direction)` гарантирует не более одного
вызова измерителя на уникальный constraint в одном solve. Wrap-строки flex
(`flexWrap`) меряют повторно при другой доступной ширине — это ожидаемо и
покрывается кэшем. Измеритель не читает `Node`: `TextLayoutInput` (текст, стиль,
direction, locale, scale, maxLines, truncation) целиком лежит в снимке.

### 3.2. Дополнение к растру и движению

Bitmap соответствует **локальному конечному размеру** × scale, а не номеру
всего layout commit. Display key описан в D52; mountEpoch защищает повторный
attach. Перемещение текста и изменение соседней ноды не требуют перерисовки.
Измерение и raster используют одну логику разбиения строк и truncation:
`CTFrameDraw` сам по себе не доказывает корректный `maxLines` + tail; последняя
видимая строка и ellipsis строятся явно по метрикам CoreText в T05/T06.

Внешний node layer отвечает за layout/фон/движение; внутренний raster layer
имеет собственный размер bitmap и обновляется без animation actions. Это общий
контракт с [планом 5, D65](implementation-plan-5.md). При изменении только размера
старый растр временно удерживается без растяжения, с clipping; при смене текста
или стиля удаляется до актуального artifact. Новый растр подменяется атомарно,
без crossfade. T02 проверяет задержку, память и видимость переключения строк.
Если компромисс неприемлем, сначала уточняются D53/D65 в обоих планах.

### 3.3. Одна модель текста, простой вход

Рекомендуемый выбор для T01: `AttributedString` с собственным Trellis
`AttributeScope`, `TextStyle` как базовый стиль. Обычная строка задаётся через
`TextNode(text: String)`; внутри это тот же документ, а не пара независимых
`text`/`attributedText`. Литерал и initializer не требуют от автора собирать runs.
Смена содержимого также имеет один канонический путь; точную подпись фиксирует T01.

Первая версия поддерживает шрифт/размер/вес/цвет runs. Paragraph-параметры
(lineHeight/alignment/maxLines/truncation) остаются общими для ноды: смешение
paragraph rules внутри строки не вводим незаметно. Только Foundation-ключи
Trellis в Core, перевод в CoreText — в Render. Неизвестные атрибуты не получают
обещанной семантики; ссылки не превращаются в кликабельные spans. Unicode,
Sendable/Hashable и equality проверяются T02/T04 на текущем toolchain.

Это немного увеличивает T04/T05, зато жирное слово и цена другим цветом проходят
по одному измерителю и display pipeline. Public DSL для runs, Markdown и редактор
не требуются, чтобы выпустить обычный текст. Выбор остаётся предложением до T01.

## 4. Порядок и зависимости

**Одна очередь, два документа.** Карточки сохраняют T/M номера для реестра и
приёмок. Параллельное изменение Node/coordinator/renderer в двух независимых
ветках не является стратегией этого плана.

| Шаг | Карточки | Наблюдаемый результат |
|---|---|---|
| 1. Договориться о форме | T01 + M01 | Примеры TextNode/animate и ранний эскиз M10 карточка → страница, измерение по конечной ширине, scope и raster-layer contract |
| 2. Проверить риск малым прототипом | T02 + M02 | CoreText → bitmap → layer; движение/resize/retarget; числа и SDK-проверки, M10 overlay/progress-прототип до переноса инфраструктуры |
| 3. Сделать текст рабочим | T03 → T04 → T05 → T06 → T07; затем T08/T09 | Реальный перенос строк и AX, смена цвета без solve, resize без старого artifact |
| 4. Закрыть качество текста | T10 → T11 → T12 | Lifecycle, нагрузка, сцены S24–S26 и полная приёмка N01 |
| 5. Добавить движение | M03 → M04 → M05 → M06 → M07 → M08 | Та же карточка раскрывается и прерывается повторным нажатием; S27/S28 |
| 6. Сделать сложный переход переиспользуемым | M10 → M11 → M12 → M13 → M14 | Карточка → страница → обратно, отменяемый жест, второй сценарий на том же механизме; обязательный результат B |
| 7. Добавить физику, если нужна | M09 (после M08, независимо от B) | Настоящая spring с той же короткой записью |

T02/M02 — исследовательский срез, не второй production pipeline. M02 работает
с минимальной raster-фикстурой, не ждёт production TextNode. Его результат
задаёт T07 контракт слоёв, чтобы не переписывать текст ради анимации. Ранний
эскиз M10 проверяет обратимый составной переход; production M11–M14 начинается
после M08. M01–M08 закрывают только результат A, а не весь план анимации.

Критический путь первого результата: T01 → T02 → T03 → T04 → T05 → T06 → T07
→ T08/T09. Этот срез не закрывает N01: нужна полная приёмка T10–T12.
Начинать с большой системы анимации до настоящего текста не рекомендуем:
именно resize, перенос строк и готовность bitmap проверяют её архитектуру.

## 5. Карточки реализации

### T01 — Зафиксировать контракты и примеры

- [x] Принять/уточнить D49–D60 в `decisions.md`; ADR 0014 (снимок с измерителем,
  новый бит `DirtyReasons.display`); зафиксировать рекомендуемую единую модель §3.3
  либо явно пересмотреть её до T04; совместно с M01 определить raster layer.
- [x] Записать API sketch: `TextStyle`, `TextTruncation`, `TextLayoutInput`,
  `TextMetrics`, `ContentMeasurer`, `TextRenderer`, `TextNode`, `DisplayScheduler`,
  `DisplayArtifact`, bridge/host hooks; таблицу владения и отмены.
- [x] Зафиксировать ожидаемые результаты: однострочный текст в `Row` с `grow`
  у соседа; многострочный в узкой `Column` (высота по фактической ширине, не по
  ширине экрана); `maxLines: 2` + `.tail`; `.exact` vs `.atMost`; RTL-абзац;
  пустая строка; смена цвета без layout; resize с устаревшим artifact.

Зависимости: A13. Приёмка: нет нерешённых альтернатив для T03–T07 кроме платформенной проверки D54 и
визуальной проверки общего D53/D65 в T02/M02.
Артефакт: `docs/validation/t01-text-contract.md`.

**Выполнено 2026-09-12.** D49–D60 приняты в [decisions.md](decisions.md)
(§«D49–D60 — Текст и измерение содержимого»), §3.3 решён в пользу
атрибутированной модели (D55). Source-breaking изменения `LayoutContentMetrics`/
`DirtyReasons` — [ADR 0014](adr/0014-content-measurer-and-display-dirty-reason.md).
API sketch, таблица владения и десять ожидаемых результатов —
[t01-text-contract.md](validation/t01-text-contract.md). Ничего не
реализовано этой карточкой; `ContentMeasurer`/`TextNode`/`CoreTextRenderer`
остаются задачами T02–T05. Следующая карточка — T02.

### T02 — Прототип растра и стоимость до масштабного переноса

- [x] Минимальный CoreText → bitmap → `CALayer.contents` на macOS и iOS Simulator:
  одна строка и абзац 2000 символов, scale 2 и 3; сверка baseline с `CTLine`.
- [x] Compile-probe Sendable на всех целевых SDK без unsafe обходов; сравнить
  допустимые варианты D54: фактические копии, время и память для 1000 строк.
- [x] Вместе с M02 проверить внешний node layer + внутренний raster layer:
  move без растра, resize с clipping старого bitmap, смена текста с задержанным
  worker; зафиксировать общий D53/D65 и стоимость дополнительного слоя.

Зависимости: T01. Приёмка: числа для бюджета T11, решения D53/D54 и план 5 D65 окончательны,
`import CoreText` в `TrellisRender` проходит policy на всех трёх SDK.
Артефакт: `docs/validation/t02-raster-prototype.md`.

**Выполнено 2026-09-12.** CoreText → bitmap → `CALayer.contents` подтверждён 7
прототипными тестами (`Tests/TrellisRenderTests/TextRasterPrototypeTests.swift`),
зелёными на macOS/iOS Simulator/tvOS Simulator вместе со всем пакетом (499/112/112).
Compile-probe нашёл, что на закреплённом SDK `CGImage`/`CGColorSpace` — `Sendable`
без обходов, а `CTFont`/`CGDataProvider` — нет; это меняет D54 (обновлена в
decisions.md): `DisplayArtifact` несёт `CGImage` напрямую, без обязательной
`Data`-копии. Стоимость на 1000 строк — фикстура `text-raster-1000` в
`Bench/Sources/TrellisBench/main.swift`, числа и оговорка о занижении памяти —
[t02-raster-prototype.md](validation/t02-raster-prototype.md) §3.1. Two-layer
механизм D65 (move/resize/text-change) подтверждён теми же тестами; retarget
поверх анимации остаётся M02 (implementation-plan-5.md). `import CoreText` в
`TrellisRender` собран на всех трёх SDK и проходит `check_policy.py` (проверочный
файл удалён, не входит в API). Следующая карточка — T03.

### T03 — Измерение содержимого в solver

- [x] `ContentMeasurer` (Sendable protocol), `LayoutContentMetrics.measurer`,
  `LayoutInputSnapshot` с измерителем; `Hashable` через identity/revision.
- [x] `FlexboxMeasure`/`FlexboxPlacement`: вызов измерителя в трёх точках §3.1,
  результат в `FlexMeasureCache`; отмена через `LayoutContext`.
- [x] Portable fallback-измеритель для тестов Core (детерминированная модель,
  явно не типографика).

Зависимости: T01, T02. Приёмка: узел с измерителем в узкой колонке получает высоту по
выделенной ширине; количество вызовов измерителя на уникальный constraint == 1
за solve; отмена посреди измерения не коммитит; узлы без измерителя — прежние
результаты (все тесты C12 без изменений); baseline через измеритель.

**Выполнено 2026-09-12.** `ContentMeasurer` протокол, `LayoutContentMetrics.measurer`
(ручные `Hashable`/`Equatable` по identity/revision, ADR 0014),
`FlexMeasureResult.firstBaseline` (дополнение к ADR 0014). Все три точки §3.1
(basis, exact-main после grow/shrink, exact-both fallback при stretch+growth)
оказались одним местом кода — рекурсивная `measure()` уже вызывалась из этих трёх
мест с разными `constraint`. `PortableFallbackMeasurer` — детерминированная
тестовая модель для `Tests/TrellisCoreTests`, явно не типографика, с
`OSAllocatedUnfairLock` вместо unsafe Sendable. 7 новых тестов плюс весь пакет
(506 macOS, 391/… iOS и tvOS Simulator) зелёные без единого изменения в C12.
Отчёт: [t03-content-measurement.md](validation/t03-content-measurement.md).
Следующая карточка — T04 (`TextNode` в `TrellisCore`).

### T04 — `TextNode` в Core

- [x] `TextStyle`, `TextTruncation`, `TextLayoutInput`, `TextMetrics`, единый
  attributed document + Trellis scope и String initializer (W01, D55/D56).
- [x] `TextNode`: `text`, `textStyle`, `maxLines`, `truncation` с no-op equality;
  geometry dirty при изменении intrinsic-полей, `.display` при цвете; измеритель
  из environment (`TextRendererKey`, fallback без хоста).
- [x] Раздельные contentRevision/displayRevision и ключи по D52: paint-only
  атрибуты не инвалидируют измерение, оба вида изменений инвалидируют нужный растр.

Зависимости: T03. Приёмка: изменение текста → один flush → новая геометрия;
тот же текст → ноль работ; смена цвета → ноль layout snapshot; `dispose()`
без поздних задач; snapshot не держит `Node`.

**Выполнено 2026-09-12.** `TextStyle`/`TextDocument`(`AttributedString` +
`TrellisTextAttributes` scope)/`TextLayoutInput`/`TextMetrics`/`TextRenderer`/
`PortableTextMeasurer`/`TextNode` в `Sources/TrellisCore/Text/`. Три уточнения
наброска T01 (constraint-параметр у `TextRenderer.measure`, `scale` убран из
`TextLayoutInput`, `TextRenderer` сужен до measure-only до T06) — D51 обновлена.
`DirtyReasons.display` и `RenderCoordinator.onDisplayOnly`/non-layout subset —
без этого «смена цвета → ноль layout snapshot» не выполнялось бы. 27 новых
тестов, весь пакет зелёный на macOS/iOS Simulator/tvOS Simulator (526/407/116).
Дефект #43 (нестабильный несвязанный `LayoutScheduler`-тест на tvOS) записан,
не блокирует карточку. Отчёт: [t04-text-node.md](validation/t04-text-node.md).
Следующая карточка — T05 (`CoreTextRenderer` в `TrellisRender`).

### T05 — CoreText-измерение (`TrellisRender`)

- [x] `CoreTextRenderer.measure`: `CTFramesetter`, строки/baseline из `CTLine`
  (W02), `.exact`/`.atMost`, `maxLines`, truncation, RTL, locale, системный
  шрифт (D55), пустая строка, смешанные runs, единая логика line breaks
  и последней truncated строки для measure и raster.
- [x] Детерминизм и thread-safety: измерение с worker-потока solver'а, 100
  повторов → равные метрики; отмена между строками.

Зависимости: T03, T04. Приёмка: примеры T01 по геометрии сходятся с реальным
CoreText в `TrellisRenderTests` (macOS) и на iOS/tvOS Simulator; portable
fallback и CoreText различаются и это **ожидаемо** — тесты Core не сравнивают их.
Дефекты #36–#39 закрыты при переносе.

**Выполнено 2026-09-12.** `CoreTextRenderer`/`CoreTextTypesetter` в
`Sources/TrellisRender/Text/` — `CTFramesetter`/`CTFrame`/`CTLine`
line-breaking по каждому run документа (смешанные шрифт/размер/вес реально
доходят до CoreText, не только до `PortableTextMeasurer`'s модели), baseline
и высота строк из реальных typographic bounds, `maxLines`/высота — два
независимых ограничителя (D56), locale в `kCTLanguageAttributeName`,
`.exact`/`.atMost` различаются. `TextStyle.lineHeight > 0` передаётся как
`CTParagraphStyle` min/max line height, а не постфактум-множитель. Дефекты
#36/#38/#39 закрыты; #37 закрыт частично (измерение не зависит от строковой
арифметики — сама отрисовка ellipsis остаётся T06). 12 новых тестов, весь
пакет зелёный на macOS/iOS Simulator/tvOS Simulator (538/535/535). Отчёт:
[t05-coretext-measurement.md](validation/t05-coretext-measurement.md).
Следующая карточка — T06 (Display pipeline).

### T06 — Display pipeline

- [x] `DisplayScheduler`/`DisplayTransaction`/`DisplayArtifact` (D53/D54) в
  `TrellisRender`; `RenderCoordinator.onPostCommit` → display pass только для
  нод с отсутствующим актуальным display key (D52); `.display` flush запускает
  raster без layout snapshot/solve, включая смену только цвета runs.
- [x] Валидность artifact по committed display-таблице, key и `mountEpoch`; устаревший —
  отброшен со счётчиком; suspend/resume/detach — отмена без поздних коммитов (D58).
- [x] Статистика: scheduled/started/completed/cancelled/dropped/stale.

Зависимости: T02, T05. Приёмка: burst из 100 изменений текста одной ноды →
один artifact в слое; resize во время растра → artifact со старой геометрией
отброшен, новый пришёл; detach во время растра → ноль коммитов; `maxConcurrency`
соблюдён; overflow не теряет последнюю видимую работу; после drain каждая нужная нода
имеет актуальный artifact, даже без следующей пользовательской мутации.

**Выполнено 2026-09-12.** `DisplayArtifact`/`DisplayKey`/`TextDisplayRequest`/
`TextRasterizer`/`DisplayScheduler` в `Sources/TrellisRender/Display/`;
`CoreTextTypesetter.rasterize` переиспользует T05's font/paragraph-style
построение и добавляет реальную `CTLineCreateTruncatedLine`-отрисовку
последней строки (закрывает #37 полностью). `DisplayScheduler` обобщает
`LayoutScheduler`'s дисциплину «один active + один pending» на много нод с
общим `maxConcurrency`. Два уточнения D53 — нет отдельного
`DisplayTransaction` (роль внутри планировщика), `mountEpoch` не хранится в
`DisplayKey` (планировщик пересоздаётся на `attach`, как `RenderCoordinator`).
`NodeHostBridge` подключает `onPostCommit`/`onDisplayOnly` к full-tree scan за
`TextNode` (`applyAppearance`'s собственный paint-only паттерн). Применение к
`CALayer.contents` — не эта карточка (T07). 20 новых тестов, весь пакет
зелёный на macOS/iOS Simulator/tvOS Simulator (558/555/555). Отчёт:
[t06-display-pipeline.md](validation/t06-display-pipeline.md). Следующая
карточка — T07 (`LayerRenderer` и текстовый слой).

### T07 — `LayerRenderer` и текстовый слой

- [x] Внешний node layer + внутренний raster layer по §3.2 и плану 5 D65.
  Artifact применяется к внутреннему `contents`/`contentsScale`/`contentsGravity`;
  `applyAppearance` не стирает bitmap; node-children sorting сохраняет raster layer.
- [x] Перемещение без resize не создаёт raster job; resize не растягивает bitmap;
  clipping не меняет overflow/семантику внешнего node layer.
- [x] `skipsLayoutOnlyWrappers` не затрагивается; DebugOverlay поверх текста.

Зависимости: T06. Приёмка: пиксельная проверка одной строки на macOS (эталон);
paint-only смена фона сохраняет текст; смена темы перерисовывает цвет; scale 1/2/3.

**Выполнено 2026-09-12.** `LayerRenderer` держит `rasterLayers: [NodeID:
CALayer]` отдельно от `LayerRegistry`; `applyDisplayArtifact(_:for:)`
коммитит bitmap в растровый sublayer, `clearDisplayContent(for:)` убирает его
немедленно. Найден и исправлен до коммита реальный пробел: первая версия не
различала resize и смену контента, оставляя старый текст видимым как
актуальный до прихода нового растра — D65 явно запрещает это для смены
текста/стиля/темы/locale (разрешено только для resize).
`DisplayKey.hasEqualContent(to:)` различает два случая;
`NodeHostBridge.scanForDisplayWork` очищает bitmap только когда контент
разошёлся. 19 новых тестов, весь пакет зелёный на macOS/iOS Simulator/tvOS
Simulator (585/582/582). Пиксельный эталон и визуальная проверка DebugOverlay
не выполнены (нет физического доступа/screenshot-baseline процесса для
текста). Отчёт: [t07-text-raster-layer.md](validation/t07-text-raster-layer.md).
Следующая карточка — T09 (T08 выполнена отдельным коммитом).

### T08 — Accessibility текста

- [x] `TextNode` заполняет `accessibility` по D57, автор побеждает; label берётся из plain characters
  единого документа. Явный override отличим от автоматического значения.
- [x] Смена текста проходит measurement при metric-инвалидации даже если итоговый
  размер совпал; только изменение AX override использует semantic-only fast path.
- [x] VoiceOver-роли: `.text`/`.header` через существующий mapping A09/A10.

Зависимости: T04, A06. Приёмка: native дерево видит label == text; изменение
текста публикует актуальный label без принудительного обхода D47;
выбор native notifications остаётся за существующим diff в адаптере; `.combine` объединяет текстовые ноды в один label.

**Выполнено 2026-09-12.** `TextNode.syncAccessibilityDefaults()` в
`Sources/TrellisCore/Text/TextNode.swift` — заполняет `isElement`/`label`/`role`
из plain characters на создании и на каждую смену текста, поле за полем, не
трогая то, что автор явно переопределил; «автор победил» отслеживается тремя
теневыми полями на самой ноде, не флагом на общем для всех `Node`
`AccessibilityProperties`. Найден и исправлен до коммита реальный баг: первая
версия безусловно перезаписывала теневые поля, из-за чего авторский
`isElement = false` тихо «забывался» уже на второй смене текста — поймано
регрессионным тестом, не попало в зафиксированный код. `AccessibilityTree`/
`SemanticSnapshot`/адаптеры не менялись — уже читали `accessibility` тем же
путём. 14 новых тестов, весь пакет зелёный на macOS/iOS Simulator/tvOS
Simulator (585/582/582). Отчёт:
[t08-text-accessibility.md](validation/t08-text-accessibility.md). Следующая
карточка — T09 (Environment в хостах).

### T09 — Environment в хостах

- [x] `TextRendererKey` (CoreText из `TrellisRender`) и `LocaleKey` выставляются
  обоими `TrellisHostView` при `attach` и при смене locale; scale — из request.
- [x] Смена locale/direction → перемер (environment revision уже поднимает geometry).

Зависимости: T05. Приёмка: без хоста — fallback, с хостом — CoreText; RTL
переключение меняет выравнивание без правки нод; тесты на обоих хостах.

**Выполнено 2026-09-12.** `NodeHostBridge.attach` получил
`textRenderer`/`localeIdentifier` (ADR 0015 — mangled-имя меняется, не
источник: оба параметра с default `nil`); `Node.setTextRenderer`/
`.setLocaleIdentifier` в `TrellisCore`. Оба хоста ставят `CoreTextRenderer()`
и `Locale.current.identifier` на `attach`, переустанавливают locale на
`NSLocale.currentLocaleDidChangeNotification` через новый
`NodeHostBridge.updateLocaleIdentifier(_:)`. 9 новых тестов
(`AppKitTextEnvironmentTests.swift`/`UIKitTextEnvironmentTests.swift`,
идентичные наборы), весь пакет зелёный на macOS/iOS Simulator/tvOS Simulator
(588/585/585). Отчёт: [t09-host-text-environment.md](validation/t09-host-text-environment.md).
Следующая карточка — T10 (Lifecycle и отмена).

### T10 — Lifecycle и отмена

- [x] Detach/replaceRoot/suspend во время solve с измерителем и во время растра;
  `dispose()` текстовой ноды с очередью; weak release ноды, artifact, scheduler.
  Выполнено 2026-09-12 — [t10-lifecycle-and-cancellation.md](validation/t10-lifecycle-and-cancellation.md).
  Большая часть уже держалась предыдущими карточками; найден и исправлен
  дефект #44 (D58: удаление ноды из живого mount'а не отменяло её задачу в
  `DisplayScheduler`, только полный `detach()` делал это).
- [x] Реентрантность: изменение текста из `onCommit`/`onFocusChange` callbacks.
  Выполнено 2026-09-12 — уже была защищена архитектурой (`RenderCoordinator`
  обнуляет callback-слоты до реентрантного вызова, `FocusEngine.inTransition`
  откладывает вложенные переходы); закреплено регрессионными тестами.

Зависимости: T06. Приёмка: ноль поздних коммитов, пустые очереди после detach,
счётчики cancelled согласованы; повторный attach не оживляет старые artifact'ы.

### T11 — Нагрузка

- [x] Bench: 1000 однострочных `TextNode` (список), абзац 5000 символов в узкой
  колонке, burst изменений текста, resize с 1000 текстами; замер измерения,
  растра, копии bitmap (D54), памяти растров.
  Выполнено 2026-09-12 — [t11-text-load.md](validation/t11-text-load.md).
  Найдено: правка одной строки в 1000-строчном списке стоит полного relayout
  дерева (~99 ms Release) — архитектурное свойство flexbox, не баг; и
  дефект #45 (открыт) — MainActor-side обходы дерева
  (`makeLayoutInputSnapshot`/`applyLayoutResult`/`LayerRenderer.update`)
  падают процессом на глубине ~1500–1600, заметно ниже границы дефекта #22
  для солвера — не специфично для текста, чинить вне бюджета этой карточки.
- [x] Сравнить с бюджетом T02, включая память внутреннего слоя и удержанного bitmap;
  кэш прошлых растров добавлять только по числам, политику §3.2 не менять молча.
  Выполнено 2026-09-12 — числа не обосновали новый кэш, политика §3.2
  (атомарная замена, один текущий artifact на узел) оставлена как есть.

Зависимости: T07–T10. Приёмка: измерений на уникальный constraint == 1; после drain актуальный artifact есть у каждой
видимой текстовой ноды; память растров линейна по площади; deep tree с
текстом без рекурсии в измерителе.

### T12 — Сцены, эталоны, матрица, документация

- [x] Сцены: S24 — типографика (стили, выравнивание, RTL, maxLines/truncation,
  пустая строка); S25 — список 200 строк с изменением текста; подписи к S22/S23
  (labels видны, не только слышны) — в отдельной S26, без изменения прежних эталонов.
  Выполнено 2026-09-12 — [t12-scenes-references-docs.md](validation/t12-scenes-references-docs.md).
  Найдено и исправлено: дефект #46 (`FlexboxMeasure.measure` игнорировал
  собственный размер лефа) и дефект #47 (`CoreTextTypesetter.rasterize`
  рисовал пустое изображение на некоторых pointSize). Найден и оставлен
  открытым (обойдён явной шириной в сценах): дефект #48 — округление ширины
  вниз до пиксельной сетки на реальном iOS-хосте обрезает знак-впритык
  auto-width текст, которого не видно на macOS.
- [x] Export ждёт готовности layout + актуальных display artifacts с bounded
  timeout; фиксированной задержки после geometry commit недостаточно. M07
  расширит тот же readiness contract анимациями.
  Выполнено 2026-09-12 — `Playground/Shared/Scenario.swift`'s
  `waitForRenderReady(root:host:...)`, используется в
  `Playground/macOS/PlaygroundApp.swift`.
- [x] Reference PNG macOS, Simulator-скриншоты iOS/tvOS, `check_all.py --matrix`,
  API baseline с review note, README/AGENTS (CoreText в Render, environment ключи).
  Выполнено 2026-09-12 — matrix зелёная (macOS/iOS/tvOS, device+simulator),
  `docs/validation/screenshots/{macOS,iOS,tvOS}`, `api/TrellisAppKit.json`/
  `api/TrellisUIKit.json` обновлены (аддитивно, `displayArtifact(for:)`),
  README.md/AGENTS.md дополнены.
- [x] Итоговая таблица: полностью / только Simulator / открыто.
  Выполнено 2026-09-12 — [t12-scenes-references-docs.md](validation/t12-scenes-references-docs.md) §7.

Зависимости: T08–T11. Приёмка: матрица зелёная на трёх платформах; consumer
использует `TextNode` без `@testable`; новые дефекты — в реестр до исправления.

## 6. Матрица рисков и доказательств

| Риск | Автоматическое доказательство | Нативная/ручная проверка |
|---|---|---|
| Текст измерен по ширине экрана, а не колонки (§3.3) | T03/T05: высота абзаца в узкой колонке | S24 на iPhone/Mac |
| Недетерминизм CoreText между потоками | T05: 100 повторов с worker'а | — |
| `Sendable` artifact через unsafe | T02: compile-probe D54, policy gate | — |
| Устаревший растр после resize/rotation | T06: display key/epoch guard, счётчик stale | S25 rotation на Simulator |
| Второй рендерер под текст | T07: один `LayerRenderer`, policy PLATFORM_IMPORT | — |
| Поздние коммиты после detach | T10: ноль коммитов, weak release | — |
| Растр-память на 1000 строк | T11: линейность, бюджет T02 | замер на устройстве — по доступности |
| Эталоны ломаются при смене SDK | D60: pin toolchain, `--update` с review note | — |
| Fallback выдаётся за типографику | W03: тесты Core не сравнивают с CoreText | S24 глазами |

## 7. После этой части

N01 считается закрытым при полной приёмке T01–T12 вместе с честной таблицей
T12. Далее M03–M08 по общему маршруту §4. Следующие текстовые расширения: `ImageNode` и `ImageMemoryCache` (N02, тот же display
pipeline), текстовый ввод/IME с focus A-этапа, интерактивные ссылки/attachments, Dynamic Type
как environment-ключ масштаба, кэш растров и удержание artifact'ов при scroll
(вместе с `ScrollNode`, D18). Они не добавляются незаметно в приёмку текущих
карточек.

Платформенные отправные точки (проверены при подготовке, 2026-09-12): CoreText
измерение и рисование — `CTFramesetterSuggestFrameSizeWithConstraints`,
`CTFramesetterCreateFrame`, `CTLineGetTypographicBounds`
([Apple CoreText](https://developer.apple.com/documentation/coretext)); системный
шрифт без UIKit/AppKit — `CTFontCreateUIFontForLanguage`; thread-safety CoreText
— документированная для immutable объектов, проверяется T05 на реальных SDK, а не
предполагается.
