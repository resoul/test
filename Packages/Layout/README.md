# Layout

Раскладка CSS Flexbox, декларативный слой над ней и тема. Внешних зависимостей нет.
`FlexEngine`, `LayoutCore` и `ThemeCore` зависят только от Foundation; адаптеры
подключают UIKit или AppKit.

| Модуль | Что делает | Зависит от |
|---|---|---|
| `FlexEngine` | Движок: дерево `LayoutNode` → рамки. Чистая функция над `Sendable`-значениями, работает на любом потоке | Foundation |
| `LayoutCore` | Декларативные спецификации (`FlexContainer`, `Breakpoint`, модификаторы), шкалы отступов и брейкпоинтов. Работает на main actor | `FlexEngine` |
| `ThemeCore` | Тема: цвета, шрифты, радиусы, движение, отступы, брейкпоинты, их значения для настроек читателя | `LayoutCore` |
| `LayoutUIKit` | `UIView` как элемент спецификации, `LayoutView` | всё выше, UIKit |
| `LayoutAppKit` | `NSView` как элемент спецификации, `LayoutNSView` | всё выше, AppKit |

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/Layout")
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "LayoutCore", package: "Layout"),
            .product(name: "FlexEngine", package: "Layout"),
        ]
    )
]
```

Типы движка (`LayoutRect`, `FlexStyle`, `LeafContent`, …) объявлены в `FlexEngine`.
Файлу, который их называет, нужен `import FlexEngine` рядом с `import LayoutCore`.

## Движок без представлений

Дерево собирается из значений, решается целиком и возвращает рамки всех узлов. Размеры
считаются по рамке (border-box): `width` включает `padding`.

```swift
var row = FlexStyle()
row.direction = .row
row.alignItems = .center
row.columnGap = 12
row.padding = Edges(all: 16)

var flexible = FlexStyle()
flexible.grow = 1
flexible.shrink = 1

let tree = LayoutNode(
    id: ProfileRowID.row,
    style: row,
    children: [
        LayoutNode(id: ProfileRowID.avatar, content: .size(width: 48, height: 48)),
        LayoutNode(
            id: ProfileRowID.name,
            style: flexible,
            content: .measured(FixedWidthText(name))
        ),
        LayoutNode(id: ProfileRowID.button, content: .size(width: 70, height: 32)),
    ]
)
return try FlexboxEngine.layout(
    tree,
    size: LayoutSize(width: width, height: 80),
    context: context
)
```

При ширине 320 имя получает 146 точек на позиции x 76, кнопка встаёт на x 234. При
ширине 200 имя сжимается до 26 точек и переносится на три строки.

Содержимое, высота которого зависит от ширины (прежде всего текст), описывается через
`ContentMeasurer`. Измеритель вызывается на потоке прохода, поэтому он не трогает
UI-объекты:

```swift
public struct FixedWidthText: ContentMeasurer {
    public let text: String

    public func minContentWidth() -> Double { 8 }

    public func maxContentWidth() -> Double { Double(text.count) * 8 }

    public func height(forWidth width: Double) -> Double {
        let perLine = max(1, Int(width / 8))
        let lines = (text.count + perLine - 1) / perLine
        return Double(max(1, lines)) * 20
    }
}
```

Отмена проходит через `LayoutContext`. Отменённый проход бросает `LayoutCancelled` и
ничего не возвращает — частичного результата не бывает:

```swift
public func layoutProfileRowInBackground(name: String, width: Double) async throws -> LayoutResult {
    try layoutProfileRow(name: name, width: width, context: .currentTask)
}
```

## Спецификации

Элемент спецификации — всё, у чего есть рамка: собственный класс с `LayoutElement`,
`UIView`, `NSView` или узел из `NodesUI`. Спецификация описывает раскладку: что
вложено во что и с какими отступами.

```swift
Breakpoint(from: .sm) {
    FlexContainer(.row) {
        avatar.size(48)
        FlexContainer(.column) {
            title
            subtitle
        }
        .gap(.s2)
        .flex(grow: 1, shrink: 1)
        follow
    }
    .alignItems(.center)
    .gap(.s4)
    .padding(.s5)
} otherwise: {
    FlexContainer(.column) {
        avatar.size(64)
        title
        subtitle
        follow
    }
    .alignItems(.start)
    .gap(.s3)
    .padding(.s5)
}
```

`.s2`, `.s4` и `.sm` — ступени шкал. В точки они превращаются только при раскладке, по
шкалам того прохода. Стандартные шкалы — отступы `2, 4, 8, 12, 16, …` и брейкпоинты
`sm 400, md 600, lg 840, …`.

Раскладка одним вызовом на main actor:

```swift
card.spec().apply(in: rect)
```

Для раздельного расчёта спецификация читается на main actor, а `LayoutRequest` хранит
снимок входа и фиксированный размер. `ComputedLayout` связывает результат с этой
подготовкой. Пример одного прохода с передачей отмены фоновой задаче:

```swift
let prepared = card.spec().prepare()
let request = prepared.request(size: rect.size)
let computed: ComputedLayout
if request.requiresMainThread {
    computed = try request.solveOnMainActor()
} else {
    let worker = Task.detached { try request.solve() }
    computed = try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}
guard !Task.isCancelled else { throw LayoutCancelled() }
prepared.apply(computed, in: rect)
```

`solve()` сам не создаёт задачу: в приложении запрос можно передать ограниченной очереди
подготовки вместо отдельного `Task.detached`. Он бросает `LayoutRequestError.requiresMainThread`
до измерений, если контент требует main actor; явный путь `solveOnMainActor()` поддерживает
такой контент. По умолчанию отмена следует текущей задаче. Если передан свой LayoutContext,
именно он определяет проверку отмены, трассировку и ограничение стека.

Проверяемое применение возвращает `nil` и ничего не меняет при другом снимке, размере
или дублирующем размещении элемента. Другая позиция прямоугольника и pixel scale разрешены:
они применяются после расчёта. Успешная пустая спецификация возвращает пустой массив,
а не `nil`.

На живом экране владелец сохраняет **текущий** PreparedLayout и заменяет его при изменении
контента, темы, локали или других входов. После `await` результат нужно применять через
текущую подготовку и текущий размер: новый снимок отклонит результат старого. Применение
через сохранённую локальную старую подготовку по-прежнему применит старый снимок — пакет
не наблюдает мутации UI автоматически. Геометрия не ждёт сетевые изображения: их загрузка
и готовность остаются ответственностью слоя UI.

## Тема

```swift
var theme = Theme.standard
theme.palette.accent = ThemeColor(
    light: Color(red: 0.1, green: 0.4, blue: 0.9),
    dark: Color(red: 0.4, green: 0.6, blue: 1)
)
theme.spacing = SpacingScale(steps: [4, 8, 12, 16, 20, 28, 40, 56, 72])
```

Значения для настроек читателя — цветовой схемы, контраста, размера текста и
уменьшения движения:

```swift
let conditions = DisplayConditions(colorScheme: dark ? .dark : .light, textScale: textScale)
let resolved = appTheme().resolved(for: conditions)
return (resolved.color(.accent), resolved.font(.body).size, resolved.points(.s4))
```

Шкалы темы передаются раскладке вместо стандартных:

```swift
card.spec().apply(in: rect, spacing: theme.spacing, breakpoints: theme.breakpoints)
```

## Представления

Представление переопределяет только `layoutSpec()`. Его подвиды становятся элементами
спецификации как есть, а надписи измеряют свой текст. `layoutTheme` задаёт тему, её
отступы и брейкпоинты:

```swift
public final class ProfileView: LayoutView {  // LayoutNSView в AppKit
    public let avatar = UIView()
    public let name = UILabel()
    public let follow = UIButton(type: .system)

    public override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            avatar.size(48)
            name.flex(grow: 1, shrink: 1)
            follow
        }
        .alignItems(.center)
        .gap(.s4)
        .padding(.s5)
    }
}
```

Любой `UIView` или `NSView`, который реализует `LayoutSpecProviding`, получает
`applyLayoutSpec()` и измеряется своей спецификацией, когда его вкладывают в другую.

## Код примеров

Примеры из этого файла взяты из
[Examples/Sources/LayoutExamples](../Examples/Sources/LayoutExamples) и проверяются
тестами в [ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift)
(раздел `Layout`).

## Проверки

```sh
swift test                                                         # все тесты пакета
CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance # записать новый baseline
cd Benchmarks && swift run -c release LayoutBench                  # скорость против прежнего движка
xcodebuild test -scheme Layout-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```

Эталоны CSS лежат в `Conformance/CSSFlexbox/`. Их генерирует `generate.cjs` через
Chromium.
