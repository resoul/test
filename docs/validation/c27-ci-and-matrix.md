# C27 — CI и итоговая матрица

Дата: 2026-09-11. Устройство: тот же Mac, что в C20/C26 (Apple Silicon), Xcode 26.6
(17F113), SDK 26.5 — совпадает с `toolchain.json` и с пином в `quality.yml`.
**Удалённого git remote в репозитории нет** — ниже задокументирован реальный локальный
прогон той же команды, которую выполняет CI; фактического хостед-прогона GitHub Actions
не было и не могло быть до появления remote. Это открытый пункт, не потерянный.

## Что сделано

1. **`Scripts/verify_bootstrap.py --matrix`** переработан: раньше все пять destinations
   (macOS universal, iOS/tvOS device и simulator) только собирались (`build`) на
   `generic/platform=...` — общий destination, на котором ничего не может *выполниться*.
   Теперь:
   - `macos-universal`, `ios-device`, `tvos-device` остаются build-only — в CI нет
     подключённого устройства, для них это предел возможного.
   - `ios-simulator`/`tvos-simulator` резолвят конкретный доступный симулятор нужной SDK
     через `xcrun simctl list devices available --json` (новая `find_simulator_udid`) и
     реально **запускают** (`xcodebuild test`, не `build`) весь набор тестов
     `Trellis-Package` на этом симуляторе.
2. **`Tests/TrellisRenderTests/AppKitHostViewTests.swift`** обёрнут в
   `#if canImport(AppKit)` (тот же приём, что уже применялся в Sources для F02) — это
   единственный файл в `TrellisRenderTests`, который не собирался вне macOS. Без этой
   правки `xcodebuild test` для iOS/tvOS падал на этапе сборки, не доходя до запуска.
3. **`.github/workflows/quality.yml`** переключён на `check_all.py --matrix
   --skip-screenshots`; таймаут 45 → 60 минут (полный матричный прогон медленнее, чем
   голый `check_all.py`). Скриншот-сравнение остаётся локальным — см. «Что осталось
   открытым».

## Проверка: можно ли реально гонять тесты на симуляторах

Да. Подтверждено вручную до правки скрипта:

```bash
xcodebuild test -scheme Trellis-Package \
  -destination 'platform=iOS Simulator,id=<iPhone 17, iOS 26.5>'
```

даёт `TrellisCoreTests` (262 теста) и `TrellisRenderTests` (58 тестов после guard'а
AppKit-файла) — оба выполняются по-настоящему на рантайме симулятора, не только
собираются. То же самое подтверждено на `tvOS Simulator`. `TrellisRenderTests` до этой
карточки не мог собраться вне macOS вообще (`import AppKit` без guard) — это не было
известно как ограничение раньше, просто никто не пытался запустить именно `test`, а не
`build`, на этом destination.

## Дефект, найденный полным прогоном на симуляторе

Первый же прогон всего набора (320 тестов) на iOS Simulator упал —
`test_debugOverlay_shownLabelsNeverOverlapNorLeaveTheCanvas` (2 параметра scale) не
проходил, хотя в изоляции (`-only-testing`) проходил стабильно 3/3. Записано в
[defects.md #29](../defects.md): тест использовал `.runtimeID`-подписи и жёстко
закладывал точные счётчики (`shown.count == 9`, `"12×60"`-фильтр `== 8`), которые зависят
от количества цифр в `NodeID` — единый монотонный счётчик на весь процесс. После ~300
предыдущих тестов ID стали 3–4-значными, одна подпись перестала помещаться в
плотно упакованный canvas 200×80. `swift test` на macOS не ловил это раньше по чистой
случайности порядка/количества тестов в своём процессе, не потому что там иначе.
Исправлено переключением на уже существующий (со времён дефекта #11) стиль
`.treeOrder` — подписи `n1`..`n9` фиксированной короткой длины, независимые от глобального
счётчика. После исправления полный `check_all.py --matrix --skip-screenshots` зелёный.

## Приёмка C27 из плана

| Пункт | Статус |
|---|---|
| Mac build/test/policy/API/consumer в CI | Есть (`check_all.py`, было и раньше); подтверждено локально, exit 0 |
| Device/simulator сборки доступных платформ | Device — build-only (нет hardware). Simulator — реальный `test`-прогон (не только build), iOS и tvOS |
| macOS arm64/x86_64 по исходному scope | `ARCHS=arm64 x86_64` в `macos-universal`, без изменений с C02 |
| Разделение API baseline и SDK paths, без авто-принятия нового baseline | Уже было (`check_api.py`: per-module SDK, `--update` требует `--review-note`) — не менялось в C27 |
| Сборка без внешнего dependency resolution | Уже было (`-disableAutomaticPackageResolution`, нет `Package.resolved`) |
| Не заявлять, что CI заменяет физические проверки | Явный комментарий в `quality.yml`; этот отчёт также не претендует на это |
| Повторить физические сценарии перед закрытием M6 | **Не выполнено** — нет физического iOS/iPad/tvOS доступа (см. C20); остаётся открытым до появления устройства |

## Что осталось открытым

- **Нет git remote** — workflow не выполнялся на реальном hosted-раннере GitHub Actions,
  только эквивалентная команда локально с тем же пином Xcode. Как только появится
  remote, первый реальный прогон CI нужно свериться с этим отчётом (тот же exit code,
  то же число тестов) — расхождение будет находкой, а не нормой.
- **Скриншоты** — `check_screenshots.py` (macOS) намеренно не включён в CI ни здесь, ни
  раньше; параллельно вне этой карточки идёт реорганизация
  `docs/validation/screenshots/` (macOS/iOS/iPadOS/tvOS подпапки) — решение о хостед
  сравнении скриншотов откладывается до её завершения, чтобы не конфликтовать.
- **Физическая матрица** — как и в C20/C26, статус iOS/iPad/tvOS «нет доступа»; C27 не
  меняет это состояние, только явно documents это как незакрытый критерий приёмки, а не
  тихо игнорирует.
