# T01 — Контракт текста и измерения содержимого: API sketch и ожидаемые результаты

Дата: 2026-09-12. Первая карточка [implementation-plan-4.md](../implementation-plan-4.md) §5.
Решения D49–D60 приняты и перенесены в [decisions.md](../decisions.md) (§«D49–D60»);
раскладка source-breaking изменений — [ADR 0014](../adr/0014-content-measurer-and-display-dirty-reason.md).
Дефекты источника #36–#40 ([defects.md](../defects.md)) закрываются переносом в T03/T05.
Кода здесь нет — примеры §3 становятся тестами T03–T09 один в один. Раскладка
raster layer (D65) согласована с [implementation-plan-5.md](../implementation-plan-5.md)
и здесь не переопределяется, только упоминается в §2 для владения слоями.

## 1. API sketch

### 1.1. `TrellisCore` (только Foundation)

```swift
// Измерение содержимого в solver (D49).
public protocol ContentMeasurer: Sendable {
    var identity: ObjectIdentifier { get }
    var revision: UInt64 { get }
    func measure(_ constraint: SizeConstraint, context: LayoutContext) throws -> LayoutContentMetrics
}

public struct LayoutContentMetrics: Sendable, Hashable {   // ADR 0014
    public let intrinsic: MeasuredSize
    public let firstBaseline: Double?
    public let measurer: (any ContentMeasurer)?
    public init(intrinsic: MeasuredSize = .zero, firstBaseline: Double? = nil,
                measurer: (any ContentMeasurer)? = nil)
    // == / hash: (intrinsic, firstBaseline, measurer?.identity, measurer?.revision)
}

// Typography (D55) — единый attributed-документ, TextStyle как база.
public struct TextStyle: Sendable, Hashable {
    public var fontName: String              // "system" → CTFontCreateUIFontForLanguage
    public var pointSize: Double
    public var weight: TextWeight             // .regular, .medium, .semibold, .bold, ...
    public var lineHeight: Double             // 0 — natural (из CTLine)
    public var alignment: TextAlignment       // .leading, .center, .trailing (физика по direction)
    public var color: ThemeColor?             // nil → theme.foreground
}
public enum TextWeight: Sendable, Hashable { case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black }
public enum TextAlignment: Sendable, Hashable { case leading, center, trailing }
public enum TextTruncation: Sendable, Hashable { case clip, tail }

// Атрибутированный документ, Foundation AttributeScope Trellis (D55).
public struct TrellisTextAttributes: AttributeScope {
    public let fontName: FontNameAttribute
    public let pointSize: PointSizeAttribute
    public let weight: WeightAttribute
    public let color: ColorAttribute            // ThemeColor
}
public typealias TextDocument = AttributedString   // с runs, ограниченными TrellisTextAttributes

public struct TextLayoutInput: Sendable, Hashable {
    public let document: TextDocument
    public let style: TextStyle
    public let direction: LayoutDirection
    public let localeIdentifier: String
    public let scale: Double
    public let maxLines: Int?                  // nil — без предела
    public let truncation: TextTruncation
}

public struct TextMetrics: Sendable, Hashable {
    public let size: MeasuredSize              // §3.2: .exact даёт ширину constraint, .atMost — min(natural, max)
    public let firstBaseline: Double           // реальный ascent первой CTLine (снимает #38)
    public let lineCount: Int
    public let didTruncate: Bool               // maxLines ИЛИ высота bounds (D56)
}

// TextNode (T04).
open class TextNode: Node {
    public var text: String { get set }        // convenience — пишет TextDocument целиком
    public var document: TextDocument { get set }   // канонический источник, no-op equality
    public var textStyle: TextStyle
    public var maxLines: Int?
    public var truncation: TextTruncation
    public private(set) var displayRevision: UInt64   // ADR 0014 DirtyReasons.display, только цвет
    // didSet: intrinsic-поля → geometry dirty + contentRevision; color-only → displayRevision + .display
    // layoutContentMetrics(for:) не переопределяется — измерение идёт через ContentMeasurer в measurer
    // accessibility (D57): isElement/label/role по умолчанию, если автор не задал явно
}

// Источник измерителя/растеризатора — environment, не глобальный реестр (D51).
public protocol TextRenderer: Sendable {
    func measure(_ input: TextLayoutInput, context: LayoutContext) throws -> TextMetrics
    func rasterize(_ input: TextLayoutInput, size: MeasuredSize, scale: Double) throws -> DisplayArtifact
}
public enum TextRendererKey: EnvironmentKey {
    public static let defaultValue: (any TextRenderer)? = nil   // nil у смонтированного хоста — ошибка конфигурации (D51)
}
public enum LocaleKey: EnvironmentKey { public static let defaultValue = "en" }

extension DirtyReasons {
    public static let display = DirtyReasons(rawValue: 1 << 5)   // ADR 0014
}
```

### 1.2. `TrellisRender` (`CoreText` нейтрален по D50)

```swift
public struct CoreTextRenderer: TextRenderer {
    public func measure(_ input: TextLayoutInput, context: LayoutContext) throws -> TextMetrics
    // CTFramesetterSuggestFrameSizeWithConstraints, строки/baseline из CTLine (снимает #38/#39)
    public func rasterize(_ input: TextLayoutInput, size: MeasuredSize, scale: Double) throws -> DisplayArtifact
    // CTFrameDraw в bitmap; та же логика переноса строк и truncation, что measure (§3.2 плана)
}

public struct DisplayArtifact: Sendable, Hashable {   // D54
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: DisplayPixelFormat
    public let key: DisplayKey                 // D52/D53
}
public struct DisplayKey: Sendable, Hashable {   // D52
    public let nodeID: NodeID
    public let contentRevision: UInt64
    public let displayRevision: UInt64
    public let size: MeasuredSize
    public let scale: Double
}

public actor DisplayScheduler {                // D53, перенос Weave W06
    public func schedule(_ job: DisplayJob, priority: DisplayPriority)
    public func cancel(nodeID: NodeID)
    public func suspend(); public func resume()
    public var statistics: DisplayStatistics { get }   // scheduled/started/completed/cancelled/dropped/stale
}
@MainActor public final class DisplayTransaction {     // D53, владелец — NodeHostBridge (D58)
    public func committedArtifact(for key: DisplayKey) -> DisplayArtifact?
    public func request(_ input: TextLayoutInput, for nodeID: NodeID, mountEpoch: UInt64)
}
```

Bridge (`NodeHostBridge`): владеет `DisplayScheduler`/`DisplayTransaction` (как
`FocusEngine`, D35); `RenderCoordinator.onPostCommit` планирует display pass
только для нод без актуального committed key (D53). `LayerRenderer`: внешний
node layer (position/bounds/appearance/hit-test/AX) + внутренний raster layer
(`contents`/`contentsScale`/`contentsGravity`) одной ноды — раскладка общая с
implementation-plan-5.md D65, второго рендерера нет.

## 2. Владение

| Объект | Владелец | Хранит | Точка отмены |
|---|---|---|---|
| `TextNode.document/style/maxLines/truncation` | `TextNode` | value | `dispose()` |
| `ContentMeasurer` в `LayoutContentMetrics.measurer` | вызывающий `TextNode.layoutContentMetrics(for:)` | `identity`/`revision`, ссылка на `TextRenderer` из environment | не владеет ничем сам; живёт ровно один snapshot |
| `FlexMeasureCache` записи по измерителю | solver (per-solve, стек-локально) | `LayoutMeasureCacheKey` → `FlexMeasureResult` | конец solve |
| `DisplayScheduler`/`DisplayTransaction` | `NodeHostBridge` | `NodeID`, `mountEpoch`, `DisplayKey`, committed artifacts | `detach()`, `replaceRoot`, `suspend()` |
| Внутренний raster layer | `LayerRenderer` (в паре с внешним node layer, D65) | `CALayer.contents`, `contentsScale` | снятие ноды, смена artifact |
| `TextRendererKey`/`LocaleKey` в environment | `EnvironmentScope` хоста | значение | `attach`/`reparent` (как safe area, D51) |

Ни один объект выше не держит живой `Node` сильно, кроме `NodeHostBridge`
(root, D07) — тот же принцип, что D35 для focus/accessibility.

## 3. Ожидаемые результаты

Все примеры — `TextRenderer` = `CoreTextRenderer` (реальный шрифт), если не
указано иное; шрифт по умолчанию `"system"`, `pointSize: 17`, `lineHeight: 0`.

| # | Сценарий | Ожидание | Закрывает |
|---|---|---|---|
| 1 | `Row { TextNode("Hi"); Spacer().grow(1) }`, ширина row 300 | `TextNode` меряется `.unspecified` по main (max-content, ADR 0009 через measurer), получает natural intrinsic width однострочного `"Hi"`; `Spacer` — остаток; ни один measurer-вызов не видит ширину, зависящую от соседа | D49 §3.1 плана |
| 2 | `Column(width: 120) { TextNode(длинный абзац) }` | измеритель вызывается с `.exact(120)` по ширине на финальном проходе; высота — по количеству строк переноса **на этой ширине**, не по ширине экрана/окна | §3.3 плана (мина W04), D49 |
| 3 | `TextNode(текст на 5 строк), maxLines: 2, truncation: .tail` | `TextMetrics.lineCount == 2`, `didTruncate == true`, последняя видимая строка оканчивается ellipsis по реальным метрикам `CTLine`, не по счёту символов (снимает W01 `renderedText`) | D56 |
| 4 | `maxLines: nil`, bounds height меньше высоты 3 строк, `truncation: .clip` | `didTruncate == true` (высота — тоже ограничитель, снимает W09), лишние строки не рисуются в bitmap | D56 |
| 5 | `constraint.width = .exact(200)` vs `.atMost(200)`, текст короче 200pt | `.exact` → `size.width == 200`; `.atMost` → `size.width == natural` (снимает #39, где Weave давал одинаковый результат) | D56 |
| 6 | RTL `direction`, абзац на арабском | `alignment: .trailing` физически выравнивает по правому краю; перенос строк учитывает direction; `localeIdentifier` действительно передаётся в атрибуты (снимает #39 `_ = localeIdentifier`) | D55, D51 |
| 7 | `TextNode(text: "")` | одна строка высотой `lineHeight` (или natural line height шрифта при `lineHeight == 0`), `intrinsic.width == 0`, `firstBaseline` не `nil` | D56 |
| 8 | Смена только `textStyle.color` (или run-level `color`) на уже размещённой ноде | `displayRevision` растёт, `contentRevision`/`structureRevision` не растут; `RenderCoordinator` не запрашивает layout snapshot/solve, только `DirtyReasons.display` → новый bitmap с тем же geometry | D52 |
| 9 | Resize контейнера с текстом: старый bitmap на прежний `DisplayKey.size`, новый — в очереди | Слой либо пуст, либо (после уточнения T02) временно держит старый bitmap с clipping по новой content area без растяжения glyphs — не растянутый старый растр; когда новый artifact готов — атомарная замена без crossfade; после `detach()` до готовности — ноль коммитов в `CALayer` | D53, D58, план 5 D65 |
| 10 | 100 последовательных `document = ...` на одной ноде без завершения предыдущего измерения/растра между ними | Один финальный layout snapshot и один финальный display job побеждают; промежуточные не коммитятся в `CALayer` (аналог D40 debounce для focus) | D53, D58 |

## Приёмка T01

- Нерешённых альтернатив для T03–T07 не осталось, кроме платформенной проверки
  D54 (compile-probe) и визуальной проверки общего с планом 5 D53/D65 — обе
  назначены T02/M02, не блокируют написание контрактов T03–T09.
- §3.3 плана 4 решён: атрибутированная модель принята как D55, второе поле
  `attributedText` не заводится.
- Raster layer contract (D65 implementation-plan-5.md) сверен и не
  переопределяется здесь: T07 применяет artifact к внутреннему слою одной и
  той же ноды, второй рендерер не появляется.
