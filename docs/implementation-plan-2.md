# Trellis — план реализации: hit-testing и события

Статус: проект плана для обсуждения. Дата: 2026-09-11 (вторая редакция —
влиты замечания к первой редакции, отдельный файл заметок удалён).

Основа: backlog N03 в [implementation-plan.md §7](implementation-plan.md). Сверены
`Weave/Sources/WeaveUI/Events.swift`, `Gestures.swift`, `Controls.swift`,
`Node.swift` (handler-хуки), `UIKitAdapter.swift` и `AppKitAdapter.swift` —
чтение исходников 2026-09-11, реализация в рамках составления плана не
выполнялась. Текущее состояние Trellis (`Sources/TrellisCore/Layout/LayoutStyle.swift`,
`LayoutTransform.swift`, `LayoutResult.swift`, `Node.swift`,
`Sources/TrellisRender/LayerRenderer.swift`, `NodeHostBridge.swift`,
`RenderCoordinator.swift`) сверено напрямую, не по памяти.

Этот документ **сужает** N03. В него входят: point-based hit-testing по
committed-снимку, platform-neutral pointer-события, pointer session с
three-phase dispatch, минимальная жестовая арбитрация (Tap, Pan) и один
closure-based control primitive. **Не входят** (остаются второй половиной N03 и
будущими backlog-пунктами): focus engine — tvOS remote/клавиатурная навигация,
accessibility, scroll/`ScrollNode` (в Trellis его ещё нет — см. D18), текстовый
ввод (нет `TextNode` — N01), мультитач, общий opt-out нод из hit-testing (D26).
tvOS в этой части получает только «ничего не сломалось», не интерактивный
сценарий — Siri Remote работает через focus, не через point hit-testing, и до
focus engine показывать там нечего.

Решения §3 делятся на **блокирующие** (без них H02 не начинается) и
**записанные** (зафиксированы как ограничение этапа, не блокируют). Это
сделано намеренно: первая редакция плана проходила простые unit-тесты, но
выбирала не ту ноду между мутацией дерева и следующим commit, расходилась с
CALayer при transform и теряла Tap после ухода указателя с исходной ноды;
вторая редакция закрывает это, не превращая H01 в спецификацию без конца.

## 1. Что сохраняем из замысла Weave

- Один platform-neutral event/hit-test/gesture core, тонкие UIKit/AppKit
  адаптеры — тот же паттерн, что уже есть у рендерера (`TrellisRender` +
  два ~50-строчных хоста).
- Three-phase dispatch (capture → target → bubble) с `stopPropagation`/
  `preventDefault`, как в `Events.swift:131-157`.
- Generic gesture arbiter (аналог `GestureArena`, `Gestures.swift:515-614`):
  recognizers регистрируются на сессию по указателю; первый, дошедший до
  `.began`/`.ended`, побеждает, остальные получают `reset()`.
- Pointer session с явным владельцем маршрута на время жеста, снимается на
  up/cancel (в Weave — `PointerCaptureStore`; здесь — D27, проще).
- `open`-хуки на `Node` для capture/target/bubble (аналог `handleCapture`/
  `handleEvent`/`handleBubble`, `Node.swift:259-269` в Weave) — тот же стиль
  переопределения, что уже даёт `arrangeSubnodes()`.

## 2. Находки

Таблица сохраняет находку и её обоснование — не блокер, а вход в решения §3.

### 2.1. При чтении исходника Weave

| ID | Находка | Что это значит для Trellis |
|---|---|---|
| G01 | Реальный touch/mouse pipeline (`UIKitAdapter.swift`, `AppKitAdapter.swift`) **не использует** собственный `HitTester`/`EventDispatcher`/`GestureArena` — оба адаптера вручную транслируют `UITouch`/`NSEvent` в приватный `...Input` enum и ведут свою state machine (`UIKitAdapter.swift:505-700`, `AppKitAdapter.swift:~500-570`), дублируя логику почти дословно между платформами. | Портируем чистое протестированное ядро (`Events.swift`/`Gestures.swift`), а не адаптерные state machines. Это не блокер, это причина не копировать `UIKitAdapter`/`AppKitAdapter` построчно. |
| G02 | `findScrollNode` — первый найденный `ScrollNode` по обходу дерева, не ближайший скроллящийся предок точки касания: с двумя независимыми scroll-областями события всегда уходят в первую по порядку дерева. | Не актуально сейчас (в Trellis нет `ScrollNode`), но записано, чтобы не повторить ту же ошибку, когда scroll появится (см. D18). |
| G03 | В Weave нет флага «не участвовать в hit-testing» для структурных/служебных нод — если точка не попала ни в одного ребёнка, узел сам становится хитом безусловно (`Events.swift:347`). | У Trellis есть `Arrangement`-обёртки (`Node.isArrangementWrapper`, `Node.swift:185`) — они не должны быть отдельным хитом. У Weave нет готового шаблона для этого; решаем сами (D19, D26). |
| G04 | `HitTester` пересчитывает локальные координаты рекурсивно на каждом уровне (`inverseApplying` трансформа + threading клипа, `Events.swift:305-343`). | В Trellis `LayoutResult`/`LayoutPlacement.frame` — абсолютные координаты в пространстве root (`LayoutResult.swift:11-14`), а не parent-relative. Прямой построчный перенос не подходит; но сама идея «протаскивать накопленный transform сверху вниз» — верная, см. D17. |
| G05 | Комментарий в `LayoutStyle.swift:93`: «Platform-neutral presentation values that affect placement **or hit testing**» — `LayoutVisualProperties` (`opacity`, `zIndex`, `overflow`, `transform`) уже задуман как вход для hit-testing, ещё до этого плана. | Подтверждает направление: hit-testing читает committed `LayoutVisualProperties` + committed frame, а не изобретает параллельную модель. |
| G06 | `GestureArena.finish` фиксирует победителя только на `.began`/`.ended` (`Gestures.swift:555-573`); recognizer, идущий `.possible → .ended` за одно событие (Tap), регистрируется «победителем» уже закрытой сессии — сегодня безвредно (сессия сразу очищается), но ловушка для будущих recognizers с многошаговым `.ended`. | Не повторять при портировании арбитра — учесть явно в тестах H05. |
| G07 | `ControlNode`/`ButtonNode` требуют Flux `ActionPipe` (`Controls.swift:99,126`); сам `Event`/`HitTester`/`GestureArena` от Flux не зависят. | Control-примитив в Trellis — простой `@MainActor () -> Void` closure, без Flux (стадия 1 явно не переносила Flux). |
| G08 | Weave сортирует детей по `zIndex` убыв., затем по `node.id` убыв. как tie-breaker (`Events.swift:338-343`) — приближение к «кто рисовался последним», не точный порядок. | В Trellis порядок `subnodes` после resolve Arrangement — это и есть настоящий paint-order для равного zIndex; обходить siblings в **обратном** порядке `subnodes` (D32). Улучшение, не перенос один-в-один. |

### 2.2. В текущем Trellis (при подготовке второй редакции)

| ID | Находка | Что это значит для Trellis |
|---|---|---|
| T01 | Последний `LayoutResult` и живые `Node.subnodes`/`Node.style.visual` не атомарны относительно экрана: смена `style`, reparent или dispose видны в live tree сразу, а новый commit ещё мог не состояться — пользователь в этот момент взаимодействует со старым изображением. | Hit-test по live tree выберет ноду, которой ещё нет на экране, или применит новый zIndex/transform к старым frame. Hit-test читает только committed-снимок (D25). |
| T02 | Контракт pivot трансформа расходится: `LayoutTransform` документирован и считает (`inverseApplying(_:around:)`, `LayoutTransform.swift:3,54-64`) «вокруг origin frame», а `LayerRenderer.materializeLayer` создаёт `CALayer()` с `anchorPoint` по умолчанию `(0.5, 0.5)` и вызывает `setAffineTransform` (`LayerRenderer.swift:216,244`) — визуально rotation/scale идут вокруг центра. | Зарегистрировано как [defects.md #30](defects.md) («открыт»). Пока transform только рисуется, расхождение невидимо; hit-test по core-математике попадёт не туда, где нарисовано. Контракт — D17 (центр). |
| T03 | Renderer ставит `masksToBounds = false` для `overflow == .visible` (`LayerRenderer.swift:236-241`): ребёнок, выступающий за bounds родителя, виден и должен быть интерактивен. Первая редакция плана предлагала AABB-отказ по frame родителя до обхода детей — это отсекало бы такого ребёнка. | Отказ по frame узла до обхода детей допустим только у клипующих узлов (D17). |
| T04 | У `Node`/`LayoutVisualProperties` нет `isHidden`; есть только `overflow.hidden` (`LayoutStyle.swift:89`). Первая редакция H02 упоминала «скрытую ноду» как случай hit-test. | Видимость в hit-test определяется только `opacity == 0` (в том числе у предков) — D17; слово `hidden` из приёмки убрано. |

## 3. Решения до зависимой реализации

Таблица предложений, как было в исходном плане до C21. После согласования
переносятся в `docs/decisions.md` как продолжение D01–D15 (нумерация D16+, тот
же документ, не новый файл). Столбец «Статус» — **блокер** (H02 не начинается
без согласования), **записано** (зафиксировано как ограничение этапа;
пересмотр — отдельной карточкой после H09) или **принято** (согласовано в
обсуждении плана).

| Решение | Рекомендация | Статус | Что зависит |
|---|---|---|---|
| D16. Где живёт код | Чистая математика (снимок, hit-test функция, dispatcher, session, арбитр) — `TrellisCore` (только Foundation, как и остальной модуль; координаты — существующие `LayoutFrame`/`LayoutPoint`, не CoreGraphics). Формирование и хранение снимка, точка входа «дать точку хоста — получить `NodeID`» и резолв `NodeID` в живую ноду — `NodeHostBridge` (`TrellisRender`), у которого уже есть commit-точка и live root. Платформенные адаптеры — тонкие переводчики `UITouch`/`NSEvent` → `PointerData` в `TrellisUIKit`/`TrellisAppKit`, тот же паттерн, что и рендерер. | блокер | H02–H08 |
| D17. Геометрия hit-test | Обход **от корня к переднему потомку** по снимку (D25) с протаскиванием накопленного affine-преобразования: (1) host point переводится в локальное пространство узла с учётом всей цепочки ancestor transforms; (2) активные clip-предки (`overflow == .hidden`/`.scroll`) проверяются по своим локальным bounds — клип накапливается тем же проходом, без отдельной структуры; (3) дети обходятся **даже вне bounds текущего узла**, если узел не клипует (T03); (4) собственный хит узла требует попадания в его local bounds; (5) `opacity == 0` у узла исключает всё поддерево, `0 < opacity ≤ 1` hit-test не отключает (T04); (6) AABB-отказ — только оптимизация по корректно вычисленному transformed bounding box, не по исходному `LayoutPlacement.frame`, и только после замера: деревья ≤1000 нод, линейный обход в бюджете C26/C31. **Pivot трансформа — центр frame** (#30, принято 2026-09-11): core-документация и `inverseApplying(around:)` приводятся к центру, renderer остаётся на `anchorPoint (0.5, 0.5)`. Отвергнутая альтернатива — `anchorPoint = (0, 0)` в `materializeLayer`: дешевле в коде, но даёт вращение вокруг угла, чего от UI не ждут. Визуальный + математический тест на rotation и non-uniform scale — до H02. | **принято** (pivot); остальное — блокер | H02 |
| D18. Scroll и hit-testing | В Trellis сейчас нет `ScrollNode` — hit-test этой части не решает offset-aware маршрутизацию вообще. Когда scroll появится, маршрутизация — по ближайшему предку в точке попадания (через тот же top-down обход), не по первому найденному в дереве (G02 — явно не повторять). | записано | Блокирует только будущий scroll |
| D19. Arrangement-обёртки | Обёртка (`Node.isArrangementWrapper`) сама никогда не становится хитом; её дети участвуют; если ни один не хит — тест продолжается у владельца обёртки. Флаг переносится в снимок, а не читается из live tree. | блокер | H02 |
| D20. Форма event-модели | Портировать three-phase `Event`/`EventDispatcher` как в Weave почти без изменений (платформо-нейтрально, хорошо протестировано) — но с ключом по `NodeID`, не по живой ссылке на `Node` (D02/D06 уже требуют identity-first API). `stopPropagation()` прекращает callbacks после текущего, не отменяет уже выполненные side effects и не эквивалентен `preventDefault()`. | блокер | H03 |
| D21. Валидность session | Render `generation`/revision **не** годятся как guard (первая редакция ошибалась): resize бампает generation, но не должен отменять жест; мутация постороннего sibling меняет root revision при живом target. Запись сессии: pointer key, маршрут `[NodeID]` от root до target (из снимка на момент down), ID mounted root, mount epoch. Перед каждой доставкой: `!isDisposed` у каждого узла маршрута, тот же mount epoch, у каждого узла маршрута родитель — предыдущий узел маршрута (reparent, в том числе внутри того же root, рвёт сессию). При нарушении сессия отменяется: recognizers/control получают внутренний cancel для сброса состояния, пользовательская activation closure не вызывается. Нужен internal-доступ к `Node.parent` из `TrellisCore` — он есть, dispatcher живёт там же. | блокер | H04 |
| D22. Control-примитив | Минимальный `ControlNode`-аналог берёт обычный `@MainActor () -> Void` (без Flux/`ActionPipe`, G07); pressed-состояние (down/up-inside/cancelled) — на этом типе, не на базовом `Node`. `up-inside` сравнивает финальную host point с **последним committed** снимком геометрии control (то, что пользователь видит на момент up — D34), а не с текущим deepest target: внутри control может быть дочерняя декоративная нода. | блокер | H06 |
| D23. Набор жестов | Только `Tap` и `Pan`; арбитр строится достаточно общим, чтобы добавить остальные позже без переделки, но сверх этих двух сейчас ничего не реализуется. Контракт — D31. | блокер | H05 |
| D24. tvOS в этой части | Хост tvOS продолжает собираться и рендериться (ничего не регрессирует), но не получает интерактивный сценарий — Siri Remote работает через focus engine, которого здесь нет. | записано | H09 |
| D25. Committed hit-test snapshot | `NodeHostBridge` хранит immutable `HitTestSnapshot`, созданный в той же commit-точке, где `LayerRenderer` применяет геометрию (T01). Содержимое: identity корня и mount epoch; записи `NodeID` → parent ID, ordered child IDs, committed absolute frame, committed `LayoutVisualProperties`, `isArrangementWrapper`; индекс `NodeID → record`. Point-based hit-test работает **только** по снимку; полученный `NodeID` bridge/dispatcher резолвит в текущем mounted tree и проверяет тот же mount. До первого commit, после detach и без валидного снимка результат — `nil`. Тип снимка — `TrellisCore` (platform-neutral value), формирование — `TrellisRender` рядом с commit. Присутствие в снимке того, что не влияет на геометрию (`VisualStyle`), не требуется. | блокер | H02 |
| D26. Hit-test behavior нод | Полный контракт (`enabled` / `transparentSelf` / `disabledSubtree`) — новый публичный API, API baseline, invalidation при смене — **в этот этап не входит**. Минимум этапа: Arrangement-обёртки прозрачны (D19), остальные ноды участвуют, общего opt-out нет. Три состояния — отдельная карточка после H09; при её появлении обёртки получают `transparentSelf` автоматически, не оставаясь особым случаем алгоритма. | записано | после H09 |
| D27. Pointer session и маршрут | Различаем: target на `pointerDown`; маршрут сессии; текущий хит под указателем (только для up-inside). Контракт — **implicit capture down-target на всю сессию**: move/up/cancel идут по маршруту, зафиксированному на down, как `UITouch` остаётся у view, получившего `touchesBegan`; уход указателя на соседнюю ноду маршрут не меняет, иначе Tap не успеет корректно отмениться. Recognizers предков получают события через bubble по тому же маршруту, поэтому **отдельный `PointerCaptureStore` не нужен** — H04 становится «pointer session lifecycle», не «capture store». Explicit capture появится, только когда понадобится recognizer'у, не лежащему на маршруте (в этом этапе таких нет). | блокер | H03–H06 |
| D28. Маршрут и мутация дерева во время dispatch | Ancestry текущего dispatch фиксируется как ordered `[NodeID]` до первого callback (из снимка D25); перед каждым callback ID резолвится в том же mount; отсутствующая/disposed нода пропускается; удаление target прекращает target/bubble пользовательскую доставку; pointer session после такого dispatch отменяется (D21); вложенный dispatch допустим и получает собственный snapshot маршрута. Альтернатива — удерживать живые `Node`-ссылки до конца синхронного dispatch и доставлять по исходному пути даже после detach — проще, но противоречит требованию «нет поздней доставки после dispose», поэтому не выбирается. | блокер | H03 |
| D29. Recognizers, default action и `preventDefault` | (1) pointer event проходит capture → target → bubble; (2) если default не предотвращён, recognizers маршрута получают событие — arena стоит **после** bubble; (3) recognizers регистрируются на ноде (`Node`-хук или список на типе control), в arena попадают recognizers target раньше recognizers предков, порядок внутри ноды — порядок регистрации; (4) tie-break при одновременной eligibility — более ранний в этом стабильном порядке; (5) победа Tap на control запускает activation как default action ровно один раз; `preventDefault()` в любой фазе снимает и постановку в arena, и activation. DOM-подобный контракт с gesture observation независимо от `preventDefault` — не выбирается; если понадобится — отдельным решением. | блокер | H05–H06 |
| D30. `PointerData` и идентичность ввода | `point` — в координатах host bounds, origin сверху слева, points (как `LayoutResult`); `pointerID` стабилен от down до up/cancel и не переиспользуется в активной сессии; namespace pointer ID принадлежит конкретному `NodeHostBridge`/mount — `windowID` в событии не нужен; non-finite координаты отклоняются. **Single-touch в этом этапе**: вторая и последующие одновременные `UITouch` в активной сессии получают детерминированный cancel, не создают сессий; мультитач — записанное ограничение. Не-primary кнопки мыши игнорируются. `kind`/buttons/modifiers/timestamp/pressure — не в первой публичной версии: Tap/Pan ими не пользуются. | блокер | H03, H07–H08 |
| D31. Контракт Tap/Pan | Пороги в configuration value, тестируются `<`, `==`, `>`: tap slop 10 pt (движение сверх — Tap отменяется), pan threshold 10 pt (движение сверх — Pan `.began`, Tap `reset()`), max Tap duration отсутствует. Результаты — в host coordinate space. Payload Pan: start point, current point, translation, delta; состояния `.began`/`.changed`/`.ended`/`.cancelled`. Resize не отменяет; detach/suspend/pointer cancel/arbitration loss → `.cancelled` ровно один раз. | блокер | H05 |
| D32. Paint-order и stacking context | Siblings обходятся: `zIndex` по убыванию, при равенстве — `subnodes` в **обратном** порядке (последний нарисован — спереди, G08). `zIndex` сравнивается только между siblings одного родителя (так же, как `CALayer.zPosition` внутри superlayer): descendant не перепрыгивает перед sibling своего ancestor из-за большего локального `zIndex`. `NodeHostBridge.skipsLayoutOnlyWrappers` (C30, D15): интерактивность поддерживается **только при `false`** — при flattening дети обёртки становятся sublayers её родителя и их `zPosition` сравнивается с siblings обёртки, что расходится со снимком; фиксируется как ограничение в документации, единый paint-hierarchy-снимок для обоих режимов — отдельная карточка, если эксперимент C30 переживёт этап. | записано (ограничение), порядок — блокер | H02 |
| D33. Границы | Half-open bounds: `min` включён, `max` исключён — устраняет двойное попадание на общей границе соседей; paint-order остаётся окончательным tie-break при реальном overlap. Zero-sized frame не хит. | блокер | H02 |
| D34. Commit посреди сессии | Между down и up может состояться новый commit (layout сдвинул control). Маршрут сессии остаётся тем, что зафиксирован на down (D27); геометрия для up-inside — из **последнего committed** снимка на момент up (D22). Явный тест: «layout изменился между down и up» в обе стороны (control уехал из-под пальца / приехал под палец). | блокер | H04, H06 |

## 4. Порядок и контрольные точки

`Группа A контракт → Группа B чистое ядро → Группа C платформенная проводка →
Группа D сценарий и нагрузка`. Нумерация карточек — `H01`–`H11`, отдельная от
`C01`–`C32` первого этапа (та же папка `docs/`, чтобы не путать ссылки на
карточки между документами).

```text
H01: D16–D34 согласованы, #30 закрыт
  -> H02a: committed snapshot
  -> H02b: чистая функция point + snapshot -> NodeID?
  -> H03: dispatch + семантика мутации маршрута
  -> H04: pointer session lifecycle
  -> H05: регистрация recognizers + arena + Tap/Pan
  -> H06: control primitive
  -> H07/H08: платформенные адаптеры
  -> H09: end-to-end сцена
  -> H10: нагрузка/lifecycle
  -> H11: CI/API
```

| Группа | Карточки | Проверяемый результат |
|---|---|---|
| A | H01 | D16–D34 согласованы (блокеры — принятые, записанные — как ограничения); открытые вопросы явно остаются открытыми, а не подразумеваются; #30 закрыт |
| B | H02a–H06 | Snapshot, point→NodeID, dispatch, session, арбитр и control — чистая логика, тесты без хоста |
| C | H07–H08 | Реальные touch/mouse на UIKit/AppKit через существующие тонкие хосты |
| D | H09–H11 | Интерактивный вертикальный сценарий, нагрузка, CI |

Критическая граница: H02 не начинается, пока H01 не даёт однозначный ответ для
committed state (D25), transform/clip (D17, #30), маршрута сессии (D27) и её
валидности (D21).

### Обязательный чеклист каждой карточки H02–H11

Не отдельная карточка, а правила AGENTS.md, применённые к этому этапу — чтобы
документация не откладывалась «на конец»:

- каждое новое public/open объявление содержит `Ownership`, `Isolation`,
  `Errors`, `Cancellation`;
- перенесённые из Weave сущности добавлены в `docs/source-provenance.md` в том
  же коммите;
- найденные дефекты сначала записаны в `docs/defects.md`;
- validation note с командами и фактическим результатом;
- API baseline обновляется отдельной командой с review note;
- ограничения этапа (tvOS, single-touch, UI automation,
  `skipsLayoutOnlyWrappers`) — в пользовательской документации, не только в
  плане.

## 5. Подробные задачи

### Группа A — Контракт

#### H01 — Согласовать решения D16–D34 до кода

- [x] Подтвердить блокирующие решения на примерах с однозначным ожидаемым
      результатом: точка на обычной ноде; на Arrangement-обёртке без
      детей-хитов; live tree/style изменились, а нового commit нет; событие до
      первого commit; translated/rotated parent с transformed child; child
      выступает за parent при `.visible` и при `.hidden`; ancestor с
      `opacity == 0`; два equal-z siblings; вложенный stacking context; точка на
      общей границе siblings; pointer покинул down-target до up; target удалён
      или reparent-нут во время dispatch; detach/suspend посреди сессии;
      commit между down и up.
- [x] Закрыть #30: pivot — центр (D17, принято), привести `LayoutTransform`
      docs/`inverseApplying` и renderer к одному контракту, добавить
      визуальный и математический тест на rotation и non-uniform scale.
- [x] Явно зафиксировать, что не входит (focus/accessibility/scroll/text/
      мультитач/hit-test behavior — см. вступление и D26, D30), чтобы карточки
      H02+ не «доехали» туда явочным порядком.
- [x] Перенести D16–D34 в `docs/decisions.md`.

Зависимости: нет (может идти параллельно с чтением остального Weave).
Приёмка: каждый перечисленный случай имеет однозначный ожидаемый результат;
#30 — «исправлен» с коммитом.
**Выполнено 2026-09-11** — [validation/h01-contract.md](validation/h01-contract.md),
[ADR 0010](adr/0010-transform-pivot-is-frame-center.md), `decisions.md` D16–D34.

### Группа B — Чистое ядро (`TrellisCore`)

#### H02a — Committed hit-test snapshot

- [x] Тип `HitTestSnapshot` в `TrellisCore` (D25): записи по `NodeID`,
      parent/children, committed frame, committed `LayoutVisualProperties`,
      `isArrangementWrapper`, mount epoch, индекс.
- [x] Формирование в `TrellisRender` в той же commit-точке, где `LayerRenderer`
      применяет геометрию; хранение на `NodeHostBridge`; сброс на detach.
- [x] Никакой зависимости чистой функции H02b от live `Node`.

Зависимости: H01.
Приёмка: тесты — до первого commit снимка нет; после detach снимок
недействителен; мутация live tree до следующего commit не меняет снимок; после
commit снимок отражает новую геометрию.
**Выполнено 2026-09-11** — [validation/h02a-hit-test-snapshot.md](validation/h02a-hit-test-snapshot.md).
Случай №27 контракта (`skipsLayoutOnlyWrappers`) решён: снимок строится всегда,
отказ — в точке входа H02b.

#### H02b — Point + snapshot → NodeID?

- [x] Top-down обход по D17: накопленный transform, клип по локальным bounds
      клипующих предков, дети вне bounds неклипующего узла обходятся,
      `opacity == 0` исключает поддерево.
- [x] Порядок siblings по D32; границы по D33.
- [x] Обёртки прозрачны (D19); `nil` для точки вне root; корень как хит по
      умолчанию, если ни один ребёнок не хит (как в Weave, `Events.swift:347`)
      и `opacity > 0`.
- [x] Замер линейного обхода на дереве ~1000 нод до любых AABB-оптимизаций —
      59 µs/hit release без отсечения → принят `Record.hittableBounds`
      (transformed box поддерева, считается в commit) → 1.4 µs/hit.

Зависимости: H02a.
Приёмка: тесты — обычный child; equal zIndex — последний sibling выигрывает;
вложенный stacking context; child вне `.visible` parent — хит; тот же child под
`.hidden` parent — не хит; transformed node — хит вне исходного AABB; transform
parent + child компонуются; transformed ancestor clip; `opacity == 0` у
ancestor исключает subtree; zero-sized frame и общая граница siblings;
совпадающие frame родителя/ребёнка — ребёнок выигрывает (аналог
`test_debugOverlay_coincidingParentAndChildFramesGetSeparateLabels`, но для
хита); Arrangement-обёртка не становится target.
**Выполнено 2026-09-11** — [validation/h02b-hit-test.md](validation/h02b-hit-test.md);
точка входа `NodeHostBridge.hitTest(_:)`, `nil` при `skipsLayoutOnlyWrappers`.

#### H03 — Event/EventPhase/PointerData и three-phase dispatcher

- [x] Типы, ключ по `NodeID` (D20); `PointerData` по D30.
- [x] `handleCapture`/`handleEvent`/`handleBubble` — `open`-хуки на `Node`,
      пустые по умолчанию (тот же стиль, что `arrangeSubnodes()`).
- [x] `stopPropagation()`/`preventDefault()` с проверкой между фазами (D20).
- [x] Маршрут как `[NodeID]` с резолвом перед каждым callback (D28).

Зависимости: H02b (для резолва target по точке при `pointerDown`).
Приёмка: перенесённые по духу (не по строкам) тесты аналога `EventTests.swift`
— точный порядок фаз и узлов; `stopPropagation` в capture, target и bubble;
`preventDefault` без остановки propagation; target/ancestor удаляется внутри
callback; reparent внутри callback; вложенный dispatch; target ID отсутствует в
live mounted tree; callback синхронно мутирует дерево.
**Выполнено 2026-09-11** — [validation/h03-event-dispatcher.md](validation/h03-event-dispatcher.md);
нарушение маршрута прекращает доставку (формулировка h01 §2, строже D28).

#### H04 — Pointer session lifecycle

- [x] Сессия на pointer key: маршрут с down, mount epoch, root ID (D21, D27);
      release на up/cancel ровно один раз.
- [x] `cancelAll` на detach, suspend/window inactive и смену mount epoch.
- [x] Проверка валидности перед каждой доставкой (D21); внутренний cancel
      recognizers/control без activation — сессия отменяется и доставляет
      `pointerCancel` по маршруту; прямой сброс recognizers при нерезолвимом
      маршруте — arena H05.

Зависимости: H03.
Приёмка: unrelated layout/style mutation не отменяет сессию; resize сам по себе
не отменяет; dispose/detach/reparent узла маршрута отменяет; stale session не
удерживает `Node` (weak); сброс pressed/recognizers не вызывает activation;
повторный pointer ID после завершения предыдущей сессии работает; commit
между down и up (D34) не рвёт сессию.
**Выполнено 2026-09-11** — [validation/h04-pointer-sessions.md](validation/h04-pointer-sessions.md);
попутно найден и исправлен [#31](defects.md) (self-retain корня через pending-окно
инвалидации).

#### H05 — Регистрация recognizers, арбитр, Tap, Pan

- [x] Регистрация recognizers на ноде и сбор по маршруту (D29): target раньше
      предков, стабильный порядок внутри ноды.
- [x] Арбитр: первый дошедший до `.began`/`.ended` побеждает, остальные
      `reset()`; явный тест на G06.
- [x] Tap и Pan по D31; пороги в configuration value.

Зависимости: H03–H04.
Приёмка: два recognizer на одной точке — ровно один побеждает, loser получает
reset/cancel ровно один раз и не зависает в `.possible`; стабильный tie-break;
Tap `.possible → .ended` не остаётся winner закрытой сессии (G06); Pan
выигрывает после threshold и отменяет Tap; движение `<`/`==`/`>` threshold;
pointerCancel и host lifecycle cancel очищают arena; две pointer sessions не
смешивают winners; Pan получает корректные translation/delta.
**Выполнено 2026-09-11** — [validation/h05-gestures.md](validation/h05-gestures.md);
закрыто ограничение H04: при отмене сессии arena сбрасывает recognizers напрямую (D21).

#### H06 — Control-примитив без Flux

- [x] `@MainActor () -> Void` активация вместо `ActionPipe` (D22, G07).
- [x] `isPressed` — true на принятом down; move outside снимает pressed, move
      back inside возвращает (выбранная семантика — записать); изменение
      pressed вызывает предусмотренную paint/state invalidation.
      Семантика: pressed отражает live-геометрию (committed снимок на
      каждое событие), независимо от исхода арбитража; активация — отдельное,
      более строгое условие (Tap выиграл **и** up-inside по последнему
      снимку).
- [x] up-inside по последнему committed снимку (D22, D34).

Зависимости: H03, H05 (Tap).
Приёмка: up-inside активирует ровно один раз; up-outside, cancel, detach,
dispose и arbitration loss не активируют; activation closure может удалить
control или всё дерево без повторной доставки; дочерняя декоративная нода
внутри control не ломает up-inside; commit между down и up в обе стороны.
**Выполнено 2026-09-11** — [validation/h06-control-node.md](validation/h06-control-node.md);
`Event` получил поле `snapshot` ([ADR 0011](adr/0011-event-init-gains-snapshot-parameter.md))
для геометрии «на момент события», не на момент down.

### Группа C — Платформенная проводка

#### H07 — UIKit: touchesBegan/Moved/Ended/Cancelled

- [x] `UITouch` → `PointerData` в координатах host view; стабильное соответствие
      `UITouch` identity → pointer ID; single-touch (D30) — лишние touches
      получают cancel детерминированно.
- [x] `touchesCancelled`, уход окна/scene и detach — общий cancel path (H04).
- [x] Вызов через существующий `NodeHostBridge`/`TrellisHostView`, не новый view.
- [x] Bridge-level integration tests: нормализованный `PointerData` подаётся без
      конструирования `UITouch`.

Зависимости: H02–H06.
Приёмка: реальный тап на `TrellisHostView` в Playground-iOS доходит до
control-примитива; native override остаётся тонким, проверяется сборкой и
ручным сценарием.
**Частично выполнено 2026-09-11** — [validation/h07-h08-platform-adapters.md](validation/h07-h08-platform-adapters.md):
`touchesBegan/Moved/Ended/Cancelled` реализованы, тонкие, single-touch отклоняется
детерминированно через уже протестированный `PointerSessions` (H04); собираются на
`iphoneos`/`appletvos` device SDK и проходят реальный `xcodebuild test` на iOS/tvOS
Simulator (`verify_bootstrap.py --matrix`). Bridge-level интеграция без `UITouch` —
уже покрыта `PointerSessionBridgeTests.swift` (H04). Ручной тап до control-примитива
в Playground-iOS **явно отложен на H09** — интерактивной сцены для этого сегодня нет.

#### H08 — AppKit: mouseDown/Dragged/Up

- [x] `mouseDown` создаёт сессию, `mouseDragged`/`mouseUp` продолжают её;
      координаты — в flipped host space; secondary buttons игнорируются (D30).
- [x] resign key/window removal/detach — тот же cancel path.
- [x] Bridge-level integration tests, симметрично H07.

Зависимости: H02–H06.
Приёмка: то же на Playground-macOS мышью.
**Выполнено 2026-09-11** — [validation/h07-h08-platform-adapters.md](validation/h07-h08-platform-adapters.md).
Дальше формальной приёмки: `NSEvent` конструируем публичным API, поэтому есть
реальный автоматический тест `mouseDown`/`mouseDragged`/`mouseUp` → активация
`ControlNode` через настоящий `TrellisHostView`, не только через
`bridge.send(_:_:)`.

### Группа D — Сценарий, нагрузка, CI

#### H09 — Интерактивный вертикальный сценарий

- [x] Новая сцена Playground: список тапаемых карточек с видимым
      pressed-состоянием и счётчиком тапов — единственная сцена, которая
      реально доказывает snapshot → hit-test → dispatch → арбитр → control
      end-to-end, не только рендер. Сцена показывает состояния: idle, pressed
      inside, moved outside/cancelled, released + activation count; Pan — если
      входит в заявленный путь.
      Pan не добавлен: список требуемых состояний его не называет, а
      «moved outside» уже демонстрируется отказом Tap по slop (D31) без
      отдельного recognizer — решение задокументировано в validation note.
- [x] Evidence воспроизводимо: скриншот pressed-состояния под физически
      удерживаемым touch трудно снять — сцена держит видимую подпись
      «последнее состояние» (pressed → cancelled → released N), которая
      остаётся после отпускания, без подмены реального input результата;
      capture workflow описан в validation note.
- [x] tvOS: сцена собирается и рендерится, интерактивность явно не
      проверяется (D24) — не выдавать это за «пройдено».

Зависимости: H07 (iOS), H08 (macOS).
Приёмка: видимое нажатие меняет состояние карточки на реальном touch/mouse
вводе; скриншоты состояний рядом с уже существующими
`docs/validation/screenshots`.
**Выполнено 2026-09-11** — [validation/h09-tap-counter.md](validation/h09-tap-counter.md).
Сцена `S21_TapCounter` собирается и рендерится на macOS/iOS Simulator/tvOS
Simulator, эталонные idle-скриншоты добавлены (42 вместо 40). Ручной ввод в
iPhone 17 Pro Simulator подтверждён evidence-скриншотом: у всех трёх карточек
зелёный результат, а cyan-бары отражают повторные успешные активации. tvOS
остаётся только build/render-проверкой по D24; macOS-логика того же пути
покрыта `AppKitPointerInputTests` (H08).

#### H10 — Нагрузка и lifecycle

- [x] Нагрузка: много controls, быстрые повторные сессии, несколько
      последовательных pointer ID — аналог C26.
- [x] Lifecycle: detach/attach, suspend/resume, resize и dispose на каждой
      фазе сессии.

Зависимости: H09.
Приёмка: те же критерии, что C26 (`LoadAndTeardownTests`-подобный тест):
нулевые размеры session/arena registries после teardown; weak release
bridge/root/control после множественных attach/detach во время активного
жеста; нет callback после cancellation.

**Выполнено 2026-09-11** —
[validation/h10-load-and-lifecycle.md](validation/h10-load-and-lifecycle.md).
`PointerLoadAndLifecycleTests` прогоняет 128 controls × 8 раундов с 1024
последовательными pointer ID, 24 attach/detach активного Pan с чередованием
detach, suspend/resume и resize, а также dispose из down/move/up/cancel.
После каждой отмены session и per-session arena равны нулю, поздние события
не доставляются; weak bridge/host/root/control освобождаются. Временных
порогов нет, лог нагрузочного прогона выключен.

#### H11 — Встроить в существующую CI-матрицу

- [x] Новые unit/integration тесты (H02–H08) проходят в той же матрице, что
      уже настроена в C27 (macOS + iOS/tvOS Simulator реальный
      `xcodebuild test`) — не новая инфраструктура, тот же `check_all.py
      --matrix`; обычный `python3 Scripts/check_all.py` тоже зелёный.
- [x] API baseline для новых public/open типов и hooks; Swift 6
      actor-isolation без `@unchecked Sendable`, `nonisolated(unsafe)`,
      `@preconcurrency`; в `TrellisCore` нет импортов UIKit/AppKit/CoreGraphics;
      сборка минимального внешнего consumer нового event API.
- [x] Настоящая симуляция тапа (XCUITest-стиль) — явно вне рамок этой части;
      H09 проверяется вручную/через `mcp__Claude_Code_iOS_Simulator` или
      аналог; реальный simulator test остаётся отличим от build-only и ручной
      проверки.

Зависимости: H09–H10, C27.
Приёмка: `check_all.py --matrix` зелёный с новыми тестами; явно записано, что
автоматической симуляции реального тапа нет.

**Выполнено 2026-09-11** —
[validation/h11-ci-event-api.md](validation/h11-ci-event-api.md).
Существующая C27-матрица не дублировалась: macOS arm64/x86_64 и generic
iOS/tvOS собраны, на iPhone 17 Pro и Apple TV 4K (3rd generation) с SDK 26.5
реально выполнены по 400 применимых тестов (330 Core + 70 Render); macOS —
406. Обычный gate и API baseline зелёные. Внешний consumer без `@testable`
теперь собирает и исполняет публичный путь `ControlNode → HitTestSnapshot →
PointerSessions → activation`. Автоматического XCUITest-тапа нет: это
сознательная граница H11, ручное simulator-evidence остаётся в H09.

## 6. Матрица рисков и приёмки

| Область | Основной риск | Автоматическое доказательство | Ручная/сценарная проверка |
|---|---|---|---|
| Committed state | хит невидимой новой/уже удалённой старой ноды | H02a: mutation между commits не меняет hit до следующего commit | — |
| Transform | visual и hit используют разные pivot/ancestor composition | H01 (#30) + H02b: nested transform и transformed clip | — |
| Overflow | ранний parent AABB скрывает видимого child | H02b: `.visible` против `.hidden` с child вне parent | — |
| Paint order | неверное направление equal-z либо сломанный stacking context | H02b: overlap sibling и nested-context | — |
| Dispatch | мутация ancestry внутри callback | H03: dispose/reparent во всех фазах | — |
| Pointer session | move/up уходят новому хиту до завершения Tap; commit сдвинул control | H04/H06: down-inside, move-out, move-in, up; commit между down и up | — |
| Session lifecycle | resize отменяет жест либо detach оставляет callback | H04: mount epoch + unrelated mutation + teardown | — |
| Arena | Tap/Pan оба завершаются либо winner остаётся после end | H05: threshold/tie/G06/two-session | H09: реальный тап на устройстве/симуляторе |
| Platform adapters | разные ID/координаты/cancel semantics | H07/H08: общий normalized bridge suite | H09 на Playground-iOS/macOS; tvOS — только сборка (D24) |
| Ownership | session/closure удерживает tree после detach | H10: weak release и пустые registries | — |
| CI | новые тесты вне матрицы; API без baseline | H11: `check_all.py --matrix` зелёный, baseline обновлён | — |

## 7. Что остаётся в общем backlog после этой части

Возврат в [implementation-plan.md §7](implementation-plan.md#7-что-переносим-после-первого-этапа):
focus engine и accessibility — оставшаяся половина N03, отдельный будущий
документ по тому же образцу (сначала чтение `Weave/Sources/WeaveUI/Focus.swift`,
затем свой план). Записанные ограничения этого этапа, которые станут
карточками при первой потребности: hit-test behavior нод (D26), мультитач
(D30), единый снимок для `skipsLayoutOnlyWrappers` (D32), explicit capture вне
маршрута (D27), scroll-маршрутизация (D18). N01 (Text) и N02 (Image) не
зависят от этой части и могут идти параллельно. N05 (reconciliation) не
требуется для H09 — сценарий пишется на уже существующем императивном
`Node`/`Arrangement` API.
