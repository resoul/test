# NodesUI

Дерево узлов поверх пакета `Layout` и слой приложения: экраны, стеки навигации, вкладки,
разделённые окна. Узлы раскладываются движком, управляются состоянием из `StateCore` и
рисуются в `CALayer`. Сами по себе узлы не зависят от UIKit и AppKit — их показывают
адаптеры. Дальнейшая поддержка и проверки сосредоточены на iOS и macOS; tvOS исключён
из поддерживаемого scope.

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

### Фоновая раскладка

`host.solvesInBackground = true` переносит расчёт последующих проходов на поток хоста
со стеком 8 МиБ. Подготовка `layoutSpec()` и `update()`, применение рамок и callbacks
остаются на MainActor. Хост передаёт solver только `LayoutRequest`, получает
`ComputedLayout` и применяет его через соответствующий `PreparedLayout`.

Первый проход, main-only содержимое и срочные проходы прокрутки сохраняют синхронный
путь. При нехватке стека синхронный расчёт без main-only содержимого переносится на
поток хоста; main-only проход отклоняется с отчётом.

Во время расчёта дерево сохраняет предыдущие рамки. Изменение размера, окружения или
контента инвалидирует результат сразу, даже если следующий проход ещё не запущен.
Перед применением хост повторно проверяет поколение, размер и отсутствие инвалидации,
в том числе после `onLayoutReport`. Отменённые и устаревшие результаты не монтируют
узлы и не запрашивают отрисовку. Анимация отклонённого устаревшего прохода переходит
к следующему, если новое изменение не задало другую анимацию.

`await host.layoutFinished()` ждёт проход, выполняющийся в момент вызова. Если он
устарел, ожидание завершится без применения; оно не запускает новую раскладку и не
включает проход, который callback мог запустить позднее.

## Потребность и готовность контента

`ContentDemand` описывает, какая работа нужна элементу, независимо от завершения:
`.preload` — данные, `.display` — подготовка для показа, `.visible` — активные эффекты
показа. `.measure` отдельно запрашивает геометрию. Эффективная потребность расширяет
Visible до Display, Preload и Measure; это не последовательность завершённых стадий.

`ContentLifecycle<Key>` работает по ключу модели до создания Node. Ключ включает id,
версию, ограничения размера и значимое окружение. Три независимых значения
`readiness.data`, `.measurement`, `.drawing` принимают состояния idle/running/ready/
failed/cancelled. Пока нужный результат не готов, владелец показывает выбранный
placeholder; Visible само по себе готовности не обещает.

```swift
let viewport = ContentViewport(
    bounds: LayoutRect(x: 0, y: 0, width: 320, height: 600),
    activity: .active
)
let policy = ContentRangePolicy()
var item = ContentLifecycle(key: 42) // Include revision and constraints in an application key.
let frame = LayoutRect(x: 0, y: 650, width: 320, height: 80)
let requested = policy.demand(for: frame, in: viewport, previous: item.demand)
let change = item.updateDemand(requested)
let measurementTicket = item.begin(.measurement)
```

Это только вычисление потребности и выдача ticket, без запуска работ. Владелец на
своём сериализованном executor (для UI — MainActor) обрабатывает `change.entered` и
`.exited`, отменяет клиентские ожидания из `.cancelled` и запускает работы в пределах
своего бюджета. `begin` не выдаёт второй ticket для running/ready-фазы. Ticket можно
передать worker без живого Node. Завершение принимается через
`complete(ticket, with: .ready/.failed/.cancelled)`; только при `true` владелец
применяет результат или ошибку на том же executor без промежуточного await/callback.
Сам механизм callbacks не вызывает.

Выход из диапазона сохраняет ready-результаты и ошибки, инвалидирует только ненужные
текущие попытки. Возврат не запускает готовое заново; после ошибки нужен
`begin(phase, retrying: true)`. `reset(for:)` сохраняет потребность, но инвалидирует все
попытки и готовность даже при том же ключе. `release(phase)` позволяет освободить одну
фазу. Ресурсы, задачи и ошибки принадлежат вызывающему; отмена его ожидания не должна
отменять загрузку других клиентов общего кэша.

`ContentViewport` пересекает bounds с переданными clips в общей системе координат.
`.active` допускает Visible, `.preparing` — подготовку соседней панели без Visible,
`.inactive` — отсутствие работы. `ContentRangePolicy` учитывает обе оси и более широкие
пороги удержания. Для скрытой соседней панели можно передать её предполагаемое окно и
`.preparing`; для полностью обрезанного реального окна потребность пуста.

Это отдельный контракт для подготовленного контента. Ниже описана его опциональная
привязка к LazyStack. Node tracksScreen, старые prefetch callbacks, пагинация и
DisplayRange renderer продолжают обслуживать свои задачи отдельно.

## Подготовка строк LazyStack

Дополнительный initializer принимает `key`, `prepare` и фабрику с `PreparedItemState`.
Модель и её id должны быть Sendable. В этом примере Post, PostRow и prepareRowPlan —
типы и функции приложения; rowCache хранит идентичность живой строки.

```swift
let rowCache = NodeCache<Post.ID, PostRow> { _ in PostRow() }
let posts = LazyStack<Post>(
    estimatedLength: 72,
    preparation: ItemPreparationPolicy(
        maximumConcurrentTasks: 2,
        maximumQueuedItems: 16,
        maximumRetainedItems: 64
    ),
    key: { $0.revision },
    prepare: { post, context in
        let plan = try await prepareRowPlan(post, width: context.crossAxisLength)
        return PreparedItem(plan, length: plan.height)
    },
    content: { post, state in
        let row = rowCache[post.id]
        switch state {
        case .pending: row.showPlaceholder(post)
        case let .ready(prepared): row.show(prepared.value)
        case let .failed(error): row.showFailure(error)
        }
        return row
    }
)
let scroll = Scroll(.vertical, content: posts)
```

После первой применённой раскладки список получает действительную ширину элемента
(для grid — долю lane), вычисляет потребность по модели и готовит планы до создания
дальних Node. Выбор учитывает обе оси, clips и прозрачность предков. Скрытый host,
фоновое приложение или отсутствие пересечения с viewport останавливают подготовку;
показанный соседний контейнер с предполагаемым окном потребует отдельной координации.
Горизонтальному grid нужно задать конечную высоту, чтобы разделить её между lanes.

`prepare` запускается в detached task. Живые Node, update, layoutSpec и фабрика остаются
на MainActor. Фабрика должна быть лёгкой: для холодного или срочного входа она показывает
placeholder, не дожидаясь сети. Данные и рисунок могут готовиться самим контентом;
этот путь координирует план измерения, не объявляет весь ресурс готовым автоматически.

Identity, ширина/высота lane, размер host, scale, direction, resolved theme и locale
добавляются к ключу автоматически. В `key` нужно включить revision и дополнительные
входы приложения, например версию собственного каталога. Передавать следует
иммутабельные снимки модели; заменять `items` при изменениях. Удалённый, отменённый или
устаревший результат не попадает в фабрику. Готовый план применяется только следующим
актуальным layout pass; `length` уточняет оценки дальних строк с сохранением якоря.

Бюджет действует на один список. Отменённый worker занимает слот до возврата, даже если
игнорирует отмену. Очередь пересматривается при движении viewport: Visible идёт раньше
Display и дальнего Preload. Кэш ограничен числом entries, а не байтами; при слишком
маленьком retention-бюджете лишние элементы остаются pending до изменения admission.
Ресурсы и Node, удерживаемые приложением, этот лимит не освобождает.

Ошибка не запускает бесконечный retry: `posts.retryPreparation(for: id)` повторяет
retained failure. `preparationProgress` показывает running/queued/retained;
`await posts.preparationsFinished()` ждёт опустошения admitted очереди, включая новые
задачи во время ожидания, но не выполняет layout и не прерывает worker ожиданием.
Все closures удерживаются списком: не захватывайте его сильно. Для общего ресурса
отменяйте клиентское ожидание, сохраняя работу остальных клиентов.

Обычный initializer с `(Item) -> Node` остаётся синхронным. Table имеет prepared
initializer, описанный ниже. Общего бюджета между разными списками пока нет.

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


### Подготовка Table и renderer

`Table` поддерживает тот же prepared initializer, что и `LazyStack`:

```swift
let table = Table<Message>(
    estimatedRowHeight: 60,
    preparation: ItemPreparationPolicy(maximumConcurrentTasks: 2),
    key: { $0.revision },
    prepare: { message, context in
        let plan = try await prepareMessage(message, width: context.crossAxisLength)
        return PreparedItem(plan, length: plan.height)
    },
    row: { message, state in cells[message.id].showing(message, state: state) }
)
```

`prepareMessage` и `showing` здесь — функции приложения. Worker получает Sendable
модель и окружение без Node. `row` создаёт или обновляет Node на MainActor и показывает
pending/failed/ready. Ключ приложения включает все значимые изменения модели;
Table дополнительно учитывает constraints, окружение и форму editing-контролов.
`context.crossAxisLength` — ширина самого содержимого после отметки выбора и ручки
перемещения. `PreparedItem.length` — высота содержимого; Table учитывает минимальную
высоту контролов. Секции, headers, свайпы, selection, перемещение и pagination
используют существующий Table; `scrolls: false` поддерживает внешнюю прокрутку.
`preparationProgress`, `retryPreparation(for:)` и `preparationsFinished()` доступны
через Table. Лимиты считаются вместе с headers. Отдельного `ListView` для этого не нужно.

Для отрисовки и ресурсов настраивается общий host:

```swift
host.solvesInBackground = true
host.drawingMode = .asynchronous
host.contentRangePolicy = ContentRangePolicy(
    preloadDistance: 2,
    displayDistance: 0.5,
    preloadRetentionDistance: 3,
    displayRetentionDistance: 1
)
let picture = Image(source: source, loadingMode: .demandDriven)
```

`contentRangePolicy` имеет приоритет над старым `displayRange`. `Node.contentDemand`
учитывает host, clips предков, обе оси и zoom; скрытые/прозрачные предки, unshown host
и фон не требуют работы. Renderer пересматривает этот opt-in контракт при render и
каждом `renderScrolls`, передаёт изменения через `LayerDrawing.contentDemandChanged`,
а при удалении ноды передаёт пустую потребность. Только Display допускает
`prepareDrawing`, `layerImage` и bitmap. Старое `displayRange == nil` без новой policy
сохраняет рисование всех смонтированных нод.

`ImageLoadingMode.immediate` остаётся значением по умолчанию. В `.demandDriven` до
первого render загрузки нет: Preload получает encoded bytes, Display декодирует preview
и затем разрешает refinement под размер, Visible повышает urgency общего ресурса.
Выход из Display отменяет клиентские decode waits и освобождает pixels ноды; выход из
Preload отменяет ожидание байтов. Общие caches и другие клиенты сохраняются.
`Image.contentReadiness` показывает data/drawing отдельно; measurement здесь не
отслеживается. Ошибка ждёт `retry()` или смену source. `ImagePipeline.preload(_:)`
можно вызвать из model preparation до создания Image; он не декодирует изображение.

У `LayerRenderer` по умолчанию два bitmap worker и не более 16 ожидающих snapshots.
Отменённый worker сохраняет слот до реального возврата; остальные mounted identities
ждут без snapshot. Очередь приоритизируется по текущей близости к экрану. Лимиты
задаются через `LayerRenderer(preparation: DrawingPreparationPolicy(...))` при ручном
использовании renderer. `runningDrawCount`, `queuedDrawCount`, `pendingDrawCount`,
`contentDemand(for:)`, `drawingState(for:)` доступны для диагностики. Последняя
готовность относится к содержимому CALayer, включая placeholder; загрузку ресурса
нужно смотреть у Image. Counts ограничивают задачи, а не суммарные байты bitmap.

Перед commit фонового bitmap renderer повторно проверяет ticket, drawingRevision,
размер, scale, mount, dirty layout и текущую потребность. Text с Sendable snapshot
рисуется в фоне; custom drawing без snapshot остаётся на MainActor. Создание/обновление
Node, захват snapshot, размещение CALayer и UI commit также остаются на MainActor.
