# C03 — проверки качества

Дата: 2026-09-10. C03 реализована. Swift-файлы и незакоммиченные изменения
пользователя из C02 сохранены; Weave не изменялся.

## Что добавлено

- `check_policy.py` + `swift_lex.py`: исходный текст для secrets/docs/TODO,
  маска для code-only правил с сохранением позиций и исполняемых интерполяций.
- `test_policy.py`: 20 тестовых методов с подслучаями, включая восемь
  перенесённых негативных файловых фикстур Weave.
- `test_verifier.py`: три теста manifest-контракта и остановки после ошибки
  команды; намеренно неуспешная команда внутри этого теста ожидаема.
- `verify_bootstrap.py`: пины toolchain, swift-format, manifest без внешних
  зависимостей, сборка/тесты, отдельный локальный consumer и optional matrix.
- `check_all.py`: единая последовательность реализованных C03 проверок.
- `policy.json`/`toolchain.json`: linter 2.0.0 и сохранённые toolchain pins C02.
- `.github/workflows/quality.yml`: workflow обычного C03 gate. Hosted запуск
  не выполнялся; наличие YAML не записывается как PASS CI.

Существующая `.swift-format` не менялась. Базовый consumer импортирует
TrellisCore/TrellisRender/TrellisAppKit без `@testable`, использует публичный
NodeID.Type, LayerRegistry и тип AppKit-хоста. Он не создаёт NSApplication
или окно. API baseline, subclass/DSL consumer и соответствующая расширенная
проверка остаются задачей C04.

## Правила

Проверяются PLATFORM_IMPORT, CORE_IMPORT, ADAPTER_GUARD,
PLATFORM_CONDITION, COCOA_LIFECYCLE, UNSAFE_CONCURRENCY, FORCE_OPERATION,
PUBLIC_DOCUMENTATION, TODO_OWNER, GUARD_IF_BLANK_LINE,
LINEAR_IDENTITY_LOOKUP, MARKDOWN_LINK, четыре семейства SECRET, версия и
корректность конфигурации. Найденный секрет в диагностике не печатается.

TODO/FIXME в Swift-комментариях требуют стабильный ID: `TODO(C03)` или
`FIXME(PROJ-123)`. Правило пробела перед return намеренно отсутствует:
оно остаётся конвенцией ревью, как требует карточка. Это явно записано в
policy.json. Разрешённые исключения требуют точного относительного пути,
правил и причины; текущее множество исключений пусто.

Проверка документации охватывает явные public/open, в том числе var/let,
многострочные объявления, атрибуты и private(set). Неявная видимость членов
protocol/public extension требует ревью. Это лексический линтер, не Swift
AST: regex literals, macro expansion и вывод доступа не входят в его
контракт. Фикстуры гарантируют заявленную обработку строк/комментариев,
включая nested block comments, raw/multiline/escaped strings и вложенные
исполняемые интерполяции. Политика линейного поиска — защита от конкретной
регрессии, а не доказательство асимптотики произвольного кода.

## Выполненные проверки

| Проверка | Результат |
|---|---|
| `python3 Scripts/check_all.py` | PASS |
| Policy исходников и документов | PASS, 0 diagnostics |
| Policy fixtures | PASS, 20 тестовых методов с подслучаями |
| Verifier tests | PASS, 3 теста |
| Swift build и test | PASS, 10 Swift-тестов C02 |
| swift-format с текущей конфигурацией | PASS |
| Отдельный локальный consumer | PASS |
| macOS universal, arm64/x86_64 | PASS, сборка Trellis-Package |
| iOS device / simulator | PASS, сборки Trellis-Package |
| tvOS device / simulator | PASS, сборки Trellis-Package |

Обычный gate выполнен в среде с ограничениями доступа. Первая попытка
xcodebuild-матрицы внутри песочницы не прошла из-за доступа к системным
сервисам/каталогам Xcode; после разрешённого запуска вне песочницы все пять
destinations прошли. Это generic builds, не запуск физических устройств.

Команды:

```bash
python3 Scripts/check_all.py
python3 Scripts/verify_bootstrap.py --matrix --output .build/c03-matrix
```

Логи, команды и exit codes: `.build/bootstrap-validation/results.json` и
`.build/c03-matrix/results.json`, рядом отдельный log каждой команды. Логи
не включаются в git. Последний обычный прогон использует локальные SwiftPM
cache/config/security каталоги в `.build/verification-swiftpm`, не устаревший
флаг `--skip-update`. Команды Xcode-матрицы от этого не изменились.

Toolchain: Xcode 26.6 (17F113), Swift 6.3.3, swift-format 6.3.0,
macOS/iOS/tvOS SDK 26.5. Пакет не содержит внешних зависимостей; verifier
не вызывает resolve и не требует Package.resolved/Flux. Единственная
зависимость consumer — локальный путь на Trellis.

## Не засчитывается этим отчётом

API baseline — C04. Полный hosted CI — C27. Устройства — C20.
Node/layout/render-конвейер — следующие карточки; текущие LayerRegistryTests
не выдаются за будущие end-to-end LayerTreeTests C17.
