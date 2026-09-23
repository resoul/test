# R06 §6.1 — Native performance baseline

Собрано `Playground/Shared/PerfRecorder.swift`/`PerfHarness.swift`'s
`app-text-list-<N>` fixture — attach-to-ready + resize-to-commit на реальном
`TrellisHostView` внутри настоящего запущенного приложения (не `Bench`'s
голый `CALayer`). Команда (одинаковая форма на всех трёх платформах, iOS
показана):

```bash
xcrun simctl launch --console-pty <device> org.trellis.playground.ios \
  --perf-run --perf-scenario text-list --perf-count 1000 --perf-seed 7 \
  --perf-viewport 402x874 --perf-repeats 20 --perf-warmup 3 \
  --perf-output <path>.json --perf-revision <git-sha>
```

macOS — тот же бинарник напрямую: `Playground-macOS.app/Contents/MacOS/
Playground-macOS --perf-run …`.

## Результаты (revision `d77ce64`, 1000 строк, чистый изолированный прогон)

Первый прогон (в конце сессии с параллельными Xcode-сборками) дал таймауты
на tvOS/macOS; ниже — повторный прогон без параллельной нагрузки на машине,
все три платформы завершили все 20 повторов без единого таймаута.

| Платформа | Устройство | attach-to-ready (мс) | resize-to-commit p50 (мс) | resize-to-commit p95 (мс) | resize-to-commit p99 (мс) | Таймауты |
|---|---|---|---|---|---|---|
| iOS | iPhone 17 Pro Simulator | 11.31 | 968.67 | 1280.93 | 1306.53 | 0/20 |
| tvOS | Apple TV 4K Simulator | 10.44 | 894.42 | 906.02 | 907.24 | 0/20 |
| macOS | хостовый Mac напрямую | 1.26 | 904.67 | 970.20 | 1019.35 | 0/20 |

Полные JSON: [baseline-ios-1000rows.json](baseline-ios-1000rows.json),
[baseline-tvos-1000rows.json](baseline-tvos-1000rows.json),
[baseline-macos-1000rows.json](baseline-macos-1000rows.json).

Все три платформы сходятся в одном порядке величины (p50 ≈ 900–970ms на
1000 строк реального `TextNode` с полным resize→relayout→re-raster) —
ожидаемо, поскольку все три гоняют один и тот же Swift-код на одном и том же
хостовом Mac (Simulator для iOS/tvOS, нативный запуск для macOS); это
согласованность самого измерения, не доказательство одинаковой
производительности на реальных iPhone/Apple TV.

## Честные ограничения (не «пройдено» сверх этого)

- **Симулятор — не устройство.** `deviceModel` во всех трёх отчётах —
  `Mac14,2` (хостовый Mac), не iPhone/Apple TV — ожидаемо и задокументировано
  в `PerfRecorder.swift`. Абсолютные числа выше привязаны к этому конкретному
  хосту; ни одно из них не может быть числовым бюджетом R15 без повторения
  на физическом устройстве.
- Один fixture (`app-text-list`), один размер (1000 строк), один seed. Нет
  варьирования viewport/wide/grid, нет варьирования под memory pressure, нет
  Instruments trace для hitch/frame-drop — implementation-plan-6.md §6.1
  требует это отдельно, здесь не покрыто.
- Измерен только сквозной request-to-commit; R15 должен разложить это на
  фазы (snapshot/solve/apply/raster), не только итоговое число.
- Peak/resident memory собраны (`peak-resident-mib` в JSON), не
  проанализированы отдельно.
- Первый (загруженный параллельными сборками) прогон намеренно не удалён из
  истории — см. предыдущую версию этого файла в git — как пример того,
  почему изоляция машины важна для воспроизводимости этого протокола; сам
  факт, что тот прогон таймаутил именно на границе харнесса (2000мс), а не
  случайным числом, был первым сигналом, что дело в нагрузке хоста, а не в
  архитектуре.

## Что это доказывает (и только это)

Сквозной pipeline `PerfLaunchConfiguration` → `PerfRecorder`/`PerfHarness` →
JSON+CSV работает end-to-end на всех трёх платформах через настоящий
`TrellisHostView` в настоящем запущенном приложении, с реальными,
воспроизводимыми (одинаковый seed → одинаковый контент), непротиворечивыми
числами при изолированном прогоне. R15 должен повторить тот же протокол на
физических устройствах, с несколькими fixture и разбивкой по фазам, прежде
чем сравнивать с числовым бюджетом.
