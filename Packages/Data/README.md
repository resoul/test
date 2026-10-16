# Data

Хранилище и сеть поверх Foundation, без сторонних зависимостей. Ядро описано
протоколами и даёт реализации в памяти для тестов. Реализации на системных фреймворках
вынесены в отдельные модули.

| Модуль | Что делает | Зависит от |
|---|---|---|
| `StorageCore` | Настройки как типизированные ключи над `PreferenceStore`, файловые хранилища (`FileStore`, `FilePath`), кэши, общие загрузки по ключу; хранилища в памяти | Foundation |
| `StorageFoundation` | `UserDefaultsPreferences`, `DiskFileStore`, дисковый кэш | `StorageCore` |
| `NetworkCore` | HTTP- и WebSocket-клиент над протоколом транспорта: статусы, повторы, учётные данные, валидаторы кэша | Foundation |
| `NetworkFoundation` | Транспорты на `URLSession`, фоновые передачи, наблюдение за сетью | `NetworkCore` |
| `NetworkStorage` | Скачивание HTTP-ответа сразу в файловое хранилище | `NetworkCore`, `StorageCore` |

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/Data")
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "StorageCore", package: "Data"),
            .product(name: "StorageFoundation", package: "Data"),
            .product(name: "NetworkCore", package: "Data"),
            .product(name: "NetworkFoundation", package: "Data"),
        ]
    )
]
```

## Настройки

Ключ задаёт имя значения и значение по умолчанию, которое читается, пока ничего не
сохранено. Где лежат значения, ключ не определяет: их хранит любой `PreferenceStore`.

```swift
public enum Settings {
    public static let compactRows = PreferenceKey("settings.compactRows", default: false)
    public static let windowWidth = PreferenceKey("settings.windowWidth", default: 800.0)
}

try await store.set(true, for: Settings.compactRows)
try await store.set(1024, for: Settings.windowWidth)
let compact = try await store.value(for: Settings.compactRows)
```

Одинаковый код работает и с `MemoryPreferences()` в тестах, и с `UserDefaults` в
приложении:

```swift
UserDefaultsPreferences(namespace: "example.")
```

Если сохранённое значение другого типа, это ошибка `PreferenceError`, а не значение по
умолчанию. Вернуться к умолчанию можно через `remove(_:)`. `values(for:)` выдаёт
значение и все последующие изменения потоком.

## Файлы

`FilePath` проверяет относительный путь и не пропускает пути за пределы хранилища,
например `../x`:

```swift
try await store.write(Data(text.utf8), to: FilePath("notes/today.txt"))
return try await store.list(FilePath("notes")).map { "\($0.path)" }
```

`MemoryFileStore()` — хранилище для тестов. В приложении используется
`try DiskFileStore(location: .caches, subdirectory: "Example")` или `.applicationSupport`,
`.documents`.

## HTTP

Клиент добавляет политику — статусы, повторы, учётные данные — поверх любого
транспорта. Поэтому в тестах и превью сервер не нужен:

```swift
public struct CannedTransport: HTTPTransport {
    public let body: Data

    public func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: body,
            url: request.url
        )
    }
}
```

В приложении в клиент передаётся `URLSessionTransport()`:

```swift
HTTPClient(
    transport: transport,
    baseURL: URL(string: "https://api.example.com/v1/"),
    defaultHeaders: ["Accept": "application/json"],
    retry: RetryPolicy(maxAttempts: 3)
)
```

Запрос строится от `baseURL`, ответ должен быть `2xx`, тело декодируется как JSON:

```swift
let request = try client.request(
    .get,
    "items",
    query: [URLQueryItem(name: "limit", value: "20")]
)
return try await client.send(request, as: [Item].self)
```

Все ошибки клиента — типизированные `HTTPError`: статус, транспорт, декодирование.
Отмена задачи отменяет запрос.

## Скачивание в хранилище

`NetworkStorage` скачивает ответ во временный файл и переносит его в хранилище, не
держа всё тело в памяти, если транспорт это позволяет:

```swift
let request = try client.request(.get, "items")
let stored = try await client.download(request, into: store, at: FilePath("cache/items.json"))
return stored.bytes
```

## Код примеров

[Examples/Sources/DataExamples](../Examples/Sources/DataExamples). Тесты — раздел `Data` в
[ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift).

## Проверки

```sh
swift test
```

Тесты `NetworkFoundation` поднимают локальные HTTP- и WebSocket-серверы на `127.0.0.1`;
внешняя сеть им не нужна.
