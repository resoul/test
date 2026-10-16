# Permissions

Что приложение знает о системных разрешениях: виды, статусы, ошибки и единый порядок
запросов. Внешних зависимостей нет.

| Модуль | Что делает | Зависит от |
|---|---|---|
| `PermissionCore` | `Permissions` (actor), `PermissionKind`, `PermissionStatus`, `PermissionError`; подставной `InMemoryPermissionProvider` для тестов | Foundation |
| `PermissionSystem` | `SystemPermissionProvider`: спрашивает системные фреймворки и сначала проверяет ключи Info.plist | `PermissionCore` |
| `PermissionUIKit` | `UIKitPermissions`: приложение на переднем плане, переход в Настройки | `PermissionSystem`, UIKit |
| `PermissionAppKit` | `AppKitPermissions`: то же для AppKit | `PermissionSystem`, AppKit |

## Подключение

```swift
dependencies: [
    .package(path: "../Packages/Permissions")
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "PermissionCore", package: "Permissions"),
            .product(name: "PermissionUIKit", package: "Permissions"),
        ]
    )
]
```

## Один объект на приложение

Если два экрана запрашивают одно разрешение одновременно, система показывает одно окно и
оба получают один ответ:

```swift
public func systemPermissions() -> Permissions {
    #if canImport(UIKit)
        Permissions(provider: UIKitPermissions.makeProvider())
    #elseif canImport(AppKit)
        Permissions(provider: AppKitPermissions.makeProvider())
    #endif
}
```

Перед запросом провайдер проверяет, что в Info.plist есть описание использования. Если
его нет, запрос возвращает ошибку `PermissionError`, а не роняет приложение.

## Спрашивать только тогда, когда это что-то изменит

```swift
let current = await permissions.status(of: .camera)
let status =
    PermissionKind.camera.canBeAsked(whenStatusIs: current)
    ? try await permissions.request(.camera) : current
switch status {
case .granted: return .ready
case .denied: return .sendToSettings
case .notDetermined, .restricted, .unavailable: return .unavailable
}
```

Ошибка не запоминается: следующий запрос снова обращается к системе. При отмене задачи
запрос бросает `PermissionError.cancelled`.

Чтобы заметить изменение разрешения в Настройках, приложение перечитывает статусы,
когда возвращается на передний план. Это делает
`permissions.follow(UIKitPermissions.foregroundChanges())`, запущенный в отдельной задаче.

## Тесты и превью

```swift
let provider = InMemoryPermissionProvider()
await provider.willAnswer(answer, for: .camera)
return Permissions(provider: provider)
```

С ответом `.granted(.full)` пример возвращает `.ready`, с ответом `.denied` —
`.sendToSettings`.

## Код примеров

[Examples/Sources/PermissionsExamples](../Examples/Sources/PermissionsExamples). Тест —
`theCameraIsAskedForOnlyWhenAskingCanChangeSomething` в
[ExamplesTests.swift](../Examples/Tests/ExamplesTests/ExamplesTests.swift).

## Проверки

```sh
swift test
```

Тесты подменяют системные фреймворки и окно запроса не показывают. Реальный запрос
разрешения проверяется только в приложении на устройстве или в Simulator.
