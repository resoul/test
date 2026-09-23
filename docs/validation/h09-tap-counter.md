# H09 — Интерактивный вертикальный сценарий

Дата: 2026-09-11. Карточка D-группы [implementation-plan-2.md](../implementation-plan-2.md)
§5. Зависимости H07 (iOS), H08 (macOS) закрыты. Новая сцена
`Playground/Shared/Scenarios/S21_TapCounter.swift` — единственная сцена, которая доказывает
snapshot → hit-test → dispatch → арбитр → control end-to-end, не только рендер.

## Сцена

Три `TapCardNode: ControlNode` в вертикальном списке (root — `Column`, `gap = 16`, как
остальные сцены). Без текста (N01 вне рамок этапа) — три сигнала выражены цветом/формой:

| Сигнал | Что показывает | Как реализован |
|---|---|---|
| Фон карточки (live) | `isPressed`: idle-цвет вверх, акцент вниз-и-внутри | `TapCardNode` переопределяет `handleEvent`/`handleBubble` (стали `open` — [ADR 0012](../adr/0012-controlnode-hooks-become-open.md)), вызывает `super`, затем красит `appearance.background` по текущему `isPressed` |
| Индикатор исхода (маленький квадрат) | последний исход: серый — не трогали; **amber** — отпущено без активации (снаружи, cancel, проигранный арбитраж); **green** — активировано | Ставится **предположительно** amber на каждый `pointerUp`/`pointerCancel` в `respond(to:)`, затем **тем же синхронным тактом** (D29 (1): capture→target→bubble→arena — всё до возврата из колбэка, породившего событие) `activated()` перезаписывает на green, если Tap выиграл арбитраж и точка внутри по **последнему** снимку (D22/D34) |
| Бар счётчика | число активаций, до 6 делений по 12pt | `counterFill.style.width` растёт в `activated()`; без cornerRadius — см. дефект ниже |

Вторая карточка держит `decorativeIcon` — декоративный ребёнок без своего recognizer (H01 §5
(7)): тап по нему всё равно долетает как `handleBubble` до карточки, активация — карточки, не
иконки.

## Дефект, найденный при первом рендере

Первый вариант `counterFill` имел `cornerRadius: 4`; при `tapCount == 0` (`width == 0`)
CALayer рисовал не пустой прямоугольник, а видимую «бабочку» — левая и правая дуги скругления
пересекались на нулевой ширине вместо того, чтобы дать пустую область. Не дефект существующего
`LayerRenderer`/Trellis — это свойство `CALayer.cornerRadius` (не клампится к половине ширины
автоматически), проявившееся из-за выбора автора сцены дать радиус элементу, чья ширина может
быть нулевой; в реестр `docs/defects.md` не заносится (это ошибка нового consumer-кода
карточки H09, не существующего кода Trellis). Исправлено удалением `cornerRadius` у
`counterFill` — плоский прямоугольник не имеет вырожденного случая и всё равно сидит внутри
скруглённого трека.

## API baseline: `ControlNode.handleEvent`/`handleBubble` → `open`

`TapCardNode` должен переопределять оба хука поверх `ControlNode`'а трекинга нажатия — они
были `public override func`, что запрещает переопределение вне модуля `TrellisCore`.
Расширены до `open override func` — [ADR 0012](../adr/0012-controlnode-hooks-become-open.md);
`changed` в baseline (меняется `accessLevel`, не мангл-имя), не breaking (`open` расширяет
доступ). `python3 Scripts/check_api.py --tvos --update --review-note <ADR>` — применено.

## Xcode-проект

`Playground/Playground.xcodeproj/project.pbxproj` — новая `PBXFileReference`/`PBXBuildFile`
для `S21_TapCounter.swift`, добавлена в `Sources`-группу и во все три
`PBXSourcesBuildPhase` (iOS/tvOS/macOS) тем же паттерном, что уже использован для S01–S20
(последовательные hex-id, без Xcode GUI).

## Скриншоты (эталон)

`python3 Scripts/check_screenshots.py --update --review-note <этот файл>` — добавлены
`S21_TapCounter.png`/`_overlay.png` (42 эталона вместо 40, остальные 40 байт-в-байт не
изменились). Идле-состояние: три карточки, серый индикатор, пустой счётчик, фиолетовая
декоративная иконка на второй карточке.

## Сборка на всех платформах

| Платформа | Проверка | Результат |
|---|---|---|
| macOS | `xcodebuild -scheme Playground-macOS build` | зелёно |
| iOS Simulator | `xcodebuild -scheme Playground-iOS -sdk iphonesimulator build` | зелёно, бандл `org.trellis.playground.ios` |
| tvOS Simulator | `xcodebuild -scheme Playground-tvOS -sdk appletvsimulator build` | зелёно — D24: сцена собирается и рендерится, интерактивность не проверяется (Siri Remote — фокус-движок, которого нет) |

## Ручная проверка на iOS Simulator

Приёмка H09 требует «видимое нажатие меняет состояние карточки на реальном touch/mouse
вводе». 2026-09-11 пользователь запустил `S21_TapCounter` на iPhone 17 Pro Simulator и
выполнил тапы. Evidence: `screenshots/S21_TapCounter_iPhone17Pro_progress.png`.

На скриншоте после завершённых жестов у всех трёх карточек зелёный индикатор исхода, а
cyan-бары имеют ненулевую длину (первая достигла визуального cap). Это подтверждает, что
успешный touch прошёл полный путь snapshot → hit-test → dispatch → arena → `ControlNode`
activation и что control/recognizer остаются работоспособны при повторных сессиях. Снимок
сделан после отпускания, поэтому live pressed-фон ожидаемо вернулся к idle-цвету.

Скриншот не доказывает отдельные случаи release-outside/cancel (amber) и точное место тапа
на decorative icon; это не требуется приёмкой H09 и остаётся покрытым unit/integration
тестами H01–H08. tvOS-интерактивность по D24 не проверяется.

## Приёмка карточки — итог

| Пункт | Статус |
|---|---|
| Сцена с тапаемыми карточками, pressed-состояние, счётчик | done |
| Видимая подпись «последнее состояние», переживающая release | done (индикатор + бар) |
| tvOS собирается и рендерится, интерактивность не проверяется | done |
| Скриншоты рядом с существующими | done (42 эталона) |
| Видимое нажатие на реальном touch — iOS | done — ручной ввод на iPhone 17 Pro Simulator, evidence-скриншот сохранён |
| Видимое нажатие на реальном mouse — macOS | покрыто автотестом (`AppKitPointerInputTests`, H08); отдельного ручного клика по GUI не производилось (нет доступного инструмента управления нативным macOS UI в этой сессии) |
