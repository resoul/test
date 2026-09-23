# C19 — Playground и scenarios

## Состав

`Playground/Playground.xcodeproj` содержит `Playground-iOS`, `Playground-tvOS` и
`Playground-macOS`. Каждый target подключает локальный пакет `..`: UIKit targets
используют `TrellisUIKit`, macOS — `TrellisAppKit`. Общие файлы находятся в
`Playground/Shared`, а `Shared/Scenarios/S01_…S15_…` содержит по одному сценарию
на файл.

`Scenario.current` выбирает имя сценария, а `Scenario.mode` переключает
`fixedInput` (canvas 320×640) и `nativeBounds`. Ожидания задаются через
стабильные semantic paths и правила геометрии в `ScenarioSpecification`; NodeID
между запусками не сравниваются.

S15 создаёт чистое дерево отдельно от `ScenarioSession`. Session — единственный
владелец periodic `Task`; iOS отменяет его при `sceneDidDisconnect`, tvOS при
завершении приложения, macOS при закрытии окна. Поэтому detached root не
получает дальнейших мутаций.

## Проверка 2026-09-10

```sh
xcodebuild -project Playground/Playground.xcodeproj -scheme Playground-macOS \
  -sdk macosx -derivedDataPath .build/c19-macos \
  -clonedSourcePackagesDirPath .build/c19-packages CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Playground/Playground.xcodeproj -scheme Playground-iOS \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build/c19-ios \
  -clonedSourcePackagesDirPath .build/c19-packages CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Playground/Playground.xcodeproj -scheme Playground-tvOS \
  -sdk appletvos -destination 'generic/platform=tvOS' -derivedDataPath .build/c19-tvos \
  -clonedSourcePackagesDirPath .build/c19-packages CODE_SIGNING_ALLOWED=NO build
python3 Scripts/check_policy.py
```

Все три сборки и policy check прошли. На физических устройствах сценарии ещё
не запускались: это намеренно входит в C20.
