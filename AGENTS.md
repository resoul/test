# Правила работы в Espalier

Этот файл — правила для кода пакета Espalier. Они переживут документы проектирования:
решения, планы и анализ в `docs/` будут удалены, когда выйдет чистая версия.

## Комментарии в коде

**Код и его комментарии не ссылаются на наши документы.** Никаких «сделано так, потому что
D09», «см. ADR 0007», «по плану, этап E1», «дефект #95», «docs/10-…». Комментарий
объясняет, *что* делает код и *почему* он устроен именно так — своими словами, так, чтобы
это было понятно без единого внешнего md-файла.

- Плохо: `// request-local cache (Trellis ADR 0007)`.
- Хорошо: `// The cache lives exactly as long as the pass and has no size limit: a container
  measures each child several times with the same constraints, and evicting those entries
  makes nested layouts exponential in depth.`

Связь «функция → документ, решение, дефект» ведётся отдельно, в
[docs/code-map.md](docs/code-map.md). Когда документы удаляются, эта карта удаляется
вместе с ними, а код остаётся понятным.

**Исключение — внешние стандарты.** Ссылки на разделы спецификаций вроде `CSS Flexbox
§9.7` допустимы: это публичный документ, который не исчезнет, и он описывает, что
реализует код.

Пути к данным, которые код читает (например, фикстуры в `Conformance/`), — не ссылки на
документацию, а часть поведения; их упоминать можно.

## Имена

**Имена модулей, папок, файлов, типов и переменных окружения описывают содержимое** и не
содержат названия продукта (`Espalier`, `Trellis`) или кодового имени версии (`v22`): продукт может
получить другое имя, версия — другой номер. Так: модуль `LayoutCore`, тесты
`LayoutCoreTests`, baseline `expectations/engine.json`, переменная
`CSS_CONFORMANCE_RECORD`.

Исключение — имя самого пакета (`Espalier`). Пути в документах и командах — от корня пакета,
чтобы переезд пакета в другой репозиторий их не менял.

## Остальные правила

- **Изоляция.** `@unchecked Sendable`, `nonisolated(unsafe)` и `@preconcurrency` запрещены.
  Модуль раскладки — чистые функции над иммутабельными `Sendable`-значениями.
- **Платформа.** `LayoutCore` импортирует только Foundation и собирается на Linux. `#if os(...)`
  запрещён. UIKit/AppKit — только в адаптерах (`LayoutUIKit`, `LayoutAppKit`, `NodesUIKit`,
  `NodesAppKit`), под `#if canImport(...)` в самих файлах. AppKit-адаптеры — под
  `#if canImport(AppKit) && !canImport(UIKit)`: в Mac Catalyst импортируются оба фреймворка,
  но `NSView` там нет, и приложение пользуется UIKit-адаптером.
- **Документация публичного API.** Каждое `public` объявление несёт `Ownership:`,
  `Isolation:`, `Errors:`, `Cancellation:`.
- **Отмена.** Отменённый проход бросает `LayoutCancelled` и ничего не возвращает;
  частичный результат отменой не является.
- **Печать.** В движке нет `print`. Диагностика — через значение, которое возвращается
  вызывающему, или необязательный записывающий объект в контексте.
- **Формат.** `swift format` с `.swift-format` в корне пакета:
  `swift format lint --configuration .swift-format --recursive Package.swift Sources Tests`.

## Проверки

```sh
swift build
swift test                                                   # включая CSS conformance
CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance   # записать новый baseline
cd Benchmarks && swift run -c release LayoutBench            # скорость: новый движок против старого
```

Эталоны CSS — `Conformance/CSSFlexbox/` (генерация — `generate.cjs` через Chromium,
[README](Conformance/CSSFlexbox/README.md)).

Адаптеры UIKit собираются и тестируются только на Simulator — на macOS это пустые модули.
Изменение адаптера не закончено без прогона:

```sh
xcodebuild test -scheme Espalier-Package -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -scheme Espalier-Package -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Фокус пульта на живом экране — UI-тест tvOS-демо (`XCUIRemote`):

```sh
cd Demo && xcodebuild test -project Demo.xcodeproj -scheme LayoutDemoTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

## Отчётность

- Каждый найденный дефект — строка в [docs/defects.md](docs/defects.md) в момент
  обнаружения, до исправления. Исправление дописывает коммит; неисправленное остаётся
  «открыт» с тем, где закрыть.
- Незакрытое называется незакрытым, с причиной.
- Проверка на Simulator не выдаётся за проверку на устройстве. Недоступное устройство —
  «нет доступа», а не «пройдено».
