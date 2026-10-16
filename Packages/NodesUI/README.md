# NodesUI

Дерево узлов поверх пакета `Layout` и слой приложения: экраны, стеки навигации, вкладки,
разделённые окна. Узлы раскладываются движком, управляются состоянием из `StateCore` и
рисуются в `CALayer`. Сами по себе узлы не зависят от UIKit и AppKit — их показывают
адаптеры.

| Модуль | Что делает | Зависит от |
|---|---|---|
| `Nodes` | `Node`, `NodeHost`, прокрутка, ленивые списки, фокус, команды, анимации, доступность | `Layout`, `StateCore`, `LocalizationCore`, `Tracing` |
| `NodesRender` | Отрисовка в `CALayer` и узлы с содержимым: `Text`, `Image`, `Button`, `TextField`, `Table`, `Video`, … | `Nodes`, `RichTextCore`, `NetworkCore`, `StorageCore` |
| `NodesUIKit` | `NodeView` — дерево узлов в `UIView`; `HostedView` — `UIView` внутри дерева | `NodesRender`, `LayoutUIKit` |
| `NodesAppKit` | `NodeNSView` и `HostedView` для AppKit | `NodesRender`, `LayoutAppKit` |
| `AppShell` | `Screen`, `NodeScreen`, `Stack`, `Tabs`, `Split`, `Shell`, оповещения, восстановление | `Nodes`, `StateCore` |
| `AppShellUIKit` | Показывает `Stack`, `Tabs` и `Split` в контроллерах UIKit | `AppShell`, `NodesUIKit` |
| `AppShellAppKit` | То же для AppKit, меню и панели инструментов | `AppShell`, `NodesAppKit` |

`NodesRender` использует из `Data` только `NetworkCore` и `StorageCore`: кэш картинок
проверяет свежесть по HTTP-валидаторам и объединяет одновременные загрузки одного адреса.
GRDB и AsyncRay этому пакету не нужны.

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/NodesUI"),
    .package(path: "../Packages/Layout"),
    .package(path: "../Packages/Basics"),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "Nodes", package: "NodesUI"),
            .product(name: "NodesRender", package: "NodesUI"),
            .product(name: "NodesUIKit", package: "NodesUI"),
            .product(name: "AppShell", package: "NodesUI"),
            .product(name: "AppShellUIKit", package: "NodesUI"),
            .product(name: "LayoutCore", package: "Layout"),
            .product(name: "FlexEngine", package: "Layout"),
            .product(name: "StateCore", package: "Basics"),
        ]
    )
]
```

## Узлы

Узел описывает раскладку подузлов в `layoutSpec()`, а свои свойства обновляет в
`update()`. Состояния, которые читает каждый из этих методов, отслеживаются: если
состояние меняется, метод выполняется снова. Узлы, которые упоминает спецификация,
становятся подузлами автоматически.

```swift
@MainActor
public final class CounterNode: Node {
    public let count = State(0)
    public let showsHint = State(true)

    public let label = Text("0", style: TextStyle(.title))
    public let hint = Text(
        "Press the button",
        style: TextStyle(.caption, colorRole: .secondaryText)
    )
    public private(set) lazy var button = Button("Add") { [unowned self] in
        count.value += 1
    }

    public override func update() {
        label.text = "\(count.value)"
    }

    public override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            label
            if showsHint.value { hint }
            button
        }
        .alignItems(.center)
        .gap(.s3)
        .padding(.s5)
    }
}
```

## Хост

На экране хостом служит `NodeView(root:)` (UIKit) или `NodeNSView(root:)` (AppKit). В
тестах и бенчмарках используется хост без представления:

```swift
let counter = CounterNode()
let host = NodeHost(root: counter, size: LayoutSize(width: 320, height: 240))
host.layoutIfNeeded()
let before = counter.button.frame

counter.showsHint.value = false
host.layoutIfNeeded()
```

`layoutIfNeeded()` также сбрасывает обновления состояний. Когда подсказка скрыта, кнопка
поднимается на её место.

## Навигация

`Stack` — модель навигации приложения. Он решает, каким будет путь, и создаёт экран для
каждого маршрута один раз. Показывает его контейнер платформы, а в тестах тот же код
работает без контейнера.

```swift
public enum MailRoute: Hashable, Sendable {
    case inbox
    case message(id: Int)
}

Stack(root: .inbox) { route in
    switch route {
    case .inbox: NodeScreen(Node())
    case .message: NodeScreen(Node())
    }
}

stack.push(.message(id: 7))  // path: [.inbox, .message(id: 7)]
stack.pop()                  // path: [.inbox]
```

В UIKit стек показывается в `UINavigationController`. Контроллер держит стек, а кнопку
«назад» и жест от края передаёт стеку:

```swift
makeMailStack().makeViewController()
```

## Код примеров

[Examples/Sources/NodesUIExamples](../Examples/Sources/NodesUIExamples). Тесты — раздел
`Nodes UI` в [ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift).

## Проверки

```sh
swift test                                           # macOS: узлы, отрисовка, AppKit
cd Benchmarks && swift run -c release ScrollBench    # проход раскладки при прокрутке демо
xcodebuild test -scheme NodesUI-Package -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -scheme NodesUI-Package -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

На macOS адаптеры UIKit собираются как пустые модули, поэтому их проверяют только тесты
на Simulator.
