# Trellis — план реализации: focus engine и accessibility

Статус: A01–A13 выполнены 2026-09-12 (A02, A08–A11 — срезы: ручные проверки VoiceOver/Siri Remote и физические устройства открыты). Дата: 2026-09-11.

Основа: оставшаяся часть N03 из [implementation-plan.md §7](implementation-plan.md)
и продолжение [implementation-plan-2.md §7](implementation-plan-2.md). H02–H11
дали committed hit-test snapshot, dispatcher, pointer sessions, Tap/Pan,
`ControlNode` и платформенный touch/mouse путь. Этот этап добавляет навигацию
без указателя и доступность CALayer-интерфейса для assistive technologies.

Сверены непосредственно: `Weave/Sources/WeaveUI/Focus.swift`,
`Accessibility.swift`, соответствующие `FocusTests.swift`/`AccessibilityTests.swift`,
focus/accessibility-участки `Node.swift`, `Controls.swift`,
`Weave/Sources/UIKitAdapter/UIKitAdapter.swift` и
`Weave/Sources/AppKitAdapter/AppKitAdapter.swift`; в Trellis — `NodeHostBridge`,
`RenderCoordinator`, `ControlNode`, `Event`, `Invalidation`, оба `TrellisHostView`,
манифест и [принятые решения](decisions.md). Реализация, сборка и запуск тестов
в рамках подготовки документа не выполнялись. Галочки ниже — только будущая
приёмка; завершение H11 не доказывает работу focus/VoiceOver.

## 1. Границы этапа

Входят:

- Один platform-neutral focus core: identity, последовательный и направленный
  обход, explicit overrides, текущий focus, modal scope и восстановление.
- Клавиатура macOS/iPadOS: Tab/Shift-Tab, стрелки, Return/Space; tvOS:
  системный focus, Siri Remote Select, видимое состояние сфокусированного control.
- Независимое семантическое дерево: label/value/hint, ограниченный набор ролей,
  enabled/selected, порядок чтения, grouping, hide, стандартные и custom actions.
- Настоящие нативные элементы UIKit/AppKit, их координаты, identity,
  уведомления и маршрутизация действий обратно в mounted tree.
- Общий путь активации `ControlNode` для pointer, keyboard/remote и accessibility;
  VoiceOver-сценарии, lifecycle, нагрузка и существующая CI-матрица.

Не входят: текстовый ввод/IME, `TextNode`, `ImageNode`, scroll-to-focus и
виртуализация, navigation stack, полноценный state framework, мультитач,
произвольные focus guides, системные rotors, live-region API и announcements
общего назначения. У текстового label в accessibility нет зависимости от
будущего текстового рендерера N01: это обычная строка метаданных.

Не расширяем платформенные импорты: Core — Foundation; Render — нейтральная
обвязка и CALayer; UIKit/AppKit — только соответствующие модули. Flux не
переносится. Режим `skipsLayoutOnlyWrappers == true` остаётся экспериментальным:
новый интерактивный путь в нём не включается до отдельного решения D32.

## 2. Находки и точки интеграции

### 2.1. Что брать из Weave, что перепроектировать

| ID | Наблюдение по исходнику | Следствие |
|---|---|---|
| W01 | `FocusDirection`, metadata с overrides по ID, immutable `FocusChange`/`FocusTrace` и отделение focus от accessibility — полезная основа. Но `Focus.swift` импортирует Flux и публикует `Pipe`. | Перенести идеи и value-типы с `NodeID`; переходы доставлять синхронно на MainActor, не через latest-value state binding. |
| W02 | `.forward`/`.backward` в `directionalScore` ранжируют по расстоянию; backward лишь добавляет всем одинаковые `0.001`. Равные directional scores не имеют стабильного tie-break после обхода dictionary. | Tab должен идти по порядку дерева, Shift-Tab — обратно; направленный поиск получает полный порядок сравнения. Реестр: [defects.md #33](defects.md). |
| W03 | Registry держит weak Node, но `focusedNode` — сильная ссылка. `unregister` сначала обнуляет её, затем вызывает `setFocus`: previous ID и focusOut теряются. В `setFocus` callback может изменить дерево до focusIn. | Хранить текущий ID; переход как транзакцию с повторной валидацией и тестами reentrancy. Реестр: [defects.md #34](defects.md). |
| W04 | Eligibility проверяет disposed/`semantics.isHidden`, но не закрепляет принадлежность mounted host. Поиск смешивает `calculatedFrame` и live metadata/ancestry; overrides могут указывать на зарегистрированный посторонний узел. | Committed topology/geometry и отдельная проверка актуального mount перед действием; не копировать registry как источник истины. |
| W05 | `AccessibilityTree.build` одинаково сохраняет детей для `.contain` и `.combine`. `.ignoreSelf` сохраняет `isElement`, а reading order затем добавляет self. Тест combine использует только скрытого ребёнка и не различает политики. | Определить grouping на примерах с видимыми детьми; исправить при переносе. Реестр: [defects.md #35](defects.md). |
| W06 | Accessibility bridge каждого адаптера хранит snapshot и отправляет layoutChanged. Создания native elements, контейнера и action routing в этих классах нет. | Это граница API, а не готовая платформенная реализация. A09/A10 должны предъявить реальные элементы системному accessibility tree. |
| W07 | Properties содержат одновременно `value` и `state.value`, traits и state дублируют disabled/selected. | В Trellis один источник enabled/selected/value; mapping в native traits выполняется адаптером. |

Известные расхождения источника фиксируются также в
[source-provenance.md](source-provenance.md). Weave не изменяется. При переносе
каждого файла — строка происхождения в том же коммите, а не задним числом.

### 2.2. Текущий Trellis

- `NodeHostBridge.onCommitGeometry` применяет renderer и строит
  `HitTestSnapshot` в одном синхронном участке. Здесь следует публиковать
  согласованный набор geometry/focus/semantics, до пользовательских callbacks.
- `onPaintOnly` обновляет appearance. Семантического dirty reason и callback
  пока нет. В `RenderCoordinator.flush()` layout snapshot создаётся до проверки
  same-work: простого добавления флага недостаточно для semantic-only fast path.
- `EventPayload` содержит только pointer, а `Event.pointer` — не optional.
  Добавление focus/activation требует явного решения совместимости и миграции
  `ControlNode.track`, который читает pointer до switch по типу события.
- `ControlNode.activation` сейчас вызывается только из победившего Tap;
  enabled/focused-состояния нет. Нельзя имитировать pointerDown/up для VoiceOver.
- CALayer сам по себе не даёт ноде нативный focus/accessibility endpoint.
  Дополнительные платформенные объекты необходимы, но не второй renderer.
- В `Package.swift` тестовый target Render зависит от AppKit, но не UIKit.
  Для native UIKit tests нужно расширить существующие test dependencies либо
  добавить платформенный test target и включить его в matrix/consumer проверки.

## 3. Предлагаемые решения до зависимой реализации

Номера D35–D48 — **предложения**, продолжение D16–D34. Они не объявляются
принятыми фактом создания этого документа. A01 фиксирует выбранные контракты
в `decisions.md` и при необходимости ADR; A02 проверяет платформенную
осуществимость D44. Исследовательский прототип не утверждает публичный API.

| Решение | Предложение | Что зависит |
|---|---|---|
| D35. Владение | `FocusEngine` и семантические value-снимки — Core. Bridge владеет engine, актуальными снимками и mounted scope. Engine хранит `NodeID`, epoch и значения; не Node/host/closures нод. Native adapters принадлежат host, резолвят ID через weak bridge. | A03–A10 |
| D36. Согласованное состояние | Снимки маркированы host/mount epoch, geometry generation и отдельной semantic/focus revision. Геометрия и порядок — из последнего commit. Metadata-only flush обновляет только уже committed IDs; при pending structure/geometry ждёт согласованного commit. Перед callback/action — live mount, disposed, ancestry и enabled guard. | A03, A06 |
| D37. Eligibility | Обычная Node по умолчанию не focusable; control opt-in по умолчанию. Для focus нужны committed frame, непустая видимая область, положительная opacity по предкам, enabled и членство в scope. Accessibility hide не отключает keyboard focus; disabled control остаётся читаемым, но не активируется. Arrangement wrapper не endpoint ни одного дерева. | A03–A06 |
| D38. Обход | Tab — committed pre-order focusable элементов, Shift-Tab — обратный; creation ID и zIndex не задают порядок. Стрелки — физические направления в host space; RTL не меняет смысл left/right, но может менять геометрию. Valid explicit override раньше поиска; неизвестный/self/out-of-scope target игнорируется. Без кандидата — unchanged/unhandled; без текущего focus forward/стрелка берут первый, backward — последний. | A04 |
| D39. Переход | `focusedID`, `FocusChange(previous,next,reason)` и revision перехода. focusOut → валидация next → focusIn → итоговое уведомление. Тот же ID — no-op. Вложенный запрос не рекурсирует: отложен до конца текущего перехода, с повторной валидацией и защитой от бесконечного callback-loop. События переходов не объединяются как отображаемое state. | A04, A05 |
| D40. Scope/lifecycle | Один modal subtree на host, без стека; хранится ID scope и ID focus до открытия. Открытие ограничивает focus и semantic exposure одной транзакцией, закрытие восстанавливает валидный прежний ID либо первый доступный. Пустая modal scope не выпускает focus в фон. Detach/root replacement очищают всё; suspend отменяет activation, сохраняет только restoration ID. | A05, A11 |
| D41. Metadata/инвалидация | Value-properties на Node с equality/no-op guard; отдельные focus/semantics dirty reasons и ревизии. Один coalesced flush на burst без layout snapshot/Flex, если geometry чистая. Label/value/hint и state живут в одном месте; `isEnabled` control — источник для focus eligibility, всех способов activation и AX mapping. | A03, A06, A07 |
| D42. Семантическое дерево | Независимо от focusable и hit-target. `.contain` сохраняет контейнер/детей, `.ignoreSelf` исключает собственный endpoint, `.hide` исключает subtree, `.combine` создаёт один элемент без отдельных детей. Reading order: sortPriority среди siblings, при равенстве committed tree order. Priority конечный, иначе 0. | A06 |
| D43. Действия | Единый default activation на ControlNode с source pointer/keyboard/remote/accessibility, без поддельных координат. Capture/target/bubble и preventDefault работают перед default action. AX action возвращает handled только при фактической обработке. Unknown/stale/disabled — false; custom action имеет стабильный ID отдельно от локализованного имени. | A07, A09, A10 |
| D44. Системный focus | На tvOS UIKit подтверждает реальный focus; engine не объявляет переход завершённым до native callback. Кандидаты, scope и overrides общие, но native spatial selection может отличаться от headless score. Один писатель committed focusedID, без второго независимого cursor по remote presses. Представление focus items выбирается в A02. | A02, A08 |
| D45. Два вида focus | Keyboard/remote focus и VoiceOver cursor независимы. AX activate не переносит keyboard focus. На tvOS системные callbacks могут связать их; зеркалирование только наблюдённого перехода с origin/token guard от feedback loop. Background commit не принуждает VoiceOver вернуться к engine.focusedID. | A08–A11 |
| D46. Геометрия | Общие transform/clip вычисления с D17; не отдельный расчёт pivot. Focus использует AABB видимого transformed polygon; полностью отсечённые элементы исключаются. Native AX frame — screen-space bounding box видимой области; conversion host→window→screen только в адаптере. Частичное перекрытие соседями не решаем pixel-perfect; порядок AX не равен paint order. | A03, A09, A10 |
| D47. Уведомления | Native elements переиспользуются по `(mountEpoch, NodeID)`. Сначала целиком заменить published tree/properties, затем уведомлять об изменении. No-op не уведомляет; value change не превращается автоматически в screen change. Layout/modal notification адресуется соответствующему host/элементу. | A09, A10 |
| D48. Совместимость | Добавить typed focus/activation payloads. Предлагается `Event.pointer: PointerData?` и migration note для внешнего consumer; новая enum case не считается автоматически source-compatible. Точные сигнатуры, public docs и API diff утверждаются в A01, baseline обновляется отдельной командой. | A01, A07, A13 |

### 3.1. Дополнение к обходу и восстановлению

Headless directional score начинается с простой детерминированной модели:
центры видимых AABB, строго положительная проекция в нужном направлении,
`primaryDistance + 0.5 * secondaryDistance`; равенство — committed traversal
index. Priority, если сохраняется из Weave, применяется только при выборе
начального/fallback focus, а не вычитанием epsilon из расстояния. A01 должен
закрепить наличие priority и его место в сравнении; Tab остаётся tree-order.
Wrap отключён вне modal; внутри modal Tab циклический, стрелки без wrap.
На границе host unhandled Tab передаётся системному traversal, иначе возникнет
keyboard trap. Explicit override не может вывести из modal scope.

Удаление/disable/полное clipping сфокусированной ноды на commit выбирает
следующего живого кандидата по прежнему traversal index, затем предыдущего,
затем первый в scope; пустое дерево даёт nil. Reparent допускает сохранение
ID только после commit в том же mount и scope; до этого действия по старому
маршруту отклоняются. При исчезновении modal root scope закрывается и
восстановление выполняется по тем же правилам. Resize сам по себе focus не
сбрасывает. После resume restoration проверяется по первому актуальному
снимку; новое attach никогда не наследует старую epoch.

### 3.2. Дополнение к семантике

Минимальные роли: button, text, image, header, link, group, adjustable.
Роли с текстовым редактированием не обещаются. Состояние: enabled, selected,
value; label/hint/identifier отдельно. Для control стандартный role — button,
но осмысленный label задаёт автор сцены. В A01 фиксируется mapping каждой
роли на обе платформы и осознанный fallback для неподдержанного сочетания.

Для `.combine`: явный label родителя имеет приоритет; иначе непустые labels
доступных потомков объединяются в reading order через `", "`. Value/hint/role
берутся у родителя; состояния и actions потомков автоматически не сливаются.
Комбинирование интерактивных детей требует явных actions на родителе:
иначе разработчик скрывает их отдельные действия. `.ignoreSelf` сохраняет
контейнерную связь, но self отсутствует в readingOrder независимо от isElement.
`.contain` с isElement=true и детьми требует platform test, доказывающий
доступность обоих уровней; если platform mapping не даёт этого, A01 уточняется
до публикации API. Не выдавать один плоский массив за проверку grouping.

Geometry-only commit обновляет frames, metadata-only — properties. При
перемещении native window без layout изменения адаптер пересчитывает screen
coordinates из прежнего host-space snapshot. Нативные элементы не читают
live `Node.style`/accessibility из getters. Скрытые, disposed и ранее mounted
элементы не получают action, даже если ОС ещё держит старый proxy.

## 4. Порядок и зависимости

1. A01 — контракт, A02 — ранний native tvOS/AX прототип.
2. A03 — metadata, снимок и semantic-only invalidation.
3. A04–A05 — focus core и scope/lifecycle; A06 — semantic tree.
4. A07 — события и единая активация; A08 — keyboard/remote адаптеры.
5. A09–A10 — UIKit/AppKit accessibility и действия.
6. A11 — end-to-end сцены; A12 — нагрузка; A13 — matrix/API/docs.

Критический путь tvOS: A02 → A03 → A04 → A07 → A08 → A11.
Критический путь доступности: A01 → A03 → A06 → A07 → A09/A10 → A11.
A02 может выявить необходимость уточнения D44, но не перенос платформенных
импортов в Core/Render. N01/N02 для этих путей не требуются.

## 5. Карточки реализации

### A01 — Зафиксировать контракты и примеры

- [x] Принять/уточнить D35–D48 в `decisions.md`; снять ограничение D24 только
  для нового tvOS пути, сохранив историческую приёмку H09.
- [x] Записать API sketch, ownership таблицу, event migration и native role mapping.
- [x] Зафиксировать ожидаемые переходы: Tab A→B→C и обратно; равные scores;
  пустая modal; удаление next из focusOut; AX activate с другим keyboard focus;
  metadata mutation во время solve; stale native proxy после нового attach.

Зависимости: H11. Приёмка: нет нерешённых семантических альтернатив для A03–A07;
платформенный механизм D44 окончательно выбирается по A02. Артефакт:
`docs/validation/a01-focus-accessibility-contract.md`.
**Выполнено 2026-09-11** — [validation/a01-focus-accessibility-contract.md](validation/a01-focus-accessibility-contract.md);
D35–D48 в [decisions.md](decisions.md) с уточнениями (priority — только initial/fallback;
`.contain`+`isElement`+дети — группа с label; wrap только в modal);
[ADR 0013](adr/0013-event-pointer-becomes-optional.md) для D48.

### A02 — Доказать нативный путь до масштабного переноса

- [x] Малый tvOS прототип: две CALayer-карточки, реальные focus items,
  preferred focus, переход Select → ровно одна activation и возврат после window loss.
- [x] Сравнить custom `UIFocusItem`/container с прозрачными UIView proxies;
  выбрать один способ, проверить frames, hit interception и отсутствие
  дубликатов VoiceOver элементов. Слои контента по-прежнему рисует LayerRenderer.
- [x] Две доступные карточки UIKit и AppKit: системное дерево видит label,
  role, frame и вызывает action. Простое notification не считается результатом.

Зависимости: A01 (границы). Приёмка: native evidence и решение D44 с
ограничениями SDK/устройств, стоимостью proxy на 1000 элементов и схемой
одного источника focus. Недоступный Apple TV — «нет доступа», карточка имеет
только срез; headless unit test не закрывает remote-интеграцию.
**Выполнено 2026-09-11 (срез)** — [validation/a02-native-prototype.md](validation/a02-native-prototype.md):
NSObject-proxy `UIAccessibilityElement`+`UIFocusItem` (1000 за ~1 ms, без CALayer, touch не
перехватывает); headless тесты на iOS/tvOS Simulator и macOS; focus-переходы и window loss
доказаны probe-запуском Playground-tvOS на Simulator (лог в отчёте). Не закрыто: Select →
activation (нет автоматизации ввода) и физический Apple TV — «нет доступа», ручной A11.

### A03 — Metadata и согласованный committed snapshot

- [x] Node focus/accessibility properties с no-op equality; ревизии,
  отдельные dirty reasons, semantic-only fast path до layout snapshot.
- [x] Общие immutable topology/geometry records для focus/semantics с
  host/epoch/generation; reuse transform/clip математики H02.
- [x] Commit публикует все снимки до внешнего callback; snapshot не держит Node.
- [x] Обновление metadata при pending geometry ждёт commit, но live disabled/
  detached guard немедленно запрещает действие. Чистая semantic mutation
  сама по себе не отменяет корректный solver; commit берёт актуальную metadata.

Зависимости: A01, решение A02. Приёмка: label burst — один semantic publish,
ноль новых layout snapshots/solve; same value — ноль работ; semantic update
во время solve не теряется; mutation между commits не публикует новый child
со старым frame. Проверить paint-only, geometry-only, suspend/resume,
rotation, nested transform/clip, нулевой размер и child вне visible parent.
**Выполнено 2026-09-11** — [validation/a03-metadata-and-snapshot.md](validation/a03-metadata-and-snapshot.md):
`Node.focus`/`accessibility` + `DirtyReasons.semantics`, `ControlNode.isEnabled`,
`HitTestSnapshot.visibleBounds(of:)`, `SemanticSnapshot`, publish в bridge до внешних
callbacks, semantic-only fast path без layout snapshot; 16 тестов.

### A04 — FocusEngine и детерминированный поиск

- [x] `focusedID`, request by ID/direction, focus trace; без Flux и strong Node.
- [x] Tab/Shift-Tab, стрелки, overrides, initial selection и boundary result.
- [x] Транзакция перехода D39: не более одного focusIn/out на действительный
  переход; stale/reentrant requests не перезаписывают более новое состояние.

Зависимости: A03. Приёмка: проверки D38, одинаковые scores и shuffled registry;
порядок создания ID не влияет; RTL и дерево после reorder; invalid override;
focusOut удаляет target/host, focusIn запрашивает ещё один focus; teardown
внутри callback. На native tvOS selection подтверждает адаптер, а не score.
**Выполнено 2026-09-12** — [validation/a04-focus-engine.md](validation/a04-focus-engine.md):
`FocusEngine` без Flux и strong Node, Tab — pre-order, стрелки — формула D38 с tie по
traversal index, транзакция D39 с очередью и лимитом, восстановление §3.1; события D48
([ADR 0013](adr/0013-event-pointer-becomes-optional.md)); 22 теста. Дефекты #33/#34 закрыты.

### A05 — Modal scope, восстановление и lifecycle

- [x] Scope ID и restoration ID без ссылок на ноды; совместная граница
  focus/accessibility, детерминированный fallback D40.
- [x] Suspend/window inactive сбрасывает pending press; detach чистит engine,
  scopes, deferred requests и callbacks. Resume не активирует control.

Зависимости: A04, A06 для общей semantic boundary.
Приёмка: modal open/close/empty, повторный запрос той же scope — no-op;
background target/override не проходит; dispose/reparent/disable current;
удаление modal root, два host с одинаковой generation, новый mount старого
root. После detach — nil focus и нулевые registry sizes, weak release.
**Выполнено 2026-09-12** — [validation/a05-scope-and-lifecycle.md](validation/a05-scope-and-lifecycle.md):
scope/restoration как ID в `FocusEngine`, wrap только в modal, пустая modal не выпускает
focus, suspend/resume/reset; 13 тестов. Semantic boundary — A06, press-cycle на suspend — A07.

### A06 — Semantic tree и reading order

- [x] Value-типы, роли/state/actions, builder поверх A03; независимость от focus.
- [x] Все четыре children policies по D42 и §3.2, включая visible grandchildren.
- [x] Stable reading order, modal subtree, прозрачные Arrangement wrappers.

Зависимости: A03. Приёмка: contain/ignoreSelf/combine/hide на одном fixture
дают разные ожидаемые деревья; disabled button читается без activation;
nonfocusable text читается; accessibility-hidden focusable control не читается;
sort ties идут по committed sibling order; reorder сохраняет NodeID;
combine не создаёт скрытых child actions. Проверить вложенные политики и
полностью clipped subtree без преждевременного parent-AABB отказа.
**Выполнено 2026-09-12** — [validation/a06-semantic-tree.md](validation/a06-semantic-tree.md):
`AccessibilityElement`/`AccessibilityTree.build(from:scope:)` с четырьмя политиками D42,
итеративный builder, reading order по sortPriority/committed order, публикация в bridge
с no-op на равном дереве; 11 тестов. Дефект #35 закрыт.

### A07 — Focus events, enabled и единая activation

- [x] Typed payloads D48, безопасная обработка непоинтерных событий в
  `ControlNode`; обновить внешний consumer и все pointer-only call sites.
- [x] Default activation после dispatch: winning Tap сохраняет up-inside H06,
  keyboard/remote завершают принятый press-cycle, AX вызывает один action.
- [x] `isFocused` отдельно от `isPressed`; disabled cancel сбрасывает press;
  стандартные/custom AX actions возвращают результат обработчика.
- [x] Return/Space/Select: key-down начинает cycle, key-up активирует один раз;
  repeat не создаёт вторую activation, смена focus до key-up отменяет cycle.

Зависимости: A04, A06. Приёмка: source matrix, preventDefault, удаление внутри
callback; pointer-регрессии H03–H06; AX action без pointer position и без
смены keyboard focus; stale/disabled action=false; повторный key-up — no-op.
Одно native действие не доставляется дважды через key и AX adapters.
**Выполнено 2026-09-12** — [validation/a07-activation.md](validation/a07-activation.md):
`ControlNode.activate(source:)` для pointer/keyboard/remote/accessibility, `isFocused`,
key press-cycle с `preventDefault` до default action, `FocusEngine.sendKey`/`KeyOutcome`,
`performAccessibilityAction` с live guard в bridge; 12 тестов. Consumer расширяется в A13.

### A08 — Клавиатура и remote в существующих хостах

- [x] AppKit responder/key traversal и UIKit keyboard input → общий intent;
  непотреблённые команды идут дальше в responder chain.
- [x] Native focus objects выбранного A02 вида: reuse ID, committed frames,
  preferred requests, native confirmation → engine transition с token guard.
- [x] Select и focus loss используют A07; не строить вторую pointer session.
- [x] Native window focus и accessibility cursor согласуются по D45 без loop.

Зависимости: A02, A05, A07. Приёмка: macOS Tab/Shift-Tab/Space/Return;
iPadOS hardware keyboard; tvOS remote arrows/Select, выход к соседнему
нативному control и обратно. Системный Menu/Back не перехватывается без
владельца navigation. Нет keyboard trap, автоматического повторного Select
и расхождения подсветки с native focused item.
**Выполнено 2026-09-12 (срез)** — [validation/a08-keyboard-and-remote.md](validation/a08-keyboard-and-remote.md):
AppKit `keyDown`/`keyUp` → engine с передачей непотреблённого по responder chain; UIKit
presses (tvOS стрелки — системе), `TrellisNodeProxy`/`NativeProxyCoordinator` с handshake
D44/D45; 7 тестов (macOS + iOS/tvOS Simulator). Ручные проверки на устройствах/симуляторе —
A11.

### A09 — UIKit accessibility

- [x] Host как accessibility container; реальные `UIAccessibilityElement`
  либо согласованные A02 focus/AX proxies, без двойного представления NodeID.
- [x] Label/value/hint/traits/state, hierarchy/order, frame conversion и actions.
- [x] Diff/reuse и notifications D47, modal exposure, stale action rejection.
- [x] UIKit native tests включены в test target/матрицу, не только Core tests.

Зависимости: A02, A06–A08. Приёмка: native tree enumeration и action callbacks;
VoiceOver на iOS/iPadOS и tvOS читает реальные названия, меняет cursor и
активирует выбранную карточку; frame корректен после resize/transform/window
move. No-op не уведомляет, изменение value сохраняет identity/cursor,
modal скрывает фон. Ручная проверка курсора обязательна сверх unit tests.
**Выполнено 2026-09-12 (срез)** — [validation/a09-uikit-accessibility.md](validation/a09-uikit-accessibility.md):
host — container, `TrellisNodeProxy` как `UIAccessibilityElement` (traits/frame/actions/
custom actions, semantic group), reuse и `.layoutChanged`/`.screenChanged` по D47, modal
exposure; 4 native-теста на iOS/tvOS Simulator. Ручной VoiceOver — A11.

### A10 — AppKit accessibility

- [x] Реальные `NSAccessibilityElement`/контейнер, parent/children,
  роли/значения/actions и преобразование flipped host coordinates в screen.
- [x] Stable reuse, корректные notification targets и teardown.

Зависимости: A02, A06, A07. Приёмка: native API видит дерево и правильный
reading order; VoiceOver выполняет press/custom/increment/decrement;
два окна не смешивают элементы, перенос окна меняет screen frame без Flex.
Уведомление на `NSApplication.shared` без доступного subtree не закрывает
карточку. Повторный attach не оживляет старые native action handlers.
**Выполнено 2026-09-12 (срез)** — [validation/a10-appkit-accessibility.md](validation/a10-appkit-accessibility.md):
`TrellisAccessibilityElement`/`AppKitAccessibilityCoordinator` — реальные элементы с
parent/children, роли/значения/actions, flipped host → screen, `.layoutChanged` на host и
`.valueChanged` на элементах, epoch guard для старых handlers; 4 теста. Ручной VoiceOver — A11.

### A11 — Вертикальные Playground-сценарии и device evidence

- [x] Сцена сетки controls с видимым focus, счётчиком активаций, disabled
  элементом, удалением текущей карточки и открытием/закрытием modal.
- [x] Семантическая сцена: label/value/hint, contain/combine/ignoreSelf/hide,
  selectable и adjustable элемент; объявления labels не требуют TextNode.
- [~] Записать реальные шаги keyboard/remote/VoiceOver, версии ОС, устройство,
  ожидаемый и фактический target, evidence в `docs/validation`.

Зависимости: A05, A08–A10. Приёмка: iPhone/iPad — VoiceOver, iPad + клавиатура,
Apple TV + Siri Remote и VoiceOver, Mac + клавиатура и VoiceOver. Скриншот
подсветки не доказывает spoken label/action: нужен протокол ручной проверки
или запись. Simulator, native automated test и физическое устройство
отмечаются раздельно; отсутствие доступа оставляет полную приёмку открытой.
**Выполнено 2026-09-12 (срез)** — [validation/a11-playground-scenes.md](validation/a11-playground-scenes.md):
S22_FocusGrid и S23_Semantics; macOS — automated `NSEvent`-прогон всех шагов со
скриншотами; iOS Simulator — реальный touch (activation/scope/restore); tvOS Simulator —
native focus confirmation D44; native AX деревья на трёх платформах. Не закрыто: Siri
Remote/iPad клавиатура/VoiceOver вручную и физические устройства (протокол в отчёте).

### A12 — Нагрузка и освобождение ресурсов

- [x] 1000 semantic/focusable элементов, burst value changes, быстрые moves,
  modal open/close и attach/detach во время незавершённого native request.
- [x] Замер build/publish/search, native proxy count/reuse и памяти в release
  при выключенном подробном логе; сравнить ранний A02 замер.
- [x] Weak release bridge/root/control/native proxies; пустые registries после
  detach, нет поздних callbacks. Глубокое дерево строится без квадратичного
  копирования descendants и без неограниченной рекурсии на MainActor.

Зависимости: A11. Приёмка: число proxies ограничено текущим semantic/focus
набором, не числом commits; повторные attach/detach не накапливают ресурсы;
semantic-only burst не запускает solver. Численные бюджеты фиксируются по
A02 до итогового прогона; flaky wall-clock thresholds не заменяют счётчики.
**Выполнено 2026-09-12** — [validation/a12-load-and-release.md](validation/a12-load-and-release.md):
bench `semantics-1000` (release: publish 16 ms, burst 2.2 ms, Tab 0.15 ms, стрелка 0.9 ms),
кэш кандидатов в engine, счётчики created proxies/elements; 5 тестов (macOS + Simulator):
proxies ограничены снимком, weak release, глубина 1500 без рекурсии. Device-замер — нет доступа.

### A13 — CI, API baseline и документация подключения

- [x] `python3 Scripts/check_all.py` и `--matrix`: policy/format, Core/Render/
  native adapter tests, consumer и API; Swift 6 без запрещённых обходов isolation.
- [x] Отдельно обновить baseline с review note по D48 и новым public API.
- [x] Документировать metadata, action handling, focus scope, доступные роли,
  ownership/cancellation; реальные примеры без Flux и `@testable`.
- [x] Итоговая таблица: что выполнено полностью, что только на simulator,
  какие устройства недоступны и какие ограничения остаются.

Зависимости: A11–A12. Приёмка: текущая матрица включает новые тесты на macOS,
iOS/tvOS Simulator; consumer использует focus + AX action API. Сборка
device SDK не выдаётся за physical input test; A13 не закрывает отсутствие
evidence A11. Новые дефекты регистрируются до исправления.
**Выполнено 2026-09-12** — [validation/a13-ci-api-docs.md](validation/a13-ci-api-docs.md):
`check_all.py --matrix` (macOS/iOS/tvOS Simulator tests, device build-only), consumer с
focus + AX API без `@testable`, baseline `PASS`, README/AGENTS дополнены, итоговая таблица
«полностью / Simulator / нет доступа». Полная приёмка N03 остаётся открытой по A11.

## 6. Матрица рисков и доказательств

| Риск | Автоматическое доказательство | Нативная/ручная проверка |
|---|---|---|
| Geometry и semantics разных revisions | A03: mutation во время solve/между commits | Frame совпадает с видимой карточкой |
| Tab как nearest-neighbour | A04: A→B→C→A в modal, обратный обход | Keyboard traversal, выход из host |
| Два владельца tvOS focus | A08: request/confirmation token, repeated callback | A02/A11: Remote, native neighbour, window loss |
| Реентрантный переход на удалённый target | A04/A05: mutation/detach в focusOut/In | — |
| Combine/ignoreSelf дублируют endpoints | A06: видимые descendants и точный order | A09/A10: реальные native containers |
| AX cursor украден layout commit | A09/A10: stable proxies, notification diff | A11: VoiceOver cursor после value/resize |
| Двойная/disabled activation | A07: матрица источников, repeat/cancel | Select и VoiceOver activate — один счётчик |
| Перепутаны экранные координаты | Native conversion tests двух окон и flipped host | VoiceOver highlight, перемещение окна |
| Registry/closure удерживают дерево | A12: weak release и размеры registries | Release memory/proxy-count замеры |
| Зелёная CI скрывает отсутствие native AX | A13 включает adapter tests | A11 evidence по каждой платформе |

## 7. После этой части

N03 считается закрытым только при полной приёмке A01–A13 вместе с H02–H11,
а не при появлении `FocusEngine.swift` и зелёных headless tests. Исторические
ограничения предыдущего плана остаются в его отчётах; новая tvOS evidence
явно ссылается на A11.

Следующие расширения: nested focus scopes/navigation, scroll-to-focus и
виртуализация, native editable text/IME (N01), rotors/live regions, сложное
объединение semantic actions, focus guides и оптимизация wrapperless rendering
(D32). Они не добавляются незаметно в приёмку текущих карточек.

Платформенные отправные точки (проверены при подготовке, 2026-09-11):
участие нативного объекта в focus описывает
[Apple UIFocusItem](https://developer.apple.com/documentation/uikit/uifocusitem);
контейнеры и запросы перехода —
[UIFocusEnvironment](https://developer.apple.com/documentation/uikit/uifocusenvironment).
Для доступности контента без UIView UIKit предоставляет
[UIAccessibilityElement](https://developer.apple.com/documentation/uikit/uiaccessibilityelement);
AppKit endpoint —
[NSAccessibilityElement](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class).
Конкретные availability и Swift 6 isolation выбранного proxy API проверяются
на SDK проекта в A02, а не предполагаются по наличию имени в документации.
