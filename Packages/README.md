# Пакеты

Библиотека, разделённая на самостоятельные SwiftPM-пакеты. Каждый пакет собирается и
проходит свои тесты без остальных. Пакеты верхнего ряда подключают нижние обычными
зависимостями.

```
                    Приложение
                 /              \
          NodesUI            AsyncRayBridges
        /    |    \          /   |    |    \
  Layout  Basics  Data   Basics Data Database Permissions
```

| Пакет | Модули | Зависит от | Внешние зависимости | Руководство |
|---|---|---|---|---|
| `Layout` | `FlexEngine`, `LayoutCore`, `ThemeCore`, `LayoutUIKit`, `LayoutAppKit` | — | — | [Layout/README.md](Layout/README.md) |
| `Basics` | `StateCore`, `RichTextCore`, `LocalizationCore`, `Tracing` | — | — | [Basics/README.md](Basics/README.md) |
| `Data` | `StorageCore`, `StorageFoundation`, `NetworkCore`, `NetworkFoundation`, `NetworkStorage` | — | — | [Data/README.md](Data/README.md) |
| `Database` | `StorageGRDB` | — | GRDB | [Database/README.md](Database/README.md) |
| `Permissions` | `PermissionCore`, `PermissionSystem`, `PermissionUIKit`, `PermissionAppKit` | — | — | [Permissions/README.md](Permissions/README.md) |
| `NodesUI` | `Nodes`, `NodesRender`, `NodesUIKit`, `NodesAppKit`, `AppShell`, `AppShellUIKit`, `AppShellAppKit` | `Layout`, `Basics`, `Data` | — | [NodesUI/README.md](NodesUI/README.md) |
| `AsyncRayBridges` | `StateAsyncRay`, `DataAsyncRay`, `PermissionAsyncRay` | `Basics`, `Data`, `Database`, `Permissions` | AsyncRay, GRDB | [AsyncRayBridges/README.md](AsyncRayBridges/README.md) |
| `Examples` | примеры всех руководств | все пакеты | AsyncRay, GRDB | этот файл |

## Как это работает отдельно

- SwiftPM скачивает зависимости только тех пакетов, которые вы подключили. Если нужна
  только раскладка, подключается `Layout`, а GRDB и AsyncRay не скачиваются.
- У пакетов нижнего ряда нет зависимостей внутри репозитория. Их можно выпускать и
  проверять по одному.
- `NodesUI` берёт из `Data` только модули `NetworkCore` и `StorageCore`: они нужны
  кэшу картинок (проверка свежести по HTTP-заголовкам и одна загрузка на ключ). Оба
  модуля зависят только от Foundation.

## Как это собирается вместе

Пакет подключается по пути (пока все пакеты лежат в одном репозитории):

```swift
dependencies: [
    .package(path: "../Packages/Layout"),
    .package(path: "../Packages/NodesUI"),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "LayoutCore", package: "Layout"),
            .product(name: "Nodes", package: "NodesUI"),
        ]
    ),
]
```

Пакет [Examples](Examples/Package.swift) подключает все пакеты сразу. Этим он проверяет,
что пакеты разрешаются вместе: имена продуктов не конфликтуют, версии AsyncRay и GRDB
совпадают. Каждый целевой модуль примеров зависит только от пакета, который показывает,
а `TogetherExamples` соединяет несколько пакетов в одном экране:

```swift
/// A list whose density follows a stored preference — the packages together: the data
/// package stores the preference, the bridges stream it into a state, the node tree reads the
/// state, and the layout package lays the rows out with the theme's spacing.
@MainActor
public final class DensityListNode: Node {
    /// Whether rows are compact; bound to the stored preference.
    public let compact = State(false)
    /// The rows.
    public let rows = (0..<3).map { _ in RowNode() }
    private let subscriptions = SubscriptionBag()

    /// Follows `key` in `preferences` until the node goes.
    public func follow(_ key: PreferenceKey<Bool>, in preferences: some PreferenceStore) {
        preferences.valuesRay(for: key)
            .compactMap { try? $0.get() }
            .bind(to: compact)
            .store(in: subscriptions)
    }

    /// Row heights follow the density.
    public override func update() {
        for row in rows { row.height.value = compact.value ? 32 : 44 }
    }

    /// The rows in a column, closer together when compact.
    public override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for row in rows { row }
        }
        .gap(compact.value ? .s1 : .s3)
        .padding(.s4)
    }
}
```

Полный код — [TogetherExample.swift](Examples/Sources/TogetherExamples/TogetherExample.swift).
Тест `aStoredPreferenceReachesTheLayoutThroughAState` проверяет, что изменение
настройки в хранилище меняет рамки строк.

## Проверки

Каждый пакет отдельно (из папки пакета):

```sh
swift build --build-tests
../../Scripts/run-with-deadline.sh 1500 -- swift test
```

Всё вместе и примеры руководств:

```sh
cd Packages/Examples && ../../Scripts/run-with-deadline.sh 600 -- swift test
```

Бенчмарки — отдельные пакеты рядом с тем, что они измеряют:

```sh
cd Packages/Layout/Benchmarks && swift run -c release LayoutBench
cd Packages/NodesUI/Benchmarks && swift run -c release ScrollBench
```

Адаптеры UIKit на macOS собираются как пустые модули. Их проверка — тесты на Simulator
из папки пакета:

```sh
xcodebuild test -scheme NodesUI-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Состояние

Пакеты в этой папке — копия модулей корневого пакета, разложенная по блокам. Корневой
`Package.swift`, демо и корневые бенчмарки по-прежнему собираются из `Sources/`. Пока
переезд не закончен, изменения в `Sources/` нужно повторять здесь.
