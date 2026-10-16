# Basics

Четыре небольших модуля, которые зависят только от Foundation и друг от друга не
зависят. Каждый можно подключить отдельно.

| Модуль | Что делает |
|---|---|
| `StateCore` | Синхронное состояние на main actor с автоматическим отслеживанием зависимостей: `State`, `Computed`, `Effect`, `Observer` |
| `RichTextCore` | Текст со стилями как значение: блоки, отрезки, отметки, ссылки; чтение и запись Markdown; операции редактора |
| `LocalizationCore` | Тексты по ключу для языка читателя: каталоги, формы множественного числа, запасные языки, псевдолокализация |
| `Tracing` | Отметки участков работы (signposts) для Instruments и наблюдатель записей для тестов и инструментов |

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/Basics")
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "StateCore", package: "Basics"),
            .product(name: "LocalizationCore", package: "Basics"),
        ]
    )
]
```

## StateCore

Чтение состояния внутри `Computed` или `Effect` подписывает на это состояние, объявлять
зависимости не нужно. Наблюдатели срабатывают на сбросе (flush): несколько записей
подряд доходят до них один раз.

```swift
@MainActor
public final class CartModel {
    public let price = State(250)
    public let count = State(1)
    public private(set) lazy var total = Computed { self.price.value * self.count.value }
}

let cart = CartModel()
var label: [String] = []
let effect = Effect { label.append("Total: \(cart.total.value)") }

cart.count.value = 2
cart.count.value = 3
cart.price.value = 300
// Observers run at a flush: the app's run loop flushes on its own; here we flush by hand.
StateUpdates.flush()

effect.cancel()
```

`label` получает `["Total: 250", "Total: 900"]`. Первое значение `Effect` записывает
сразу при создании, второе — на сбросе. Состояния держат эффект слабо: если его
отпустить, он остановится, как и после `cancel()`.

## RichTextCore

```swift
var text = RichText(markdown: markdown)
let firstWord = text.plainText.prefix { !$0.isWhitespace }
let range = text.range(utf16Location: 0, length: firstWord.utf16.count)
text.toggle(.bold, in: range)
return text.markdown
```

`"Hello world"` превращается в `"**Hello** world"`. Позиции в тексте — `RichPosition`
и `RichRange`. Перевод в смещения UTF-16 и обратно (`range(utf16Location:length:)`,
`utf16Range(of:)`) связывает текст с текстовыми представлениями платформы.

## LocalizationCore

```swift
var catalog = LocalizationCatalog()
catalog.insert(.text("Inbox"), for: "inbox.title", language: "en")
catalog.insert(.text("Входящие"), for: "inbox.title", language: "ru")
catalog.insert(
    .plural([.one: "%1$@ unread message", .other: "%1$@ unread messages"]),
    for: "inbox.unread",
    language: "en"
)
catalog.insert(
    .plural([
        .one: "%1$@ непрочитанное", .few: "%1$@ непрочитанных", .many: "%1$@ непрочитанных",
    ]),
    for: "inbox.unread",
    language: "ru"
)

let localizer = CatalogLocalizer(catalog: catalog, fallbackLanguages: ["en"])
let text = LocalizedText("inbox.unread", count: count)
return localizer.resolve(text, locale: Locale(identifier: localeIdentifier)).text
```

Для `ru_RU` получается `5 непрочитанных` и `21 непрочитанное`; для `de_DE` текст берётся
из запасного английского — `3 unread messages`. Количество подставляется первым
аргументом. В приложении каталог читается из строковых файлов бандла:
`LocalizationCatalog.main`. Узлы `NodesUI` разрешают `LocalizedText` для локали своего
дерева сами.

## Tracing

Библиотека отмечает свою работу — раскладку, отрисовку, декодирование, загрузку
страниц — и эти участки видны в Instruments. Те же имена доступны приложению, а
наблюдатель получает записи с любого потока:

```swift
let records = Recorded()
let observation = Trace.observe { records.append($0) }
defer { observation.cancel() }

_ = Trace.measure(.decode, "avatar.png") {
    Data(count: 1024).count
}
```

Наблюдатель получает начало и конец участка (`.begin`, `.end`). Пока никто не
наблюдает и Instruments не записывает, текст детали не строится.

## Код примеров

[Examples/Sources/BasicsExamples](../Examples/Sources/BasicsExamples). Тесты — раздел
`Basics` в [ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift).

## Проверки

```sh
swift test
```
