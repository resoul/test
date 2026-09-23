# C02 — матрица сборки

Дата прогона: 2026-09-10. Все результаты получены на этой машине; ничего не
записано как pass без фактического запуска.

## Инструменты

| | Значение |
|---|---|
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3`) |
| Xcode | 26.6, build 17F113 |
| SDK | macOS 26.5, iOS 26.5, tvOS 26.5 |
| Deployment minimums | macOS 14, iOS 16, tvOS 16 |
| Внешние зависимости | нет; `Package.resolved` отсутствует, резолвить нечего |

Целевая платформа тестового прогона — `arm64e-apple-macos14.0`, то есть минимум
из манифеста применяется, а не подменяется версией системы.

## Mac: сборка и тесты

```bash
xcrun --sdk macosx swift build --disable-sandbox -Xswiftc -warnings-as-errors
xcrun --sdk macosx swift test  --disable-sandbox -Xswiftc -warnings-as-errors
```

| Проверка | Результат |
|---|---|
| `swift build` | PASS, 0 предупреждений |
| `swift test` | PASS, 10 тестов |

Тесты: `TrellisCoreTests` (5 — идентичность, уникальность, hashing, description)
и `TrellisRenderTests` (5 — реестр слоёв на голом `CALayer`).

## Матрица xcodebuild

Общие флаги всех прогонов:

```
CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
SWIFT_VERSION=6.0 SWIFT_STRICT_CONCURRENCY=complete
SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_SUPPRESS_WARNINGS=NO
```

### Целевые платформы

| Прогон | Схема | Destination | Результат |
|---|---|---|---|
| macos-universal | `TrellisAppKit` | `generic/platform=macOS`, `ARCHS=arm64 x86_64` | PASS |
| ios-device | `TrellisUIKit` | `generic/platform=iOS` | PASS |
| ios-simulator | `TrellisUIKit` | `generic/platform=iOS Simulator` | PASS |
| tvos-device | `TrellisUIKit` | `generic/platform=tvOS` | PASS |
| tvos-simulator | `TrellisUIKit` | `generic/platform=tvOS Simulator` | PASS |

### Проверка платформенных границ (F02)

Это главный смысл карточки. Утверждение «отдельные таргеты сами по себе решают
вопрос платформ» было **неверным**: SwiftPM компилирует платформенный таргет на
любой платформе из списка манифеста, потому что условия у таргета нет. Работает
не структура таргетов, а узкий `#if canImport(...)` внутри файлов хостов — так же,
как в Weave.

Проверено, что «чужой» платформенный таргет собирается **пустым модулем**, а не
падает:

| Прогон | Схема | Destination | Результат |
|---|---|---|---|
| x-appkit-on-ios | `TrellisAppKit` | `generic/platform=iOS` | PASS (пустой модуль) |
| x-uikit-on-macos | `TrellisUIKit` | `generic/platform=macOS` | PASS (пустой модуль) |

И весь пакет целиком — все четыре таргета сразу — на каждой платформе:

| Прогон | Схема | Destination | Результат |
|---|---|---|---|
| pkg-macos | `Trellis-Package` | `generic/platform=macOS`, universal | PASS |
| pkg-ios | `Trellis-Package` | `generic/platform=iOS` | PASS |
| pkg-tvos | `Trellis-Package` | `generic/platform=tvOS` | PASS |

## Проверки границ модулей

Выполнены вручную; в C03 становятся правилами линтера.

| Проверка | Результат |
|---|---|
| `#if os(` в `Sources/` | нет ни одного — только `canImport` |
| `import UIKit/AppKit/Cocoa/SwiftUI/Metal` в Core и Render | нет |
| `import QuartzCore/CoreGraphics` в Core | нет |
| Импорты в `TrellisCore` | **ни одного**; даже Foundation не требуется |
| `swift-format lint` по `Sources`, `Tests`, `Package.swift` | чисто |

Последняя строка важна отдельно: `.swift-format` с
`lineBreakBeforeEachArgument: true` действует с первого файла, а не вводится
позже поверх уже написанного кода.

## Что здесь ещё не проверено

- Запуск на физических устройствах — C20. Успешная сборка под
  `generic/platform=iOS` устройством не является.
- CI — C27. Локальный прогон CI не заменяет.
- API baseline — C04; стабильного публичного API пока нет.
- Отдельный внешний consumer-таргет — C04. Сейчас публичный импорт проверяется
  только тестами внутри пакета.
