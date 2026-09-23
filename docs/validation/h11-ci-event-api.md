# H11 — Event API в CI-матрице

Дата: 2026-09-11. Финальная карточка
[implementation-plan-2.md](../implementation-plan-2.md) §5. Зависимости
H09–H10 и C27 закрыты.

## Внешний consumer

`Scripts/verify_bootstrap.py` по-прежнему создаёт отдельный временный SwiftPM
consumer без `@testable`. Его smoke-сценарий расширен публичной event-цепочкой:

1. внешний `EventControl: ControlNode` переопределяет `handleEvent`;
2. consumer создаёт `LayoutResult` и применяет committed frames;
3. публичный `HitTestSnapshot` фиксирует mount epoch и геометрию;
4. `PointerSessions` получает down/up через `PointerData`;
5. проверяются две доставки, одна activation, сброшенный `isPressed` и
   `activeCount == 0`.

Это compile- и runtime-проверка публичного API из модулей `TrellisCore`,
`TrellisRender` и `TrellisAppKit`; внутренних hooks consumer не видит.

## Полная матрица

Команда:

```bash
TRELLIS_LOG=off python3 Scripts/check_all.py --matrix
```

| Destination | Режим | Результат |
|---|---|---|
| macOS generic, `ARCHS=arm64 x86_64` | build | pass |
| iOS generic | device build-only, без code signing | pass |
| tvOS generic | device build-only, без code signing | pass |
| iPhone 17 Pro, iOS 26.5 Simulator | реальный `xcodebuild test` | pass — 330 Core + 70 Render tests |
| Apple TV 4K (3rd generation), tvOS 26.5 Simulator | реальный `xcodebuild test` | pass — 330 Core + 70 Render tests |
| macOS arm64 host | `swift test` | pass — 406 tests |

На simulator выполняется весь применимый `Trellis-Package`: AppKit-only тесты
закрыты `canImport(AppKit)` и потому закономерно остаются только в macOS-наборе.
Generic iOS/tvOS destinations — именно build-only; наличие строки `pass` не
выдаётся за запуск на физическом устройстве.

Обычный `python3 Scripts/check_all.py` также был выполнен в H10 и зелёный.
Matrix-команда повторно прошла его общую часть, затем дополнительно прошла:

- policy 2.0.0 и swift-format;
- Swift 6 strict concurrency с warnings-as-errors;
- внешний consumer;
- API baseline: TrellisCore 683, TrellisRender 91, TrellisAppKit 17,
  TrellisUIKit 18 символов; tvOS surface совпадает с iOS baseline;
- 42 macOS screenshot reference;
- `TRELLIS_LOG` в реальном subprocess.

Policy gate подтверждает отсутствие `@unchecked Sendable`,
`nonisolated(unsafe)` и `@preconcurrency`, а также отсутствие UIKit/AppKit/
CoreGraphics imports в `TrellisCore`. Публичная поверхность H10 не менялась;
package/internal arena test hook в API baseline не входит.

## Граница автоматизации ввода

`xcodebuild test` на iOS/tvOS Simulator запускает unit/integration suites, но
не синтезирует настоящий `UITouch`/Siri Remote input. XCUITest target и
автоматический tap намеренно не добавлены в этой части. End-to-end touch
evidence — ручной iPhone 17 Pro Simulator прогон H09; tvOS-интерактивность
остаётся вне этапа по D24. Build-only, simulator unit tests и ручной ввод в
отчётах не смешиваются.

## Приёмка карточки — итог

| Критерий | Статус |
|---|---|
| Новые тесты встроены в существующую C27-матрицу | done; инфраструктура не дублировалась |
| macOS + iOS/tvOS Simulator tests | done |
| Generic iOS/tvOS и universal macOS builds | done |
| API baseline и Swift 6 isolation | done |
| Внешний consumer нового event API | done |
| XCUITest-тап явно отделён и не заявлен | done |
