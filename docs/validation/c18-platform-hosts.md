# C18 — UIKit/AppKit host views

Дата: 2026-09-10.

Обе платформенные view стали тонкими источниками state для `NodeHostBridge`:
они не владеют layer mapping и не выполняют layout/render сами.

## Контракт

- `attach(root:)` создаёт bridge и передаёт initial bounds, scale, safe area и
  direction одним вызовом; safe area преобразуется из физических left/right в
  logical leading/trailing.
- UIKit обновляет state через layout, safe-area и trait events; scene lifecycle
  observers привязаны к конкретному `UIScene`.
- AppKit обновляет state через layout/backing changes; host layer-backed и
  flipped; lifecycle observers привязаны к конкретному `NSWindow`.
- `detach` и deinit удаляют observers и отменяют bridge work. Одно окно/scene
  не получает notification другого из-за object-filtered registration.
- Старый public `layerRegistry` удалён: настоящий registry принадлежит
  `LayerRenderer`, см. [ADR 0005](../adr/0005-c18-host-bridge-api.md).

## Автоматическая приёмка

- `AppKitHostViewTests` создаёт реальный `NSView`, подтверждает `wantsLayer`,
  `isFlipped` и асимметричные дочерние `CALayer` с возрастающей Y координатой.
- Generic iOS device и tvOS device `xcodebuild` компилируют UIKit branch с
  warnings-as-errors; generic matrix также включает macOS и оба simulator SDK.

Физический smoke test не выполнялся: это отдельная C20-приёмка, а не замена
generic builds или macOS test.

## Проверки

| Команда | Результат |
|---|---|
| `swift test --filter TrellisHostViewTests` | PASS, AppKit host test |
| `xcodebuild … generic/platform=iOS … build` | PASS |
| `xcodebuild … generic/platform=tvOS … build` | PASS |
| `python3 Scripts/check_all.py --matrix` | PASS: macOS universal, iOS device/simulator, tvOS device/simulator, tests, consumer, API |
| `python3 Scripts/check_api.py --module TrellisUIKit/TrellisAppKit --update --review-note docs/adr/0005-c18-host-bridge-api.md` | UPDATED: remove `layerRegistry`, add attach/detach and platform lifecycle overrides |
