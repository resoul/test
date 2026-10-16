# AsyncRayBridges

Наблюдения других пакетов в виде потоков AsyncRay. Это отдельный пакет, чтобы AsyncRay
скачивали только те, кому нужны потоки.

| Модуль | Что делает | Зависит от |
|---|---|---|
| `StateAsyncRay` | Поток → `State` (`bind(to:)`), `State` → поток (`asyncRay`) | `StateCore`, AsyncRay |
| `DataAsyncRay` | Настройка, запрос к базе и состояние WebSocket в виде потоков: `valuesRay(for:)`, `observeRay(_:)`, `statesRay` | `StorageCore`, `NetworkCore`, `StorageGRDB`, AsyncRay, GRDB |
| `PermissionAsyncRay` | Статус разрешения в виде потока: `statusRay(of:)` | `PermissionCore`, AsyncRay |

`SyncDemo` — пример приложения с тестами: репозиторий поверх базы, HTTP и сокета и
модель экранов. Это целевой модуль для тестов, а не продукт пакета.

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/AsyncRayBridges"),
    .package(url: "https://github.com/resoul/AsyncRay.git", exact: "1.0.0"),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "StateAsyncRay", package: "AsyncRayBridges"),
            .product(name: "DataAsyncRay", package: "AsyncRayBridges"),
            .product(name: "AsyncRay", package: "AsyncRay"),
        ]
    )
]
```

## Потоки в состояние экрана

Привязка записывает значения на main actor и держит состояние слабо. `SubscriptionBag`
завершает все привязки разом:

```swift
@MainActor
public final class SettingsModel {
    public let compactRows = State(false)
    public let camera = State(PermissionStatus.notDetermined)
    private let subscriptions = SubscriptionBag()

    public func bind(preferences: some PreferenceStore, permissions: Permissions) {
        let key = PreferenceKey("settings.compactRows", default: false)
        preferences.valuesRay(for: key)
            .compactMap { try? $0.get() }
            .bind(to: compactRows)
            .store(in: subscriptions)
        permissions.statusRay(of: .camera)
            .bind(to: camera)
            .store(in: subscriptions)
    }

    public func stop() {
        subscriptions.cancelAll()
    }
}
```

Сохранённое значение, которое не декодируется, приходит как `.failure`, и поток
продолжается. В примере такие значения отбрасываются, и состояние остаётся прежним.
Если отпустить подписку без `cancel()`, доставка продолжится, пока поток не закончится.
Поэтому подписки хранят в `SubscriptionBag`.

## Состояние в поток

Сначала поток выдаёт текущее значение, затем новое значение на сбросе после каждого
изменения. Изменения между двумя сбросами приходят одним значением:

```swift
await count.asyncRay.take(values).collect()
```

## Код примеров

[Examples/Sources/StreamsExamples](../Examples/Sources/StreamsExamples), а пример, где
работают все пакеты вместе, —
[Examples/Sources/TogetherExamples](../Examples/Sources/TogetherExamples). Тесты —
разделы `Streams` и `Together` в
[ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift).

## Проверки

```sh
swift test
```
