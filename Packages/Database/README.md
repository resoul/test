# Database

База данных SQLite поверх GRDB: миграции, транзакции, наблюдение за запросами, резервные
копии. Это отдельный пакет, чтобы GRDB скачивали только те, кому нужна база.

| Модуль | Что делает | Зависит от |
|---|---|---|
| `StorageGRDB` | `DatabaseStore` (actor): `open`, `read`, `write`, `observe`, `backup`, `restore`, `close`; `DatabaseMigration` | GRDB |

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/Database"),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "StorageGRDB", package: "Database"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]
    )
]
```

Запросы пишутся на GRDB (`Database`, `fetchAll`, `execute`), поэтому модулю с запросами
нужен и продукт `GRDB`.

## Схема

Миграции применяются по порядку. Хранилище помнит, какие из них уже выполнены:

```swift
public let todoMigrations = [
    DatabaseMigration("createTodo") { db in
        try db.create(table: "todo") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("title", .text).notNull()
            table.column("done", .boolean).notNull().defaults(to: false)
        }
    }
]
```

## Чтение, запись, наблюдение

```swift
let store = try await DatabaseStore.open(location, migrations: todoMigrations)
let openTitles: @Sendable (Database) throws -> [String] = { db in
    try String.fetchAll(db, sql: "SELECT title FROM todo WHERE done = 0 ORDER BY id")
}

var updates = await store.observe(openTitles).makeAsyncIterator()
seen.append(try await updates.next()?.get() ?? [])

try await store.write { db in
    try db.execute(
        sql: "INSERT INTO todo (title) VALUES (?), (?)",
        arguments: ["Milk", "Bread"]
    )
}
seen.append(try await updates.next()?.get() ?? [])

let total = try await store.read { db in
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todo") ?? 0
}
try await store.close()
```

- `location` — `.inMemory` для тестов и `.file(url)` в приложении.
- `write` выполняет тело в транзакции. Если тело бросает ошибку, транзакция
  откатывается.
- `observe` сразу выдаёт результат запроса, а потом новый результат после каждой
  фиксации, которая изменила прочитанные запросом данные. Медленный потребитель
  получает только последний снимок. Если отменить итерацию, наблюдение остановится.
- Ошибка запроса приходит как `.failure` и завершает поток.

В примере наблюдение видит `[]`, затем `["Milk", "Bread"]`, затем `["Bread"]`.

## Код примеров

[Examples/Sources/DatabaseExamples](../Examples/Sources/DatabaseExamples). Тест —
`theDatabaseMigratesWritesAndIsFollowed` в
[ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift).

## Проверки

```sh
swift test
```
