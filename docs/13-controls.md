# Компоненты: Control, поля ввода, клавиатура, rich text

**Статус: проект, 2026-09-28.** Решения ниже — рекомендации; вопросы в конце ждут ответа
пользователя. Кода нет.

## Зачем

Сейчас в `NodesRender` есть `Text` (строка одного стиля), `Button`, `Image`, `Table`,
`RefreshSpinner`. Пользователь просит: общий `Control`, от которого пойдут остальные;
`TextField`, `EmailField`; отличную работу с клавиатурой; rich text «как в Telegram»;
`Checkbox`, `Switch`, `Select` (выпадающее меню), `Toast`; ранее — `Tooltip`.

Источники идей: старый проект Weave (`ControlNode`, `ButtonNode`, `TextFieldNode` через мост
к `UITextField`), Telegram iOS (`docs/richtext-composer.md`, `RichTextEditor`, `Display`
— клавиатура, `SwitchNode`, `CheckNode`, `UndoUI`, `TooltipUI`).

## Что взято из Telegram и что нет

- **Модель содержимого — значение, а не `NSAttributedString`.** В Telegram `ChatInputContent`
  — дерево блоков и отрезков текста (`paragraph`/`quote`/`code`/…, отрезки bold/italic/mono/
  strike/underline/spoiler + ссылка/упоминание/эмодзи), с которым работают отправка,
  черновики, правка. Мы делаем так же: `RichText` — `Sendable`-значение в модуле без UIKit,
  проверяемое `swift test` на Linux. `NSAttributedString` — только на границе адаптера.
- **Ядро редактора без UIKit**, TextKit — за протоколом (у них `BlockLayoutEngine`: TextKit 2
  на iOS 16+, TextKit 1 ниже). У нас минимум iOS 16 — только TextKit 2 (`NSTextLayoutManager`).
- **Меню «Формат»** в системном меню правки (`UIEditMenuInteraction`, iOS 16+): Bold, Italic,
  Monospace, Link, Strikethrough, Underline, Quote, Spoiler.
- **Родитель задаёт размер и отступы**, поле возвращает высоту (`update(size:insets:) ->
  height`) — у нас это и так: нода измеряется раскладкой.
- **Клавиатура — на уровне окна**, высота клавиатуры приходит вниз как часть условий показа
  (`inputHeight`) с кривой анимации клавиатуры. У нас — через `NodeHost` (ниже).
- **Не берём:** собственную подмену вида клавиатуры и перетаскивание системной клавиатуры
  через приватные виды (`KeyboardManager`, `WindowPanRecognizer`) — это частные API и
  хрупкость между версиями iOS. Своя клавиатура-панель (эмодзи) — через публичный
  `inputView`, как у них для редактора.

## Control

Общий класс для нод, с которыми взаимодействуют. Сейчас это делает `Button` вручную
(`onTap`, `pressChanged`, `focusChanged`).

```swift
open class Control: Node {
    var isEnabled: Bool            // выключенный: не фокусируется, не нажимается, тусклее
    private(set) var state: ControlState   // [.pressed, .focused, .hovered, .disabled, .selected]
    open func stateChanged(from: ControlState)   // подкласс перерисовывает
    var toolTip: String?           // подсказка (Mac, iPad с курсором)
    var command: Command?          // нажатие = команда; включённость и подсказка — от неё
}
```

- Состояние — множество флагов, а не одна фаза (Weave: `idle/pressed/focused/disabled`):
  нажатая кнопка может быть в фокусе.
- `hovered` — курсор Mac и iPad (`UIHoverGestureRecognizer`), новое для адаптеров.
- Доступность: признак, значение, подсказка — от подкласса (`accessibilityValue` у Switch —
  «вкл/выкл»); выключенный — `notEnabled`.
- Клавиатура: Space и Return нажимают контрол в фокусе (Mac, iPad), Select — на TV (есть).
- `Button` становится подклассом `Control`, его API не меняется.
- Значение: у контролов со значением (`Checkbox`, `Switch`, `Select`, поля) — свойство
  значения на `State` (наблюдаемо) и `onChange`; привязки «два пути» нет — приложение
  само пишет в свою модель в `onChange` (как сейчас `Table.onSelect`).

## Поля ввода

### Способ: системное поле внутри дерева или своё

| | Системное (`UITextField`/`UITextView`/`NSTextField`) | Своё (`UITextInput`/`NSTextInputClient` на ноде) |
|---|---|---|
| Ввод на всех языках (IME, marked text), диктовка, автокоррекция, подсказки клавиатуры | даром | реализовать самим (Telegram — тысячи строк) |
| Автозаполнение паролей и email (`textContentType`), «Вставить из»... | даром, проверено | частично; пароли надёжно только у `UITextField` |
| Лупа, ручки выделения, меню правки | даром | самим (у Telegram отдельные разделы с «инвариантами») |
| Вид по теме, раскладка, прокрутка вместе с деревом | мост: вид поверх ноды | естественно |
| TV (полноэкранная системная клавиатура) | даром | самим |
| Rich text | `UITextView` + атрибуты — «наследная» ветка Telegram | их новый движок |

**Рекомендация.** `TextField`, `EmailField`, `SecureField`, `TextEditor` (многострочный) —
системные виды, которые нода держит и ставит в свою рамку («вложенный вид платформы»). Это
первый шаг, и он нужен в любом случае: так же потом вставляются карта, видео, веб-вид.
Rich text редактор — второй шаг, на `UITextView`/`NSTextView` с TextKit 2 и нашей моделью
`RichText` (атрибуты — только на границе). Свой движок ввода — только если упрёмся.

### Вложенный вид платформы (новое в Nodes и адаптерах)

```swift
final class HostedView: Node          // ядро не знает UIKit: держит непрозрачный ключ
// адаптер: NodeView кладёт UIView ноды своим subview в рамку ноды после раскладки,
// сдвигает при прокрутке, прячет при isShown == false, порядок — по порядку дерева
```

- Размер: нода спрашивает вид о желательном размере (`sizeThatFits`, `intrinsicContentSize`)
  — через обратный вызов адаптера, как текст меряется сейчас.
- Фокус: поле в фокусе — first responder; фокус дерева и клавиатурный фокус согласованы
  (Tab с Mac/iPad-клавиатуры ведёт по полям в порядке дерева; на TV — фокус движка).
- Команды: пока поле — first responder, его клавиши (⌘Z, ⌘A, стрелки) у него; команды
  приложения — через цепочку: вид поля → `NodeView` → экран.

### TextField

```swift
let name = TextField(placeholder: "Name")
name.text                 // State, наблюдаемо
name.onChange = { … }; name.onSubmit = { … }       // Return
name.returnKey = .next    // .next переводит фокус на следующее поле дерева
name.content = .name      // textContentType: имя, email, телефон, адрес, код из SMS …
name.clearButton = .whileEditing
name.maxLength = 64
```

**EmailField** — `TextField` с `content = .email`, клавиатурой email, без автокоррекции и
заглавных, и проверкой: `isValid` (наблюдаемо; простая форма `local@domain.tld`, без
претензии на RFC 5322), `validationMessage` показывается под полем после ухода из него.
Общая модель проверки — `TextField.validate: (String) -> String?` (сообщение или `nil`);
`EmailField` задаёт свою. Аналогично потом `PhoneField`, `NumberField`, `CodeField` (код из
SMS по ячейкам — у Telegram `CodeInputView`).

**SecureField** — пароль: `isSecureTextEntry`, `content = .password/.newPassword`
(предложение сильного пароля).

### Клавиатура

- **Высота клавиатуры — условие показа хоста.** Адаптер следит за
  `keyboardWillChangeFrame` (или `keyboardLayoutGuide`, iOS 15+), переводит кадр клавиатуры
  в координаты `NodeView` и отдаёт хосту `keyboardInset` вместе с длительностью и кривой.
  Раскладка перестраивается в `withAnimation` с кривой клавиатуры — поле ввода внизу экрана
  едет вместе с клавиатурой, как в Telegram. iPad с плавающей клавиатурой и Stage Manager —
  по пересечению кадра клавиатуры с окном, а не по высоте экрана (у Telegram этому посвящена
  половина обработчика).
- **Поле в фокусе остаётся видимым:** `Scroll` вокруг поля прокручивает его над клавиатурой
  (как `reveal` для фокуса сейчас), с отступом.
- **Скрытие клавиатуры:** касание вне полей (по настройке экрана), прокрутка вниз
  (`dismissesKeyboard: .onDrag` у `Scroll`), Escape на iPad. Интерактивное «тянуть вниз вместе
  с пальцем», как в Сообщениях, у системы есть только для `UIScrollView.keyboardDismissMode =
  .interactive`; наш `Scroll` — свой, поэтому интерактивное скрытие — вопрос (ниже).
- **Панель над клавиатурой** (`inputAccessoryView`): кнопки «Готово», «Назад/Далее» по полям,
  форматирование — нодами (`NodeView` как accessory).
- **Своя клавиатура** (эмодзи, стикеры): `inputView` поля — `NodeView` с деревом; переключение
  системная ↔ своя без потери first responder (как у Telegram).
- Mac: клавиатуры на экране нет; Tab/Shift-Tab — по полям, Return — `onSubmit`, Escape —
  отмена правки (`Command.cancel`).
- TV: поле в фокусе по Select открывает системный экран ввода; `EmailField` передаёт
  `content` — на TV это даёт подстановку email из настроек.

### Rich text

**Модель (`RichTextCore`, без UIKit, Linux):**

```swift
struct RichText: Sendable, Hashable, Codable {
    var blocks: [Block]              // .paragraph(runs) / .quote(runs) / .code(String, language)
                                     // / .list(ordered, items)
}
struct Run { var text: String; var marks: Marks; var link: URL?; var mention: Mention? }
struct Marks: OptionSet { bold, italic, mono, strike, underline, spoiler }
struct RichSelection { start, end: RichPosition }   // позиция: блок + смещение
```

- Правка — операциями над значением (`insert`, `delete`, `toggle(.bold, in:)`, `setLink`),
  тесты — на Linux. Отмена (`UndoManager` платформы) хранит значения.
- Конвертеры: Telegram-подобные сущности (`entities: [(range, type)]` над простым текстом),
  Markdown (`**bold**`, `_italic_`, `` `code` ``, `~~strike~~`, `||spoiler||`), HTML —
  для отправки на сервер, вставки, копирования.
- **Ввод Markdown на лету** (по настройке): набрали `**слово**` — стало жирным.
- **Отображение:** `Text` учится показывать `RichText` (сейчас — строка одного стиля): отрезки
  со стилями, ссылки нажимаются (`onLink`), спойлер скрыт до касания, упоминания.
- **Редактор (`TextEditor(rich:)`)**: `UITextView`/`NSTextView` на TextKit 2; модель ↔
  атрибуты через симметричный преобразователь (цвета темы применяются при показе и не
  попадают в модель — инвариант Telegram); меню «Формат» в меню правки; ⌘B/⌘I/⌘U — команды
  (`Command`), доступные и из строки меню Mac/iPad.

## Checkbox и Switch

- `Switch(isOn:)` — на iOS и Mac есть системные (`UISwitch`, `NSSwitch`), на TV — нет.
  `Checkbox` — на Mac системный (`NSButton` со стилем checkbox), на iOS — нет вовсе
  (у Telegram свой `CheckNode`).
- Рекомендация: оба — свои ноды, рисуемые по теме (цвета, анимация «щелчка»), одинаковые
  на всех платформах; доступность — как у системных (признак переключателя, значение
  «вкл/выкл», действие). Системный вид — по настройке (`style: .platform`) через
  вложенный вид, где он есть.
- Состояние Checkbox: вкл/выкл/смешанное (для «выбрать всё»).

## Select (выпадающее меню)

```swift
let sort = Select(options: [.date, .sender, .subject], selection: .date) { $0.title }
```

- iOS/iPad: кнопка, открывающая системное меню (`UIButton.menu`, `showsMenuAsPrimaryAction`,
  галочка у выбранного) — родное поведение iOS 14+.
- Mac: `NSPopUpButton` (вложенный вид) или своё меню `NSMenu` из кнопки.
- TV: меню нет — список вариантов на весь экран (`Alert(style: .actions)` или экран-список).
- Много вариантов с поиском (страны) — отдельный компонент позже: экран-список в листе.

## Toast

Короткое сообщение поверх окна, само уходит: «Сообщение удалено — Отменить»
(Telegram `UndoOverlayController`).

```swift
shell.toast(Toast("Message deleted", action: ToastAction("Undo") { restore() }))
```

- Уровень окна (`SceneSession`), поверх листов; очередь — по одному, новый заменяет или ждёт
  (настройка). Длительность: 4 с, с действием — дольше; касание или смахивание убирает;
  пока VoiceOver читает — не уходит.
- Доступность: объявление (`UIAccessibility.post(.announcement)`, `NSAccessibility`).
- Положение: снизу над панелью вкладок и клавиатурой (учитывает `keyboardInset`), на Mac —
  снизу окна, на TV — сверху справа, без кнопки (или кнопка по Play/Pause).

## Tooltip

Было в плане раньше: `node.toolTip` (Mac — `NSView.addToolTip(rect:)` по рамкам нод, iPad —
`UIToolTipInteraction` с курсором, iPhone/TV — нет). Кнопки панели и пункты меню — из
заголовка команды. Входит в `Control` (`toolTip`), но работает у любой ноды.

## План

| Этап | Что | Проверка |
|---|---|---|
| C0 | `Control` (состояние, выключенность, наведение, клавиши нажатия); `Button` на нём; `Tooltip` | модель на Linux; наведение и подсказка на Mac/iPad, UI-тесты |
| C1 | `Checkbox`, `Switch` (свои, по теме), доступность как у системных | модель; VoiceOver-признаки; TV-фокус |
| C2 | Вложенный вид платформы (`HostedView`) в Nodes и адаптерах | рамки при прокрутке, скрытие, порядок, фокус |
| C3 | `TextField`, `EmailField`, `SecureField`, `TextEditor`; Tab/Return по полям | ввод, автозаполнение email, проверка, TV-клавиатура |
| C4 | Клавиатура: `keyboardInset`, анимация по кривой, поле над клавиатурой, скрытие | UI-тесты iPhone/iPad, плавающая клавиатура |
| C5 | `Select`, `Toast` | меню iOS/Mac, список на TV, очередь тостов, объявление |
| C6 | `RichText` (модель, конвертеры) и `Text` с rich text | Linux-тесты round-trip; ссылки, спойлер |
| C7 | Rich text редактор: TextKit 2, меню «Формат», Markdown на лету, ⌘B/⌘I | UI-тесты правки; round-trip с моделью |

## Вопросы пользователю

1. **Вид Switch/Checkbox:** свои по теме, одинаковые везде (рекомендация), или системные
   там, где есть?
2. **Поля ввода:** системные виды внутри дерева первым шагом (рекомендация), или сразу свой
   движок ввода, как новый редактор Telegram?
3. **Rich text в первой версии:** только отрезки (bold/italic/mono/strike/underline/spoiler/
   ссылка/упоминание — как сущности Telegram) или сразу блоки (цитата, код, списки)?
4. **Интерактивное скрытие клавиатуры** («тянуть вниз вместе с пальцем»): нужно ли? Если
   да — наш `Scroll` на iOS должен стать `UIScrollView`-основанным или своим способом
   управлять клавиатурой (у Apple публичного нет, кроме `keyboardDismissMode`).
5. **Select на iPhone:** системное меню из кнопки (рекомендация) или лист со списком / колесо
   выбора?
6. **Toast:** новый заменяет текущий или ждёт очереди? Нужен ли на TV?
7. **Проверка полей** (`EmailField.isValid` и сообщение под полем) — часть компонентов
   (рекомендация) или дело приложения?
8. **Порядок:** C0 → C7 как в таблице, или сначала поля ввода и клавиатура (C2–C4)?
