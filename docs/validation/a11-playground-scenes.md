# A11 — Вертикальные Playground-сценарии и device evidence

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5.
Зависимости A05, A08–A10 закрыты. Simulator, native automated run и физическое
устройство ниже отмечены раздельно; отсутствие доступа названо отсутствием доступа.

## Сцены

| Сцена | Файл | Что показывает |
|---|---|---|
| S22_FocusGrid | `Playground/Shared/Scenarios/S22_FocusGrid.swift` | `FocusCardNode: ControlNode` — сетка 3×3: видимый focus ring (`isFocused` → border), pressed-фон (`isPressed`), счётчик activations (бар), карточка 5 disabled, карточка 7 «Remove me» удаляет себя при activation (fallback focus по A04 §3.1), карточка 9 «Open dialog» открывает modal с Cancel/Confirm и `setFocusScope` (закрытие — восстановление). Начальный focus запрашивается после первого publish (retry на MainActor), поэтому ring виден на reference-скриншоте без ввода. |
| S23_Semantics | `Playground/Shared/Scenarios/S23_Semantics.swift` | labelled `.contain` группа «Profile» (header «Ada Lovelace», text «Mathematician», button «Follow» с hint и custom action «Share profile»); `.combine` строка → один элемент «Weather, 21 degrees»; `.ignoreSelf` строка с кнопками Like/Comment и `.hide` декорацией; `SelectableCardNode` (isSelected по activation); `VolumeCardNode` (`.adjustable`, value 0…10, increment/decrement через `onAccessibilityAction`). Все labels — строки metadata, `TextNode` не нужен. |

Инфраструктура: `Scenario.initialIndex` (`--scene <name>`), `Scenario.dumpsAccessibility`
(`--dump-accessibility` печатает **native** дерево через `accessibilityElements`/
`accessibilityChildren()` — то, что перечисляет VoiceOver), `AccessibilityDump.swift`;
macOS `--drive-focus <dir>` — сценарий реальных `NSEvent` через `TrellisHostView.keyDown/keyUp`
со скриншотом после каждого шага. Playground-tvOS: стрелки и Select отданы host (D44),
Play/Pause переключает сцены, Menu не перехватывается. Reference-скриншоты
`docs/validation/screenshots/macOS/S22_*`, `S23_*` добавлены этим отчётом (review note
для `check_screenshots.py --update`).

## Evidence

### macOS 26.5 (Apple Silicon), native automated run — `Playground-macOS --drive-focus`

`NSEvent.keyEvent` → `TrellisHostView.keyDown/keyUp` — тот же путь, что у физической
клавиатуры ниже responder chain; не физический ввод. Лог `A11DRIVE` (focused/scope после
каждого шага) и 17 скриншотов; четыре ключевых — в `docs/validation/a11-macos-*.png`:

| Шаг | Ожидание | Факт |
|---|---|---|
| initial | ring на Card 1 | `focused=#5` |
| Tab ×3 | Card 2 → 3 → 4 | `#9`, `#13`, `#17` |
| Tab | Card 5 disabled пропущена → Card 6 | `#25` ([скриншот](a11-macos-05-tab-skips-disabled.png)) |
| Return ×2 | счётчик Card 6 = 2, focus не меняется | `#25`, бар 2 шага |
| Shift-Tab | назад к Card 4 | `#17` |
| ↓ | Card 7 (геометрия) | `#29` |
| Return на «Remove me» | карточка удалена, focus на следующей (Card 8) | `#33` ([скриншот](a11-macos-10-remove-fallback.png)) |
| → | Card 9 | `#37` |
| Return на «Open dialog» | dialog, scope = dialog, focus Cancel | `focused=#54 scope=#50` ([скриншот](a11-macos-12-dialog-scope.png)) |
| Tab, Tab | Cancel → Confirm → Cancel (wrap внутри modal) | `#58`, `#54` |
| Return на Cancel | dialog закрыт, focus восстановлен на Card 9 | `focused=#37 scope=nil` ([скриншот](a11-macos-15-dialog-closed-restored.png)) |
| ← | Card 8 | `#33` |

Native accessibility tree S23 через `accessibilityChildren()` (`A11DUMP`, тот же запуск):

```
AXGroup Profile (591,680,288,112)
  AXStaticText Ada Lovelace · AXStaticText Mathematician · AXButton Follow
AXStaticText "Weather, 21 degrees"          ← .combine: один элемент
AXGroup (без label)                          ← .ignoreSelf: контейнер без endpoint
  AXButton Like · AXButton Comment           ← декорация .hide отсутствует
AXButton Notifications
AXSlider Volume value=4
```

### iOS 26.5 Simulator (iPhone 17 Pro) — реальный `UITouch` через Simulator input

Запуск `--scene S22_FocusGrid`; tap по Card 6, по «Open dialog», по Cancel в диалоге
(лог `TRELLIS_LOG=focus,event`):

```
[trellis.focus] changed #5 previous=nil reason=request            ← начальный focus Card 1
[trellis.event] activated #25 source=pointer                       ← tap Card 6, счётчик +1
[trellis.event] activated #37 source=pointer                       ← tap Open dialog
[trellis.focus] changed #54 previous=#5 reason=scope               ← scope открыт, focus Cancel
[trellis.event] activated #54 source=pointer                       ← tap Cancel
[trellis.focus] changed #5 previous=#54 reason=restoration         ← focus вернулся на Card 1
```

Tap не переносит keyboard focus (D45): ring остался на Card 1 до открытия диалога.
Скриншот после Cancel — [a11-ios-s22-after-cancel.png](a11-ios-s22-after-cancel.png).
S23 `--dump-accessibility` (native `accessibilityElements` UIKit): группа Profile
(`element=false`) с header (traits 65536), staticText (64), button (1); «Weather, 21 degrees»
один элемент; группа без label с Like/Comment; Notifications button; Volume adjustable (4096)
value=4 — [a11-ios-s23.png](a11-ios-s23.png). iPad + клавиатура: не проверено вручную
(нет автоматизации клавиатурного ввода в Simulator без прав accessibility); путь
`pressesBegan` → engine доказан unit-тестами A08 на iOS Simulator.

### tvOS 26.5 Simulator (Apple TV 4K 3rd gen) — Playground-tvOS `--scene S22_FocusGrid`

Лог `TRELLIS_LOG=focus`:

```
[trellis.focus] changed #5 previous=nil reason=request     ← engine запросил Card 1
[trellis.focus] native-focus #5 confirmed=true              ← система сфокусировала proxy #5 (D44)
```

Системный focus engine tvOS принял `preferredFocusEnvironments` host и подтвердил
переход через `didUpdateFocus` proxy — один источник focus работает на реальном пути
приложения, ring виден: [a11-tvos-s22-native-focus.png](a11-tvos-s22-native-focus.png).
Native AX dump: 9 элементов с labels, «Disabled card» traits 257 (button + notEnabled).
Стрелки Siri Remote и Select: **не проверено** — Simulator не принимает touch на tvOS,
AppleScript-клавиши требуют прав Accessibility для терминала (не выданы); физический
Apple TV — **нет доступа**.

### VoiceOver

Не запускался ни на одной платформе: голосовое чтение не автоматизируется из этой
сессии. Native деревья выше — то, что VoiceOver перечисляет, но spoken label и cursor не
подтверждены. Ручной протокол:

| Платформа | Шаги | Ожидание |
|---|---|---|
| iPhone/iPad, VoiceOver | S23: свайп вправо по элементам; двойной тап на Follow; rotor Actions → Share profile; на Volume свайп вверх/вниз; на Notifications двойной тап | «Profile, group» → «Ada Lovelace, heading» → «Mathematician» → «Follow, button, Follows Ada» → «Weather, 21 degrees» → «Like, button» → «Comment, button» (без «Decoration», без «Ignored row») → «Notifications, button» → «Volume, 4, adjustable»; Share возвращает успех; Volume 5/3; Notifications «selected» |
| iPad + клавиатура | S22: Tab/Shift-Tab, стрелки, Return/Space | как macOS-таблица выше |
| Apple TV + Siri Remote | S22: свайпы, Select на Card 6, на «Remove me», на «Open dialog», Cancel; выход стрелкой к системному элементу и обратно | ring следует системному focus; Select — счётчик +1 ровно один; удаление переносит focus на соседа; диалог ограничивает focus, Cancel восстанавливает; Menu не перехвачен |
| Apple TV + VoiceOver | S23 как iPhone | то же чтение |
| Mac + VoiceOver | S23: VO-→ по элементам, VO-Space на Follow, VO-Cmd-Space → Share profile, на Volume VO-↑/↓ | роли AXGroup/AXStaticText/AXButton/AXSlider как в `A11DUMP`; press/custom/increment/decrement срабатывают |

## Приёмка A11 — итог

| Критерий | Статус |
|---|---|
| Сцена controls: focus ring, счётчик, disabled, удаление текущей, modal | done — macOS automated run (все шаги), iOS real touch (activation/scope/restore), tvOS native focus confirmation |
| Семантическая сцена: label/value/hint, четыре политики, selectable, adjustable | done — native деревья macOS/iOS/tvOS через platform API |
| Реальные шаги keyboard/remote/VoiceOver с версиями ОС | частично: macOS — automated NSEvent, не физическая клавиатура; iPhone — реальный touch; tvOS remote, iPad клавиатура, VoiceOver везде — **не проверено**, протокол выше |
| iPhone/iPad VoiceOver, Apple TV + Siri Remote/VoiceOver, Mac + VoiceOver | **открыто** — ручная проверка; физические устройства — нет доступа |
