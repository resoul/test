# Layout Framework — план на версию 2.0

> Исторический черновик, не действующий план исполнения. Его утверждения и имена местами исправлены анализом [weave-analysis.md](../weave-analysis.md). Актуальные задачи: [implementation-plan.md](../implementation-plan.md); принятые контракты: [decisions.md](../decisions.md). В частности, LayoutContext теперь принадлежит исполнению solver, а arrangeSubnodes() первого этапа не принимает constraint.

Документ фиксирует замечания по текущей кодовой базе (Node, Reconciler, LayoutEngine,
FlexSolver, LayoutSpec, Lifecycle, Accessibility, Window/Scene) и предлагает архитектуру
2.0 с явным multi-engine layout (Flex/Grid/Absolute) через единый декларативный builder
(`Arrangement`/`arrangeSubnodes(in:)`) — по духу похоже на Texture (`ASLayoutSpec`/
`layoutSpecThatFits:`) и CSS (flex vs grid), но с собственным неймингом — см. раздел 2.6.

---

## 1. Баги и риски в текущей реализации (чинить до 2.0)

### 1.1 `Reconciler.diff` — некорректные индексы в remove-патчах [БЛОКЕР]

**Файл:** `Transfer.swift` / `Reconciler`

Индексы `.remove(fromIndex:)` в финальном while-цикле считаются от **финального**
состояния `working` (уже пересобранного под порядок `new`), а не от состояния
живого дерева на момент, когда `apply()` реально дойдёт до применения этого
конкретного патча. `insert`/`move`/`replace` эмитятся в порядке, синхронном с
последовательным применением, а `remove`-хвост эмитится отдельным проходом поверх
уже финального `working` — из-за этого индексы могут не совпадать с реальной
позицией элемента в дереве на момент применения.

Пример, где заведомо может разъехаться: `old=[A,B,C]`, `new=[B]`, где A/B/C —
разные `typeName` без ключей. Позиционное сопоставление (`nil`-key sibling match)
у вас сравнивает `descriptor.key == nil` и индекс, а не тип/контент — то есть A на
позиции 0 "принимается" за B и уходит в `.replace`, а не в `.remove`+`.insert`. В
простых кейсах `NodeReconciliationController.isApplicable` эту рассинхронизацию
ловит и просто отклоняет diff (`applied: false`) — то есть баг не крашит
приложение, а **молча не обновляет дерево**, что почти хуже (баг незаметен, пока
не появится property-based тест).

**Рекомендация:**
- Переписать remove-фазу так, чтобы патчи считались **относительно единой
  последовательной симуляции применения** (одна копия массива, патчи применяются
  к ней по порядку эмиссии, индексы читаются из неё на каждом шаге), а не в два
  раздельных прохода (основной цикл + отдельный remove-хвост).
- Добавить property-based тест: случайные `old`/`new` (без ключей, с ключами,
  смешанные), сравнение результата применения патчей к копии `old` с ожидаемым
  `new`. Это тот же контракт, что уже проверяет `isApplicable`, но полезно иметь
  отдельно как unit-тест самого дифа, а не только как рантайм-guard.

### 1.2 `Reconciler.diff` — потеря первого дубликата ключа в `old`

```swift
if oldByKey.updateValue(index, forKey: key) != nil {
    duplicateKeys.append(key)
    oldByKey[key] = oldByKey[key].map { min($0, index) }
}
```

`updateValue` уже перезаписал значение до сравнения — `oldByKey[key]` после этой
строки всегда равен новому `index`, `min($0, index)` — no-op. Нужно сохранить
предыдущее значение до `updateValue`:

```swift
if let previous = oldByKey[key] {
    duplicateKeys.append(key)
    oldByKey[key] = min(previous, index)
} else {
    oldByKey[key] = index
}
```

### 1.3 `ForEach.result` — идентичность ключа через `String(describing:)`

**Файл:** `Transfer.swift` / `ForEach`

```swift
let key = String(describing: element[keyPath: id])
```

Два разных значения `ID: Hashable` теоретически могут дать одинаковую строку через
`describing`, если тип не предоставляет осмысленный `CustomStringConvertible`.
Использовать `AnyHashable(element[keyPath: id])` как реальный ключ идентичности,
`String(describing:)` оставить только для человекочитаемых diagnostics-сообщений.

Также: `ForEach.result` перезаписывает `key` результата `make(element)` ключом из
keyPath безусловно (`NodeDescriptor(typeName: descriptor.typeName, key: key)`),
теряя любой key, который `make` мог явно проставить сам. Если это осознанное
поведение (внешний key всегда доминирует) — задокументировать явно в doc-комментарии,
иначе это будет источником "необъяснимых" багов у потребителей API.

### 1.4 `NodeState.set`/`modify` — потенциальный actor reentrancy gap

**Файл:** второй присланный сниппет (`NodeState` actor)

```swift
public func set(_ value: Value) async -> Bool {
    let current = await storage.value
    guard current != value else { return false }
    await storage.set(value)
    revision &+= 1
    return true
}
```

Если `storage` (`CurrentValueDistinct`) — независимый actor/isolation domain
(не просто synchronous-wrapped значение под тем же actor), то `await storage.value`
и `await storage.set(value)` — два отдельных suspension points, между которыми
`NodeState`-actor может отдать управление другому таску, обращающемуся к тому же
`set`/`modify`. Это классический check-then-act race: `guard current != value`
может устареть к моменту записи.

**Рекомендация:** либо доказать, что `storage` не создаёт реальной конкурентности
(например, деталь реализации `CurrentValueDistinct` гарантирует, что все operations
serialized относительно `NodeState`'s isolation без промежуточной приостановки),
либо переписать так, чтобы check-and-set был одной non-suspending операцией внутри
изоляции `NodeState` (например, `storage` хранит value синхронно под тем же actor,
без собственного `await`-API).

### 1.5 `LayoutEngine.request` — детач без учёта возможного повторного входа в `commit`

**Файл:** `LayoutEngine.swift`

`worker = Task.detached { ... await self?.commit(result, generation: requestGeneration) }`
— это уже сделано аккуратно (generation guard в `commit`), явных багов нет.
Единственное на будущее: `cache = FlexMeasureCache()` создаётся заново на каждый
`request`, то есть кэш измерений не переиспользуется между layout passes соседних
кадров. Для 2.0 стоит рассмотреть per-node measurement cache с invalidation по
`contentRevision`/`environmentRevision` (у вас эти поля уже есть в
`LayoutInputSnapshot` — это прямой сигнал для кэш-инвалидации, который сейчас не
используется).

### 1.6 `makeLayoutInputSnapshot` — отсутствие мемоизации по revision

**Файл:** `Node`

Снепшот строится полной рекурсией по всему дереву на каждый вызов, без проверки,
изменилось ли поддерево (`layoutRevision`/`contentRevision` уже трекаются, но не
используются для пропуска пересборки неизменных веток). Для больших деревьев
(списки, сложные экраны) это O(N) аллокаций на каждый layout request, даже если
изменился один лист. Стоит закешировать `LayoutInputSnapshot` per-node и
переиспользовать ветки, где revision не изменился с прошлой сборки.

### 1.7 `NodeBacking` — протокол-заглушка на уровне core, но platform-мост уже существует отдельно

`protocol NodeBacking: AnyObject {}` в core-таргете пуст, `backing` всегда `nil`.
**Уточнение после просмотра adapter-файлов (`WeaveUI` platform layer):** сам мост
до платформы **уже реализован** — `CoreTextRasterRenderer`, `ImageRasterRenderer`,
`VisualStyleRenderer`, `WindowHost`, `CoreAnimationConversions` — это готовый,
неожиданно зрелый raster/adapter слой. Формальный `NodeBacking` протокол в core,
судя по всему, не тот механизм, через который эти файлы реально связаны с `Node`
сегодня — связка идёт через отдельный pipeline (`DisplayPipeline`/
`RenderCoordinator`/`UIKitAdapter`/`UIKitLayerRenderer`, файлы затребованы, но
содержимое не рассмотрено). Раздел 3 ниже пересмотрен с учётом этого — часть
"из заглушки в реализацию" фактически уже сделана, работа 2.0 здесь в основном про
**формализацию контракта** и заполнение конкретных пробелов, а не про создание
слоя с нуля.

---

## 2. Замена layout-модели: единый builder поверх нескольких engine

### 2.1 Проблема текущего состояния

Сейчас декларативность живёт в двух не до конца связанных местах:

- `LayoutSpec.swift` — текущий файл в кодовой базе (`StackSpec`, `InsetSpec`,
  `OverlaySpec`, `CenterSpec`, `RatioSpec`, `AbsoluteSpec`, `BackgroundSpec`,
  `WrapperSpec`) — умеет только **измерять** (`measure(in:) -> MeasuredSize`), не
  позиционирует и не знает про живые `Node`. Этот файл и его типы переименовываются
  в рамках 2.6 (Naming pass) — `Spec`-нейминг там прямая калька Texture.
- Позиционирование целиком идёт через `LayoutStyle` (flex-only: `flexDirection`,
  `justifyContent`, `alignItems`, ...) и единственный движок `FlexSolver`.

Нет grid engine, нет способа сказать "этот узел — flex-контейнер, а вот этот его
ребёнок внутри — grid", и текущий `LayoutSpec` не связан с реальным деревом `Node`
напрямую (сборка дерева спеков и дерева `subnodes` должны синхронизироваться
вручную).

### 2.2 Целевая модель для 2.0

Три независимых слоя, как обсуждали:

```
LayoutEngine (протокол)     — FlexEngine, GridEngine, AbsoluteEngine — каждый своя математика
LayoutNode / Node (дерево)  — engine как свойство узла, не глобальный переключатель
Arrangement (builder/DSL)   — декларативный result-builder поверх Node+engine, наш аналог Texture layoutSpecThatFits (см. 2.6, переименовано)
```

**Ключевое решение:** движок — свойство *контейнера*, не глобальная настройка.
Одно дерево может свободно содержать flex-секцию с grid-ячейкой внутри и
наоборот — ровно как в реальном CSS (grid на верхнем уровне layout страницы,
flex внутри карточек).

```swift
public protocol LayoutEngine: Sendable {
    /// Pure function: snapshot + constraint → positioned children.
    /// No Node, no platform object — same contract FlexSolver already has today.
    func layout(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy,
        cache: inout LayoutMeasureCache
    ) -> LayoutResult
}
```

`FlexSolver` уже соответствует этой форме почти буквально (см. `LayoutResult.swift`,
`layoutContainer(input:frame:roundingPolicy:cache:)`) — превратить его в
`FlexLayoutEngine: LayoutEngine` conforming type — почти без изменений сигнатуры,
только обернуть существующую статическую функцию.

`GridLayoutEngine` — новый тип с той же формой контракта, читает grid-specific
поля стиля (см. 2.3), пишет те же `LayoutPlacement`.

`LayoutStyle` — расширить как **суперсет** полей, а не создавать параллельную
Grid-стилевую структуру:

```swift
public struct LayoutStyle {
    // существующие flex-поля без изменений (обратная совместимость) ...

    // новое: движок этого контейнера. По умолчанию .flex — 100% обратная совместимость
    public var layoutEngine: LayoutEngineKind = .flex

    // новое: grid-only поля, читаются только GridLayoutEngine, игнорируются FlexLayoutEngine
    public var gridTemplateColumns: [GridTrack] = []
    public var gridTemplateRows: [GridTrack] = []
    public var gridAutoFlow: GridAutoFlow = .row
    public var gridColumn: GridPlacement = .auto
    public var gridRow: GridPlacement = .auto
}

public enum LayoutEngineKind: Sendable, Hashable {
    case flex
    case grid
    case absolute
    case custom(String) // расширяемость под сторонние движки (plugin-модель, см. раздел 4)
}
```

`Node` при построении `LayoutInputSnapshot` не выбирает движок сам — это делает
верхнеуровневый layout dispatcher, глядя на `style.layoutEngine` контейнера:

```swift
enum LayoutEngineRegistry {
    static func engine(for kind: LayoutEngineKind) -> any LayoutEngine {
        switch kind {
        case .flex: FlexLayoutEngine()
        case .grid: GridLayoutEngine()
        case .absolute: AbsoluteLayoutEngine()
        case .custom(let id): CustomEngineRegistry.shared.engine(for: id) ?? FlexLayoutEngine()
        }
    }
}
```

`LayoutResult.layoutContainer` (сейчас единственная точка входа) становится тонким
диспетчером: смотрит `input.style.layoutEngine`, зовёт нужный `LayoutEngine`, для
детей — рекурсивно то же самое (у каждого ребёнка свой `style.layoutEngine`,
диспетчеризация происходит на каждом уровне дерева, не глобально).

### 2.3 `GridTrack`/`GridPlacement` — минимальный набор для старта

```swift
public enum GridTrack: Sendable, Hashable {
    case fixed(Double)
    case fraction(Double)     // аналог CSS `fr`
    case auto
    case minmax(min: Double, max: Double)
}

public enum GridPlacement: Sendable, Hashable {
    case auto
    case line(Int)                    // grid-column: 2
    case span(start: Int, count: Int) // grid-column: 2 / span 2
}

public enum GridAutoFlow: Sendable, Hashable { case row, column, rowDense, columnDense }
```

Этого достаточно для аналога `LazyVGrid(.adaptive)`/CSS
`grid-template-columns: repeat(...)` в первой версии; explicit row/column spanning
(2D placement с перекрытием) можно добавить вторым проходом без ломки контракта
`LayoutEngine`, поскольку алгоритм инкапсулирован внутри `GridLayoutEngine`.

### 2.4 Декларативный override — аналог Texture `layoutSpecThatFits`, другое имя

`LayoutSpec` дерево — не третий параллельный layout-механизм, а компилятор в
`LayoutStyle` существующих `Node`, так же как обсуждали. Листовой узел спека — не
абстрактный размер, а ссылка на живую `Node`.

**Именование:** override называется `arrangeSubnodes(in:)`, не
`layoutSpecThatFits` — см. раздел 2.6 (Naming pass), почему это важно сделать
сразу, а не переименовывать после того, как API кто-то начнёт использовать.

```swift
/// Leaf: wraps a live Node so the arrangement tree always resolves to real subnodes,
/// exactly like ASLayoutElement/ASDisplayNode in Texture — but under our own name.
public struct NodeArrangement: Arrangement {
    public let node: Node
    public init(_ node: Node) { self.node = node }
}

public struct Stack: Arrangement {
    let spacing: Double
    let children: [any Arrangement]
    public init(spacing: Double = 0, @ArrangementBuilder _ content: () -> [any Arrangement]) {
        self.spacing = spacing
        self.children = content()
    }
}

public struct Grid: Arrangement {
    let columns: [GridTrack]
    let children: [any Arrangement]
    public init(columns: [GridTrack], @ArrangementBuilder _ content: () -> [any Arrangement]) {
        self.columns = columns
        self.children = content()
    }
}
```

Резолвер (`ArrangementResolver.apply(_:to:)`) проходит дерево и **пишет
`LayoutStyle`** в соответствующие `Node` — `Stack` выставляет
`layoutEngine = .flex, flexDirection = .row`, `Grid` выставляет
`layoutEngine = .grid, gridTemplateColumns = columns`. Дети получают свой
`gridColumn`/`flexGrow`/`alignSelf` через chainable модификаторы (см. 2.5).
Никакого отдельного "исполнения" дерева в рантайме layout-прохода не требуется —
`FlexSolver`/`GridLayoutEngine` продолжают работать над обычным
`LayoutInputSnapshot`, как сегодня.

Override-точка на `Node`:

```swift
extension Node {
    /// Override to declaratively describe how this node arranges its subnodes.
    /// Default nil means the node's style/children are managed manually (today's behavior).
    open func arrangeSubnodes(in context: LayoutContext) -> (any Arrangement)? { nil }
}
```

Вызывается один раз при `compose()`/`setNeedsLayout()` инвалидации, результат
применяется атомарно (собрать все мутации `LayoutStyle.Draft` и применить одним
`style { }` вызовом на узел, чтобы не плодить промежуточные `setNeedsLayout()`
на каждое поле).

### 2.5 Chainable-модификаторы поверх draft (без нового DSL-слоя)

```swift
extension Arrangement {
    public func flexGrow(_ value: Double) -> ModifiedArrangement { ModifiedArrangement(self) { $0.flexGrow = value } }
    public func gridColumn(_ placement: GridPlacement) -> ModifiedArrangement { ... }
    public func padding(_ insets: DirectionalEdgeInsets) -> ModifiedArrangement { ... }
}
```

`ModifiedArrangement` — тонкая обёртка, которая просто копит отложенные мутации
`LayoutStyle.Draft`/`VisualStyle.Draft` и применяет их поверх того, что уже
выставил родительский узел арранжмента при резолве. Это тот же паттерн, что уже
есть в `StyleBuilders.swift` (`buildStyle`/`Draft`) — переиспользуем существующий
механизм, не изобретаем новый.

### 2.6 Naming pass — увести нейминг от Texture-калек

Часть терминов в исходном черновике этого документа (`LayoutSpec`,
`layoutSpecThatFits`, `NodeSpec`, `StackSpec`) — прямая калька имён из Texture
(`ASLayoutSpec`, `-layoutSpecThatFits:`, `ASStackLayoutSpec`). Стоит развести два
разных класса терминов:

- **Общий CS/CSS-вокабуляр — не трогать.** `FlexDirection`, `JustifyContent`,
  `AlignItems`, `AlignSelf`, `AlignContent`, `FlexWrap` — это номенклатура из
  W3C Flexbox спецификации, её используют одинаково Yoga, Texture, React Native,
  SwiftUI-подобные системы. Переименование здесь только создаст путаницу для
  людей, знакомых с CSS/RN — они ожидают именно эти слова. `LayoutEngine`,
  `GridTrack`, `GridPlacement`, `measure(in:)` — тоже общие термины, не
  Texture-специфичные.
- **Texture-специфичный API-нейминг — переименовать.** Ниже таблица.

| Было (Texture-калька) | Стало | Причина |
|---|---|---|
| `layoutSpecThatFits` | `arrangeSubnodes(in:)` | `layoutSpecThatFits:` — точное имя метода `ASDisplayNode` |
| `LayoutSpec` (протокол) | `Arrangement` | `Spec` — калька нейминга Texture/ComponentKit |
| `LayoutSpecContext` | `LayoutContext` | тот же паттерн, убрать `Spec` |
| `StackSpec`/`InsetSpec`/`CenterSpec`/`RatioSpec`/`AbsoluteSpec`/`BackgroundSpec`/`OverlaySpec`/`WrapperSpec`/`EmptySpec` | `Stack`/`Inset`/`Center`/`Ratio`/`Absolute`/`Background`/`Overlay`/`Wrapper`/`Empty` | суффикс `Spec` не нужен вообще; короче, ближе к SwiftUI-стилю (`VStack`, не `VStackSpec`) |
| `NodeSpec` | `NodeArrangement` | `Node` уже участвует в дереве напрямую как лист — обёртка называется по роли (оборачивает Node в Arrangement), не по Texture-аналогии |
| `layoutSpecBlock` (если понадобится closure-вариант без наследования) | `arrangementBlock` | тот же принцип, что и у override-метода |
| `LayoutSpecResolver` | `ArrangementResolver` | следует за переименованием протокола |
| `@LayoutBuilder` (result builder) | `@ArrangementBuilder` | следует за переименованием протокола |

**Важно сделать это в одном PR с вводом самого override (пункт 6 в разделе 5),
а не отдельным заходом позже** — как только `arrangeSubnodes`/`Arrangement`
попадут в публичный API и на них появятся внешние потребители, переименование
станет breaking change с миграционным путём, а не просто выбором имени в
черновике.

---

## 3. Platform backing (`NodeBacking`) — из заглушки в формализованный контракт

**Обновление:** после просмотра `CoreTextRasterRenderer.swift`,
`ImageRasterRenderer.swift`, `VisualStyleRenderer.swift`, `VideoPipeline.swift`,
`CoreAnimationConversions.swift`, `WindowHost.swift` стало ясно, что значительная
часть platform-моста уже существует как отдельный adapter-слой (`WeaveUI` product
target, отдельный от core). Разделы 3.1–3.3 ниже скорректированы: где было "спроектировать
с нуля" — теперь "формализовать в `NodeBacking` то, что уже работает", и добавлен
новый раздел 3.5 про raster pipeline, которого не было видно на момент первой версии
этого документа.

### 3.1 Протокол шире, чем сейчас

```swift
@MainActor
public protocol NodeBacking: AnyObject {
    var isLayerBacked: Bool { get }
    func syncFrame(_ frame: LayoutFrame)
    func syncAppearance(_ style: VisualStyle)
    func syncAccessibility(_ properties: AccessibilityProperties)
    func mount(child: any NodeBacking, at index: Int)
    func unmount(child: any NodeBacking)
    func teardown()
}

@MainActor
public protocol NodeBackingFactory {
    /// Return nil for structural nodes (Group-like) — their children attach
    /// to the nearest backed ancestor instead of creating an empty view/layer.
    func makeBacking(for node: Node) -> (any NodeBacking)?
}
```

Живёт **не в core-таргете** — отдельные adapter-таргеты (`UIKitAdapter`,
`AppKitAdapter`), core остаётся platform-agnostic (уже так спроектировано, просто
нужно довести до конца).

### 3.2 `PlatformHost` — недостающее связующее звено

Сейчас в коде нет явного объекта, который соединяет
`LayoutEngine.onApply → applyRecursively → backing sync`. Логика размазана между
`Node.apply(_:)` и неявными предположениями. Явный `PlatformHost`:

- владеет `LayoutEngine`, `NodeBackingFactory`, корневым `Node`
- на `onApply` вызывает `root.applyRecursively(result)` **и** обходит дерево,
  создавая/переиспользуя `backing` для узлов без него, синхронизируя
  `frame`/`appearance`/`accessibility`
- батчит все `syncFrame` вызовы одного `LayoutResult` в один
  `CATransaction`/`NSAnimationContext` (см. 3.3) — без этого каждая ручная
  простановка `frame` триггерит отдельный implicit animation commit,
  что на больших деревьях/списках даёт заметный перф-хит
- становится единственной точкой, которую нужно мокать в тестах — весь
  pipeline (descriptor → diff → node → layout) тестируется без реального
  UIKit/AppKit через fake `NodeBackingFactory`

### 3.3 Batch commit

```swift
func applyBackingSync(_ result: LayoutResult) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for placement in result.placements {
        backing(for: placement.identity)?.syncFrame(placement.frame)
    }
    CATransaction.commit()
}
```
На AppKit — эквивалент через `NSAnimationContext.runAnimationGroup` с
`allowsImplicitAnimation = false`, либо прямая простановка `frame`/`bounds` вне
анимационного контекста, в зависимости от того, что реально нужно на macOS.

`VisualStyleRenderer.applyVisualStyle(_:to:theme:)` уже существует и делает ровно
то, что нужно для paint-only свойств (`background`/`cornerRadius`/`border`/
`shadow` напрямую на `CALayer`, без растеризации — правильное решение, раз Core
Animation умеет рисовать это само). Он должен вызываться из того же batch-прохода,
что и `syncFrame`, внутри одной `CATransaction`, а не отдельным проходом по дереву —
иначе paint-обновление и геометрия дадут два отдельных implicit commit на кадр
вместо одного.

### 3.4 Recycling — задел уже есть, протокол не хватает

`NodeReconciliationController.apply(..., recycle: (@MainActor (Node) -> Void)?)`
уже принимает recycle callback — хороший задел под список/скролл. Для 2.0 стоит
формализовать протокол переиспользования backing (не просто `Node`, а именно
`NodeBacking`, чтобы не пересоздавать `UIView`/`NSView` при переиспользовании
ячейки):

```swift
public protocol RecyclableBacking: NodeBacking {
    func prepareForReuse()
}
```

### 3.5 Raster pipeline — уже существует, нужно формализовать как явную систему

Обнаружено при просмотре adapter-файлов: контент (текст, картинки) **не** рисуется
синхронно на MainActor через `syncAppearance`/`draw(_:)`. Вместо этого есть
отдельный raster pipeline:

```
Node (style + content) → RenderRequest (Sendable, immutable, с generation/geometryGeneration/contentRevision)
                        → *Renderer.render(request:) — чистая функция, безопасно на background Task
                        → DisplayArtifact (immutable, несёт готовый CGImage либо .empty)
                        → generation-check (тот же staleness guard, что в LayoutEngine.commit)
                        → layer.contents = artifact.image   (единственный MainActor-шаг)
```

Конкретные компоненты, которые уже есть:

- **`CoreTextRasterRenderer`** — `measure(...)` (CoreText framesetter, синхронный,
  дешёвый) отдельно от `render(request:) throws -> DisplayArtifact` (полный
  раскрой + `CGContext` растеризация, кооперативно проверяет
  `Task.checkCancellation()` на каждой дорогой стадии). Правильное разделение —
  измерение нужно layout-проходу синхронно/часто, рендер — только когда геометрия
  окончательно закоммичена.
- **`ImageRasterRenderer`** — decode через `ImageIO` (`CGImageSourceCreateThumbnailAtIndex`
  с `kCGImageSourceCreateThumbnailFromImageAlways` — то есть всегда генерит thumbnail
  нужного пиксельного размера, а не декодит и потом даунскейлит полное изображение;
  это правильно для памяти на больших исходниках), дальше compositing по
  `ImageContentMode` (`.fit`/`.fill`/`.stretch`) в `CGContext` того же паттерна, что
  text renderer.
- **`VideoPipeline` / `CALayerAttachingVideoBackend`** — единственный контент-тип,
  который **обходит** raster pipeline полностью: `AVPlayerLayer`-подобный backend
  атачится как sublayer напрямую (`attachVideoLayer(to:)`), потому что видео не
  рисуется в `CGImage` кадр за кадром вручную. Архитектурно корректный третий путь
  рядом с "растеризовать" (text/image) и "нативные CALayer properties"
  (`VisualStyleRenderer`).

**Три content-paths итого:**
1. Native CALayer properties — `VisualStyleRenderer`, синхронно, MainActor, дёшево.
2. Rasterized artifact — `CoreTextRasterRenderer`/`ImageRasterRenderer`, async,
   background-safe, `layer.contents =` в конце.
3. Attached native sublayer — `VideoPipeline`, MainActor, layer живёт вне raster pipeline.

**Что нужно формализовать для 2.0 (файлы `DisplayPipeline.swift`/
`RenderCoordinator.swift`/`UIKitAdapter.swift`/`UIKitLayerRenderer.swift` не были
прочитаны на момент этой версии документа — пункты ниже основаны на контракте
запросов/артефактов, видимом из renderer-файлов, и должны быть сверены с реальным
`RenderCoordinator` до реализации):**

- Явный **raster scheduler**, симметричный `LayoutEngine`: принимает
  `TextRenderRequest`/`ImageRenderRequest`, коалессирует повторные запросы на тот
  же `nodeID` (отменяет предыдущий `Task` при новом запросе — как
  `LayoutEngine.request` отменяет `worker`), фильтрует stale-результаты по
  `generation` перед `layer.contents =`.
- Явный контракт: какая из трёх ревизий (`generation`/`geometryGeneration`/
  `contentRevision`) что инвалидирует — в частности, важно чтобы **изменение
  только геометрии** (скролл, resize без изменения текста/картинки) не
  триггерило повторную растеризацию, а только `syncFrame` геометрии слоя
  (`layer.bounds`/`layer.position`), при переиспользовании уже готового
  `artifact.image`. Если `geometryGeneration` уже разведена с `contentRevision`
  в `TextRenderRequest`/`ImageRenderRequest` для этой цели — задокументировать
  как формальный инвариант raster pipeline, чтобы будущие авторы renderer'ов
  (custom content types, п. 4) не сломали его случайно.
- Concurrency limit / приоритизация: сколько text/image рендеров одновременно
  на фоне (особенно в списках — сотни ячеек не должны залпом стартовать сотни
  `Task.detached`). `LayoutEngine` такого лимита тоже не имеет — стоит решить
  единым механизмом на оба (layout + raster), не дублировать логику дважды.
- `RecyclableBacking.prepareForReuse()` (3.4) должен явно **отменять pending
  raster request** для переиспользуемой ячейки — иначе старый text-render,
  запущенный для прошлого контента ячейки, может прилететь и перезаписать
  `layer.contents` уже после того, как ячейка переиспользована под новые данные
  (тот же класс бага, что generation-guard решает для layout, но применительно
  к per-cell recycling нужен явный cancel в момент `prepareForReuse`, а не
  только фильтрация по generation постфактум).

---

## 4. Расширяемость движков — "плагин к UIKit", как обсуждали

`LayoutEngineKind.custom(String)` + `CustomEngineRegistry` — сторонний код может
зарегистрировать свой `LayoutEngine` (например, кастомный masonry/waterfall
layout) без форка core-таргета:

```swift
public enum CustomEngineRegistry {
    @MainActor public static var shared = CustomEngineRegistry()
    private var engines: [String: any LayoutEngine] = [:]
    public mutating func register(_ engine: any LayoutEngine, for id: String) {
        engines[id] = engine
    }
    public func engine(for id: String) -> (any LayoutEngine)? { engines[id] }
}
```

Тот же принцип на platform-слое: `NodeBackingFactory` — протокол, значит вторая
платформа (или тестовый in-memory backend) подключается без изменений в core.

---

## 5. Порядок работ для 2.0

0. Прочитать `DisplayPipeline.swift`/`RenderCoordinator.swift`/`UIKitAdapter.swift`/
   `UIKitLayerRenderer.swift` и сверить с разделом 3.5 — эта версия документа
   написана по контракту, видимому из renderer-файлов, не по самому
   `RenderCoordinator`; пункты 8–9 и 3.5 могут потребовать правки после сверки.
1. Починить `Reconciler.diff` remove-индексы + property-based тест (1.1, 1.2) — блокер
2. `AnyHashable` вместо `String(describing:)` в `ForEach.result` (1.3)
3. Проверить/зафиксировать non-reentrant `NodeState.set`/`modify` (1.4)
4. Ввести `LayoutEngine` протокол, обернуть текущий `FlexSolver` в `FlexLayoutEngine` — без изменения поведения (2.2)
5. Добавить `LayoutEngineKind`/grid-поля в `LayoutStyle.Draft`, реализовать `GridLayoutEngine` (2.2–2.3)
6. Переименовать `LayoutSpec` → `Arrangement` и связанные типы, ввести
   `NodeArrangement`+`arrangeSubnodes(in:)` override, резолвер arrangement→style —
   один PR, см. Naming pass (2.4–2.6)
7. Chainable-модификаторы поверх существующего `Draft`-механизма (2.5)
8. Формализовать `NodeBacking`+`NodeBackingFactory` вокруг уже существующего
   adapter-слоя (`UIKitAdapter`, `VisualStyleRenderer`, raster renderers) — не
   писать с нуля, обернуть контрактом (3.1)
9. Ввести/сверить `PlatformHost`, batch commit через `CATransaction` для
   geometry+paint за один проход (3.2–3.3)
10. Формализовать raster scheduler: коалессинг per-`nodeID`, единый лимит
    конкурентности с `LayoutEngine`, явный инвариант `geometryGeneration` vs
    `contentRevision`, cancel pending render в `prepareForReuse` (3.5)
11. Кэш `LayoutInputSnapshot` по revision (1.6) — перф-проход, не блокер корректности
12. `RecyclableBacking` протокол под списки, включая cancel raster-запросов (3.4, 3.5)
13. `CustomEngineRegistry` для сторонних layout-движков (4)

Пункты 1–3 — исправление существующих багов, не затрагивают публичный API.
Пункты 4–7 — новый layout-слой, обратно совместим (`layoutEngine` по умолчанию
`.flex`, старый код не меняет поведения). Пункты 8–10 — формализация уже частично
существующего platform/raster моста в явный, тестируемый контракт (не написание
с нуля, как предполагалось в первой версии этого документа). Пункты 11–13 — перф
и расширяемость, можно делать параллельно/после.
