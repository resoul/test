# R08 — native movement, focus и accessibility

Обновлено: 2026-09-23. Программные пробелы focus reveal/AX/lifecycle устранены;
iOS/tvOS UI-прогоны выполнены на Simulator. Пользователь подтвердил, что
перечисленные ниже физические проверки также запускались на реальных устройствах.
Список моделей, версий ОС и отдельных результатов в этой сессии не предоставлен;
такие детали не выдумываются. Исторические записи 17–18 сентября сохранены,
а пользовательское уточнение имеет приоритет для текущего статуса R08.

## Выполнено

- `NativeScrollBacking.apply(configuration:)` проводит `ScrollConfiguration` в
  адаптер до следующего layout: UIKit выставляет input, directional lock,
  indicators, bounce и keyboard-dismiss; AppKit — indicators, elasticity и
  gate wheel/trackpad events для `userInteractionEnabled`. Программные команды
  при выключенном пользовательском вводе остаются доступны.
- Каждый native offset tick теперь переиздаёт `SemanticSnapshot`, но не запрашивает
  layout/raster. `HitTestSnapshot.visibleBounds(of:)` переводит content-space box
  в viewport-space на `-offset` до scroll clip; это же работает для вложенных
  scroll ancestors. Тем самым hit test, focus eligibility и AX frames используют
  одну актуальную геометрию.
- Regression `test_scrollOffset_republishesFocusAndAccessibilityGeometryWithoutLayout`
  проверяет переход control из offscreen в видимую область после `.dragging`,
  успешный `focus`, новое visible bounds и отсутствие нового layout snapshot.
- Regression `test_scrollNode_appliesConfigurationWithoutASecondLayoutSnapshot`
  проверяет передачу конфигурации backing'у без нового layout snapshot.

## Проверено

`swift test --filter 'ScrollNodeHitTest|test_scroll'` — прошло: 24 render и
20 core scroll tests. В macOS-набор также попали реальные
`AppKitScrollNodeEmbeddingTests`; это не доказательство живого wheel/trackpad
input, только проверка компиляции и native AppKit embedding.

`Playground-iOS` успешно запущен на iPhone 18 Pro Simulator после исправления
scene-based lifecycle (`UIApplicationSceneManifest` + `SceneDelegate`). Это
подтверждает запуск Playground и готовность ручного input-прогона, но само по
себе не подтверждает touch/deceleration/focus/AX критерии ниже.

`python3 Scripts/check_policy.py` — `PASS`, 0 diagnostics.

## Остаётся для закрытия R08

- Реальные UIKit touch/deceleration/bounce и отмена animation user input на iOS/iPadOS;
- iPadOS indirect pointer/trackpad, hover и resize Split View/Stage Manager;
- AppKit wheel/trackpad/momentum в живом окне;
- tvOS remote/focus-driven reveal и AX scroll actions;
- native tap-after-drag trace и detach во время фактического движения.

Simulator resize не будет выдан за аппаратный trackpad input; недоступное
устройство фиксируется отдельно от покрытых unit/AppKit embedding checks.

## 2026-09-18: первый живой iOS Simulator прогон — найден блокирующий архитектурный пробел

Эта сессия впервые собрала и запустила `Playground-iOS` через реальный
`xcodebuild … -destination 'id=<iPhone 18 Pro Simulator>'` (не `swift build`)
и впервые смонтировала настоящий `ScrollNode` в Playground — новый сценарий
[`S33_ScrollNodeInteraction`](../../Playground/Shared/Scenarios/S33_ScrollNodeInteraction.swift)
(вертикальный `ScrollNode`, 16 строк по 96pt, `ControlNode`-карточки на row 1 —
видима сразу — и row 10 — за сгибом), зарегистрирован в `Scenario.swift` и
`Playground.xcodeproj`.

**Найдено и исправлено по пути (дефект #74, `docs/defects.md`):**
`UIScrollViewBacking.makeChildBacking` не компилировался под реальным Xcode —
отсутствовал `return` перед конструктором. Это никогда не ловилось раньше,
потому что `swift build`/`swift test` на macOS целиком исключают файл под
`#if canImport(UIKit)`; первый в истории проекта `xcodebuild` для
`Playground-iOS` в этой же сессии впервые прогнал этот файл через реальный
компилятор. Исправлено (добавлен `return`); `xcodebuild test -scheme
Trellis-Package -only-testing:TrellisRenderTests` на iPhone 18 Pro Simulator —
295/295 зелёных, включая `UIKitScrollNodeEmbeddingTests`.

**Найден блокирующий архитектурный пробел (дефект #75, `docs/defects.md`,
открыт):** после исправления сборки и живого запуска сценарии — реальный
`swipe` по `ScrollNode` корректно двигает native offset (подтверждён fling с
моментумом, открывающий скрытую за сгибом row 10 — real UIKit
deceleration/momentum работает, это часть R08 checklist item 2 закрыта живьём
для UIKit), **но реальный `tap` точно по видимой `ControlNode`-карточке ни
разу не активировал её** — ни row 1 (видима сразу, без scroll), ни row 10
(открыта drag'ом, что должно было бы проверить offset-aware hit test). Три
независимые попытки с последовательно уточнёнными координатами (пересчитаны
из raw `xcrun simctl io screenshot`, а не из показанного preview-масштаба)
дали одинаковый результат: индикатор карточки остаётся серым (`Palette.
border`), не зеленеет.

Причина локализована по коду, не только по симптому: `TrellisHostView`'s весь
pointer pipeline (`touchesBegan/Moved/Ended/Cancelled` → `bridge?.send(.
pointerDown/…)`) реализован как override этих методов **на самом хосте** —
UIKit вызывает их только на view, выигравшей `hitTest`. R07 встраивает
`ScrollNode` как отдельный настоящий `UIScrollView`-subview хоста
(`UIScrollViewBacking.init`: `superview.addSubview(scrollView)`), так что
любая точка внутри `ScrollNode` теперь hit-тестируется в этот `UIScrollView`,
не в `TrellisHostView` — и ничего не форвардит touch-события обратно. Значит
**любой** потомок `ScrollNode` (не только `ControlNode`) не получает вообще
ни одного pointer-события Trellis на реальном UIKit-хосте; долетаёт только
native offset самого `UIScrollView` (что и объясняет, почему swipe/momentum
работают, а tap — нет). Ни один существующий тест это не ловит:
`ScrollNodeHitTestTests`/`UIKitScrollNodeEmbeddingTests` используют fake
backing/programmatic offset, не реальный `UITouch` через `TrellisHostView`.

Это меняет масштаб оставшегося R08 checklist item 3 («Hit test учитывает
текущий offset, tap после drag не активирует control»): вопрос не в
корректности offset-конверсии (та часть уже закрыта дефектом #71/R08's первым
проходом), а в том, что тап до `ControlNode` внутри `ScrollNode` не доходит
**вообще**, при любом offset. Нужен явный форвардинг pointer-событий из
scroll-backing'ов обратно в `NodeHostBridge` (вероятно, `UIGestureRecognizer`,
прикреплённый к `TrellisHostView`, получающий touch-и по границам хоста
независимо от того, какая subview их hit-тестировала — в отличие от
переопределения `touches*` на конкретной view) — дизайн этого форвардинга не
входит в объём уже проверенного и не начат в этой сессии; см. дефект #75 для
деталей и следующего шага.

## 2026-09-18 (продолжение): дефект #75 исправлен — второй, более глубокий root cause

Тем же днём, после того как выше зафиксирован пробел, реализован и проверен
живьём фикс: `TrellisTouchObserver` (UIKit) / `TrellisMouseObserver` (AppKit) —
пассивный `UIGestureRecognizer`/`NSGestureRecognizer`, прикреплённый напрямую к
`TrellisHostView` в `installTouchObserver()`/`installMouseObserver()`. Такой
recognizer получает touch/mouse-события по всей area хоста независимо от того,
какой subview их hit-тестировал — ровно то форвардинг-решение, которое было
намечено выше. Он пересылает каждую фазу в уже существующие (протестированные)
обработчики хоста; `cancelsTouchesInView = false`/`delaysPrimaryMouseButtonEvents
= false`, `state` никогда не покидает `.possible` — наблюдатель не участвует в
арбитраже, только пассивно смотрит. `touchesBegan`'s `pointerDown` получил явный
guard `touchPointerIDs[key] == nil` (AppKit — `hasActiveMouseSession`, сбрасывается
в `detach()`/при резигнации окна), поскольку теперь один и тот же реальный touch
может дойти до хоста дважды (его собственный override + наблюдатель), когда хост
сам оказывается hit-тестирован напрямую; `pointerUp`/`pointerCancel` уже были
идемпотентны через `removeValue(forKey:)`.

Первый живой прогон после этого фикса (S33, тот же iPhone 18 Pro Simulator)
показал: row 1 (без scroll) активируется корректно, но row 10 (открыта реальным
drag'ом) — **всё ещё нет**, стабильно, включая после явного ожидания 3+ секунд
полного оседания momentum. Диагностика через `TRELLIS_LOG` потребовала
`xcrun simctl launch --console-pty` (не `--console`/`log stream`: оба теряли
вывод из-за block-buffering — приложение никогда не флашило свой stdout без PTY)
— показала: на **весь** цикл swipe+tap появляется только ОДИН `session-begin`
(`pointer=1`, от самого swipe), а его `session-end` появляется только ПОСЛЕ —
и относится к — СЛЕДУЮЩЕЙ, несвязанной попытке взаимодействия, а не к
завершению самого swipe. Значит `touchesEnded`/`touchesCancelled` никогда не
доставлялись наблюдателю, пока `ScrollNode`'s собственный native pan
recognizer действительно распознавал реальный drag — сессия оставалась
залипшей, и `PointerSessions`' single-touch enforcement (D30) молча отклонял
`pointerDown` каждого следующего тапа, пока его не "смывал" случайный более
поздний жест.

Причина: без явного `UIGestureRecognizerDelegate`/`NSGestureRecognizerDelegate`,
разрешающего одновременное распознавание, политика UIKit/AppKit по умолчанию
для конкурирующих recognizer'ов молча прекращает доставку `touchesMoved/Ended/
Cancelled` пассивному recognizer'у-предку, как только recognizer потомка
(pan у `UIScrollView`) реально начинает распознавание. Оба наблюдателя теперь
реализуют `shouldRecognizeSimultaneouslyWith` → `true` безусловно (безопасно:
наблюдатель никогда сам не "побеждает" — `state` не покидает `.possible`).

**Подтверждено живьём после фикса:** тот же swipe+tap на iPhone 18 Pro
Simulator теперь логирует `session-begin` → `activated` → `session-end`
корректно; индикатор карточки запикселено подтверждён зелёным (`Palette.
green`, `(57,200,141)` при ожидаемых `(51,191,122)`). Реальный drag, *начатый*
прямо на уже активированной карточке, логирует `session-begin`/`session-end`
без единого промежуточного `activated` — подтверждает, что drag-vs-tap
disambiguation (D29) не сломан фиксом. Полный regression:
`swift test` (macOS) — 787/787 (включая ранее флейковавший
`m12_gestureGrabbingAnInFlightOpen…`, чисто в изоляции); `xcodebuild test
-scheme Trellis-Package -only-testing:TrellisRenderTests` (iPhone 18 Pro
Simulator) — 296/296, включая новый `Tests/TrellisRenderTests/
ScrollNodeRealOffsetTouchTests.swift` (реальный `UIScrollView.contentOffset` +
прямые `touchesBegan`/`touchesEnded` — доказывает, что `HitTestSnapshot`/
`scrollOffsets`-математика сама по себе была верна всё это время; настоящий
баг был именно в доставке событий recognizer'у, не в offset-конверсии).
`check_policy.py` — чисто (`required init?(coder:)` для `NSGestureRecognizer`
написан как failable `return nil`, не `fatalError` — FORCE_OPERATION запрещает
`fatalError`/`try!`/force-unwrap без исключений).

Дефект #75 закрыт (`docs/defects.md`) — оба root cause описаны и исправлены там.

## 2026-09-18 (продолжение): AppKit подтверждён живьём пользователем на реальном трекпаде

Пользователь сам собрал и запустил `Playground-macOS` (Xcode, схема
`Playground-macOS`) на реальном железе и вручную прогнал S33 через реальный
трекпад — прислал живой `TRELLIS_LOG`. Лог подтверждает оба сценария:

- Скролл трекпадом (много `[trellis.semantics] published ... revision=NN`
  подряд, offset-only тики) — работает; на AppKit скролл идёт через
  `scrollWheel`/wheel events, полностью отдельно от `mouseDown/Dragged/Up`
  пайплайна (важное отличие от iOS, где drag пальцем — это один и тот же
  touch-канал и для скролла, и для тапа).
- Клик по карточке после скролла: `session-begin` → `appearance changed` →
  **`activated`** → `session-end ... pointerUp` — активация проходит с первого
  раза, залипания сессии (как было на UIKit до фикса) не воспроизведено.
- Отдельно проверено «зажать и потянуть карточку в сторону, отпустить снаружи»:
  `session-begin` → серия `style no-op appearance` (индикатор держит
  `Palette.cyan` пока зажато) → `session-end ... pointerUp` **без**
  `activated` между ними — карточка корректно не активируется при drag-away,
  D29 disambiguation не сломан фиксом дефекта #75 и на AppKit.

Это закрывает AppKit-часть п.2/п.3 чек-листа R08 живым трекпадом, не только
синтетическими `NSEvent`-тестами (`AppKitPointerInputTests`).

## 2026-09-18 (продолжение): tvOS не запускался вообще — дефект #76, исправлен

Пользователь попытался вручную запустить `Playground-tvOS` для проверки
focus/remote — приложение падало на старте:
`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`: «UIScene life
cycle is required for apps built with this SDK». Тот же класс дефекта, что
уже был исправлен для iOS (#73): tvOS-таргету не хватало
`INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, а `AppDelegate`
использовал старый постфактум-паттерн (`UIScene.didActivateNotification`)
вместо `UISceneConfiguration`/`UIWindowSceneDelegate`. Исправлено (дефект #76,
`docs/defects.md`) по образцу уже рабочего iOS-таргета. Проверено: `xcodebuild
-scheme Playground-tvOS build` зелёный; живой запуск на Apple TV 4K (3rd
generation) Simulator — приложение стартует без краша, `S33_ScrollNodeInteraction`
монтируется и рендерится (скриншот). Focus-навигация Siri Remote/AX scroll
actions сама по себе этим не проверена — краш мешал добраться даже до этого.

## 2026-09-18 (продолжение): tvOS focus-навигация подтверждена живьём пользователем

После фикса #76 пользователь прогнал `Playground-tvOS` на Apple TV 4K
Simulator с `TRELLIS_LOG=focus,semantics,event,host`. Первая попытка на S33
показала: `focusItems=0` (сцена не переключилась — запуск через Xcode Run без
`--scene` держит `Scenario.current = .s01`, у которой нет ни одного
`ControlNode`); после явного `--scene S33_ScrollNodeInteraction` в Arguments
Passed On Launch фокус на baseline-карточке подтверждался (`activated
source=keyboard`), но стрелки не двигали фокус дальше — ожидаемо: в S33 на
экране одновременно только ОДНА фокусируемая карточка (row 10 вне viewport,
`isFocusCandidate` требует непустые `visibleBounds`), двигать некуда.

Чтобы отделить общую tvOS focus-навигацию от специфичного для `ScrollNode`
offscreen-reveal, переключились на `S22_FocusGrid` (несколько карточек видны
одновременно, без `ScrollNode`) — лог подтвердил полностью рабочий цикл:
`focusItems=8`, стрелки последовательно двигают фокус по всем восьми
карточкам (`#5→#17→#25→#13→#9→#33→#37→#25→...`), каждый переход —
`[trellis.focus] changed ... reason=native` + `native-focus ... confirmed=true`
на предыдущем элементе. Общий tvOS `UIFocusSystem`-движок (D44) подтверждён
живым пультом/клавиатурой Simulator, не только unit-тестами.

Итог: «стрелки не работают» на S33 — не баг, а следствие уже известного
открытого пункта чек-листа («focus reveal, offscreen eligibility») — переход
фокуса к краю видимой области `ScrollNode` должен был бы триггерить
авто-скролл, открывающий следующую офскрин-карточку; этот механизм не
реализован ни в одной карточке плана 6 пока. Общая tvOS-навигация вне
`ScrollNode` работает корректно и подтверждена живьём.

## 2026-09-18 (продолжение): iPadOS trackpad + resize/Split View подтверждены живьём

Пользователь прогнал `Playground-iOS` на iPad Simulator с `I/O ▸ Input ▸ Send
Pointer Events` (эмуляция indirect pointer/trackpad через хостовый
трекпад/мышь) и `TRELLIS_LOG`. Лог подтверждает:

- Наведение курсора по карточкам генерирует pointer-сессии (`session-begin`/
  `session-end`, растущие `pointer=N`); клик активирует —
  `[trellis.event] activated ... source=pointer` дважды, на двух разных
  карточках.
- **Resize (Split View-ширина)**: чистый переход `1032×1376 → 375×1376`
  (типичная узкая Split View-колонка) — новый layout/commit, `ScrollNode`
  пересчитал ширину строк (`1000pt → 343pt`), `scroll-backing=true`
  сохранился на native backing, `focusItems=2` не потерялись, краша нет.
  Anchor/фокус переживают resize.

Заодно всплыло безобидное, но шумное UIKit-предупреждение:
`<TrellisTouchObserver: 0x…> has been in possible phase for 47s` — ожидаемо
для recognizer'а, который **намеренно** никогда не покидает `.possible`
(R08/defect #75's фикс); доставка событий продолжала работать корректно и
до, и после этого сообщения в той же сессии. Задокументировано в коде
(`TrellisTouchObserver`'s doc comment), чтобы не приняли за реальный баг —
отдельного дефекта не заводилось, поведение штатное.

Это закрывает живьём iPadOS-часть чек-листа R08 (trackpad/pointer, resize с
сохранением anchor/focus) в Simulator. Настоящее аппаратное Split View/Stage
Manager (два разных приложения бок о бок на реальном iPad) не проверялось —
Simulator ограничен эмуляцией resize одного приложения.

## Остаётся для закрытия R08 (обновлено)

Блокирующие пробелы (touch pipeline #75, tvOS launch #76) закрыты. UIKit,
AppKit, tvOS (вне ScrollNode) и iPadOS trackpad/resize подтверждены живьём.
Остаётся:

- Настоящее аппаратное Split View/Stage Manager на реальном iPad (два разных
  приложения) — Simulator это не эмулирует полноценно, resize в Simulator уже
  проверен и достаточен как приближение;
- Focus-driven reveal офскрин-контента `ScrollNode` на tvOS (авто-скролл к
  следующему фокусируемому элементу) — не реализовано, не входит в объём
  уже проверенного R06–R08, отдельная задача (см. также R11's anchor/reveal);
- AX scroll actions (assistive-technology-driven scroll, не только
  focus-навигация) отдельно не проверены живьём;
- Detach во время фактического momentum не проверен изолированно (кнопки
  Prev/Next оверлея — за пределами `TrellisHostView`, не заблокированы
  дефектом #75, но не были достигнуты точным тапом в отведённое время сессии).

Simulator resize не будет выдан за аппаратный trackpad input; недоступное
устройство фиксируется отдельно от покрытых unit/AppKit embedding checks.

## 2026-09-23: focus reveal, AX и проверенный native teardown

С пользователем согласован [ADR 0028](../adr/0028-scroll-focus-reveal.md), уточняющий
D37/D38/D44. Скрытая карточка участвует только в поиске цели раскрытия; eligibility
проверяется повторно после native scroll. На tvOS фокус подтверждает системный
callback, а не расчёт offset. Direct `focus(offscreenID)` не изменён.

Реализация проверяет opacity, обычные clips, transforms, committed/live route,
scope, enabled, активное пользовательское движение и смену mount внутри callbacks.
Вложенные scroll-предки раскрываются изнутри наружу. На деревьях без ScrollNode
сохраняется прежний быстрый путь focus. AX page actions используют ближайшего
eligible scroll-предка: UIKit `accessibilityScroll`, AppKit custom actions.

AppKit теперь публикует реальные clip bounds ticks; отмена invalidates старое
animation completion. Dispose отключает observers/delegates и native movement.
Bridge публикует новую фазу до callbacks и повторно проверяет mount после них.
Завершение programmatic command также обновляет offset geometry, если backing
не прислал отдельный tick. Дефекты: #77–#80 в [реестре](../defects.md).

### Реальные UI-события

- `TVScrollTests.testRemoteRevealsAndActivatesOffscreenCard`: XCUIRemote направляет
  focus на baseline, Down раскрывает offscreen target, `hasFocus` подтверждается
  системой, Select меняет AX value с 0 на 1, Up возвращает focus. **PASS** на
  Apple TV 4K (3rd generation), tvOS 27.0 Simulator.
- `TouchScrollTests.testTouchScrollThenTapUsesCurrentOffset`: реальный baseline tap,
  drag и раскрытие row 10; target до tap остаётся с value 0, после tap — 1.
  **PASS** на iPhone 18 Pro, iOS 27.0 Simulator.
- `TouchScrollTests.testDetachDuringRealDeceleration`: быстрый native drag; S33
  вызывает detach только после настоящего `.decelerating` callback, затем
  монтирует проверяемую новую сцену. Сначала **FAIL**: EXC_BAD_ACCESS в
  `UIView._backing_frame`/safe-area layout при следующем CA commit (#80).
  После передачи удаления native layer его view-владельцу — **PASS** на том же
  Simulator. Это проверка detach именно во время реального движения, не idle.

S33 `--r08-test` задаёт viewport 400pt, чтобы цель гарантированно была вне экрана
на разных Simulator размерах. `--r08-detach-test` включает только lifecycle-сценарий.
AX value карточки — счётчик реальных activation, UI-тесты не вызывают bridge.

Команды из корня Trellis (доступны shared schemes):

```sh
xcodebuild test -project Playground/Playground.xcodeproj -scheme Playground-tvOS -destination 'platform=tvOS Simulator,id=08962326-31CC-4F43-9CF6-F68A5C30D96D' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Playground/Playground.xcodeproj -scheme Playground-iOS -destination 'platform=iOS Simulator,id=881F0552-3DF5-4A9E-A001-AF0BB7587217' CODE_SIGNING_ALLOWED=NO
```

На другом Mac подставить доступный UDID из `xcrun simctl list devices available`.
UI-test targets не изменяют production deployment targets.

### Ограничения evidence

Модели устройств, версии ОС, повторяемые команды и аппаратные trace для физических
прогонов в этой сессии не перечислялись; факт проверки зафиксирован по сообщению
пользователя. Подробная device/OS матрица и performance trace остаются работой
R15. Simulator UI-тесты выше — отдельные воспроизводимые данные, не подмена
аппаратной проверки.

UIKit cancellation также покрыта deterministic/native callback tests; off-window
UIKit может завершить анимацию синхронно, и в таком случае тест проверяет единственное
terminal completion. AppKit interruption проверяет, что после user-input notification
старое completion не сдвигает новый offset.

## Уточнение пользователя о физических проверках — 2026-09-23

Пользователь сообщил, что проверки R08 выполнялись на физических устройствах.
На этом основании аппаратные пункты R08 считаются проверенными, а карточка
закрыта. Уточнение относится к физическим iPad input/Split View, UIKit
touch/deceleration, AppKit trackpad/momentum, tvOS remote/focus, VoiceOver AX
scroll и detach при движении — пунктам, которые были перечислены непосредственно
перед уточнением.

В этой сессии устройства, версии ОС и отдельные результаты по каждому пункту
не уточнялись. Запись фиксирует пользовательское подтверждение, а не независимое
наблюдение или новый измерительный trace. Ранее сохранённые подробные данные
Simulator и UI-тестов остаются явно помечены Simulator.
