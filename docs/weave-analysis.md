# Weave → Trellis: анализ источника и матрица переноса

> **Этап 1 реализован** (C01–C32, [implementation-plan.md](implementation-plan.md)); этот документ — исторический анализ источника, написанный до и во время реализации, а не описание текущего состояния. Принятые контракты: [decisions.md](decisions.md); что реально в коде — `Sources/`, `api/*.json` (снятый public API baseline) и evidence в `docs/validation/`. Синхронизирован с поправками F01–F15. Примеры API ниже — проектные эскизы того времени, часть из них изменилась при реализации (см. ADR в `docs/adr/` и отчёты карточек); прежние оценки строк никогда не были ограничениями.

Документ описывает перенос кодовой базы `Weave` в новый плагин **Trellis**.
Это не «Weave 2.0» и не рефакторинг существующего пакета — это новый продукт,
который забирает из Weave только то, что реально работает и реально нужно для
построения дерева нод, и оставляет позади всё, что накопилось «на будущее».

Документ грунтован на чтении исходников `/Users/resoul/projects/v2/Weave`
(2026-09-10), а не на пересказе черновика `docs/history/weave-2.0-draft.md`. Там, где
черновик расходится с кодом, это отмечено явно в разделе 2.

---

## 0. Цель этапа 1 и критерий готовности

### Что должно получиться

Одно предложение: **на реальных устройствах (iPhone, iPad, Apple TV, Mac) видна
корневая нода, внутрь неё можно добавлять другие ноды, и они раскладываются по
экрану по правилам flex — а в консоли Xcode виден полный след того, как это
произошло.**

Ноды и раскладка — предмет этапа. Адаптер — только транспорт до экрана, и
делается настолько маленьким, насколько это возможно (раздел 7).

### Definition of Done для этапа 1

| # | Критерий | Как проверяется |
|---|---|---|
| 1 | `swift build` и `swift test` зелёные на Mac | локально + CI |
| 2 | `python3 Scripts/check_all.py` зелёный | локально + CI |
| 3 | `Playground` запускается на **физических** iPhone, iPad, Apple TV и на Mac | Xcode, 4 устройства |
| 4 | На экране видна корневая нода с фоном — на всех четырёх | глазами |
| 5 | Вложенные ноды (минимум 3 уровня) раскладываются по flex-правилам | глазами + лог |
| 5а | Подкласс `Node` описывает раскладку детей через `arrangeSubnodes()` (5.2) — императивная и декларативная формы дают одинаковый результат | глазами + тест |
| 6 | `flexDirection`, `justifyContent`, `alignItems`, `gap`, `padding`, `margin`, `flexGrow`, `width/height` (points/fraction/auto), `positionType = .absolute` — каждое проверено вручную | чек-лист сценариев, раздел 7 |
| 7 | Одинаковые snapshots и bounds/scale/insets/direction дают одинаковую геометрию на четырёх платформах; реальные размеры устройств проверяются отдельно | сравнение по semantic paths, без runtime NodeID |
| 8 | В консоли для каждого кадра виден полный след: invalidate → snapshot → measure → place → commit → CALayer | Xcode console |
| 9 | Для каждой ноды в логе видно: id, родитель, constraint, измеренный размер, финальный frame | Xcode console |
| 10 | `trellis-public-api.json` заполнен и стабилен | `check_api.py` |

### Чего в этапе 1 нет

Text, Image, Button, Control, Scroll, Collections, Gestures, Events/HitTest,
Animation, Focus, Accessibility, Navigation, Coordinator, DeepLink, Video,
Forms, Theme-подписки, Networking, Storage, Analytics, Syntax и платформенные
фабрики контент-нод. Лимита в 105 строк для хостов нет: ownership/lifecycle
должны быть корректны независимо от размера файла.
Всё это — отдельные задания после того, как Node+Layout стабилен на железе.
Минимальный реактивный путь уже входит в первый этап (C29), полноценный
state/Flux framework — позже. Первая картинка появляется раньше завершения
этапа: минимальные приёмки C05–C20, один UIKit-host, S01/S10, одно устройство.
Полная таблица выше относится к завершению этапа, а не к первому запуску.

---

## 1. Карта того, что реально есть в Weave

Прежде чем решать «что брать», зафиксируем реальную структуру. Пакет — 21.5k
строк Swift в 12 таргетах.

### Цепочка, которая реально доводит ноду до экрана

```
Node.addSubnode / .style { }
  └─ Node.setNeedsLayout()               Sources/WeaveUI/Node.swift
       └─ рекурсивно вверх до root, root.onInvalidate?(self)
            └─ UIKitHostView.attach замкнул этот колбэк   Sources/UIKitAdapter/UIKitAdapter.swift
                 └─ RenderCoordinator.invalidate(root:bounds:scale:)  Sources/WeaveAdapters/RenderCoordinator.swift
                      ├─ root.makeLayoutInputSnapshot()   ← Sendable-снимок всего дерева
                      └─ LayoutEngine.request(...)        Sources/WeaveUI/LayoutEngine.swift
                           └─ Task.detached
                                └─ FlexSolver.layoutContainer(...)  Sources/WeaveUI/LayoutResult.swift
                                     ├─ measureContainer(...)       Sources/WeaveUI/FlexSolver.swift
                                     └─ → LayoutResult (плоский массив LayoutPlacement)
                                          └─ await commit → generation guard
                                               └─ RenderCoordinator.handleLayoutResult
                                                    ├─ ревизионные guard'ы (stale → retry)
                                                    ├─ root.applyRecursively(result)   ← calculatedFrame
                                                    └─ onCommitGeometry
                                                         └─ UIKitLayerRenderer.applyCommitted
                                                              └─ CATransaction { update(node:) рекурсивно }
                                                                   ├─ CALayer bounds/position (относительно родителя)
                                                                   ├─ applyVisualStyle(...)  Sources/WeaveAdapters/VisualStyleRenderer.swift
                                                                   └─ addSublayer / удаление stale-слоёв
```

**Эта цепочка рабочая и её надо перенести целиком.** Она — костяк Trellis.

### Что находится рядом, но в этой цепочке не участвует

- `LayoutSpec.swift` (205 строк) — **мёртвый код**. Проверено: во всём
  `Sources/` на него нет ни одной ссылки, единственный потребитель —
  `Tests/WeaveBootstrapTests/LayoutSpecTests.swift`. Умеет только `measure`,
  не позиционирует, с живыми `Node` не связан.
- `protocol NodeBacking: AnyObject {}` в конце `Node.swift` — пустой,
  **internal** (не public), поле `backing` всегда `nil`, `isLoaded` всегда
  `false`. Мост до платформы идёт не через него, а через
  `UIKitLayerRenderer` + словарь `[ElementID: CALayer]`.
- `NodeState` / `ActionPipe` (`NodeState.swift`) — не участвуют в layout.
- `Logging` — отдельный таргет с actor-based `FileSink`/`ConsoleSink` и
  async API (`await logDebug(...)`). В layout/render пути **не используется
  вообще: там нет ни одного лога**.

---

## 2. Поправки к черновику `docs/history/weave-2.0-draft.md`

Черновик писался частично по памяти и частично по кускам файлов. Перед тем
как класть его пункты в план, каждый проверен по коду. Ниже — расхождения.
Это важно: два из трёх «блокеров» черновика в код не подтверждаются, а
настоящие проблемы там не названы.

### 2.1 Ссылки на файлы устарели

| В черновике | В реальности |
|---|---|
| «`Transfer.swift` / `Reconciler`» | `Reconciler` живёт в `Sources/WeaveUI/Reconciliation.swift` |
| «`Transfer.swift` / `ForEach`» | `ForEach` живёт в `Sources/WeaveUI/NodeBuilder.swift` |
| `Transfer.swift` | это **drag & drop** (`TransferSession`, `TransferCoordinator`), к реконсиляции отношения не имеет |
| «второй присланный сниппет (`NodeState` actor)» | `Sources/WeaveUI/NodeState.swift`, 82 строки |

### 2.2 §1.1 «Reconciler.diff — некорректные индексы в remove-патчах [БЛОКЕР]» — **не подтверждается**

Алгоритм `Reconciler.diff` был портирован на Python и прогнан брутфорсом:
**600 000 случайных пар `old`/`new`** (длины 0–6, типы из набора, ключи
`nil`/`k1`/`k2`/`k3`, включая дубликаты ключей в `old` и в `new`). Результат:

```
reject (невалидный индекс) = 0
wrong  (неверная форма)    = 0
```

Причина, по которой хвостовой remove-проход всё-таки корректен: он снимает
элементы **с конца, по убыванию**, а `working` к этому моменту синхронен с
живым массивом (основной цикл эмитит патчи в порядке применения). Удаление
последнего элемента N раз подряд даёт правильные индексы.

Конкретный пример из черновика (`old=[A,B,C]`, `new=[B]`, без ключей) даёт:

```
patches  = [replace(0, B), remove(2), remove(1)]
applied  = [B]                                    ← форма верная
```

**Настоящий дефект в этом месте — другой: потеря идентичности.**
Позиционное сопоставление сравнивает только `descriptor.key == nil` и индекс,
не сравнивая `typeName`. Поэтому живая нода `A` уничтожается и на её месте
создаётся новая `B` (`.replace`), а **уже существующая живая нода `B`
удаляется** патчем `remove(1)`. Вместо «удалить A, удалить C, оставить B»
получается «уничтожить 2 ноды, создать 1». Для будущих потребителей reconciliation это важно: при таком
сопоставлении пересоздаются связанные ноды и слои. В первый этап
descriptor reconciliation не входит.

**Что делать при будущем переносе reconciliation:** сначала определить
контракт identity. Проверка typeName предотвращает reuse другого типа,
но сама по себе не сохраняет B при `[A,B,C] → [B]`: позиция B изменилась.
Для такого сохранения нужны устойчивые ключи или другой алгоритм matching.
Позиционная identity может быть осознанной семантикой, а не багом.
Разовый брутфорс выше — свидетельство исходного анализа; его нужно сделать
воспроизводимым тестом с seed при этапе reconciliation, не в первом этапе.

### 2.3 §1.2 «потеря первого дубликата ключа» — баг реальный, предложенный фикс спорный

Код действительно no-op:

```swift
if oldByKey.updateValue(index, forKey: key) != nil {   // уже перезаписал
    duplicateKeys.append(key)
    oldByKey[key] = oldByKey[key].map { min($0, index) }   // min(new, new) = new
}
```

Но предложенное «чинить на `min`, то есть побеждает первое вхождение» —
не улучшение. Проверенный случай:

```
old = [(A,"k1"), (B,"k1"), (C,nil)]      new = [(B,"k1")]
текущее поведение (побеждает последнее): move(1→0), remove(2), remove(1)  ← живая B сохранена
после «фикса» (побеждает первое):        replace(0,B), remove(2), remove(1) ← живая B уничтожена
```

**Что делать в Trellis:** дубликаты ключей — это ошибка потребителя API, а не
случай, который надо «правильно разрулить». Правильная политика:
дубликат ключа → ключ **целиком выводится из сопоставления** (обе ноды идут
по позиционному пути), плюс строка в лог, плюс запись в
`diagnostics`. Никаких `min`/`max` — они выбирают между двумя одинаково
неправильными вариантами.

### 2.4 §1.4 `NodeState` reentrancy — вне scope этапа 1

`NodeState` в layout-пути не участвует. Замечание про два suspension point'а
в `set` формально верно, но переносить `NodeState` в этап 1 не нужно вообще
(раздел 4). Вопрос переезжает вместе с ним в этап, где появится state.

### 2.5 §1.7 / §3 `NodeBacking` — подтверждается, и решение проще, чем в черновике

Черновик предлагает большой `@MainActor protocol NodeBacking` с
`mount/unmount/syncFrame/syncAppearance/syncAccessibility/teardown` и
`NodeBackingFactory`. Для этапа 1 это преждевременно: в Weave **все ноды
получают одинаковый голый `CALayer`** (`UIKitLayerRenderer.makeLayer` буквально
делает `_ = node; let layer = CALayer()`), никакой полиморфизм backing'а не
используется.

**Что делать в Trellis:** пустой `protocol NodeBacking` и поле `backing` не
переносить вообще (мёртвый код). Оставить модель «renderer владеет
`[NodeID: CALayer]`», как сейчас. Протокол backing — задача этапа, где
появятся ноды с разным нативным представлением (text/image/video).

### 2.6 §2 — Grid вне этапа 1, `Arrangement` внутри

Черновик держит Grid-движок и `Arrangement`-DSL одним пакетом. Их надо
разделить: это разные вещи с разной ценностью для этапа.

- **Grid-движок, `LayoutEngineKind`, `CustomEngineRegistry` — вне этапа 1.**
  Не нужны, чтобы увидеть вложенные ноды на экране, и их нельзя осмысленно
  спроектировать, пока flex не оттестирован руками на железе.
- **`Arrangement` / `arrangeSubnodes()` — в этапе 1.** Это форма, в которой
  пишутся сами ноды («наследуюсь и описываю положение внутренних»), то есть
  предмет ручного тестирования, а не надстройка над ним. Полный разбор,
  включая почему у метода нет параметра-констрейнта — раздел 5.2.

Но **одно решение из §2 надо принять сразу**, потому что оно про форму
публичного типа: `LayoutEngine` в Weave — это имя **шедулера** (`@MainActor
final class LayoutEngine` с `request/cancel/dispose`), а черновик хочет
назвать `LayoutEngine` **протокол математики раскладки**. Два разных смысла
на одном имени. В Trellis разводим сразу, до первого публичного релиза —
планировщик получает собственное имя, после чего `LayoutEngine` свободно
и достаётся математике, как и хотел черновик (D11):

| Роль | Имя в Trellis |
|---|---|
| MainActor-шедулер асинхронной раскладки | `LayoutScheduler` |
| Контекст исполнения движка, включая отмену | `LayoutContext` (D10); не контекст Arrangement |
| Математика раскладки (сегодня один flex) | `FlexboxEngine` (D11); протокол `LayoutEngine`, internal, без публичного registry до второго движка |
| Выбор движка на контейнере (этап 2+) | `LayoutStyle.engine: LayoutEngineKind` |

Переименование `LayoutEngine` → `LayoutScheduler` делается **при переносе**,
одним движением, пока публичных потребителей нет. Имя `LayoutEngine` при этом
не исчезает, а меняет смысл: в Weave это планировщик, в Trellis — протокол
математики. Расхождение намеренное и записано в D11, чтобы обнаруживаться при
чтении, а не при отладке.

### 2.7 §5 п.0 — сверка с `RenderCoordinator` выполнена

Черновик просил «прочитать `RenderCoordinator.swift` и сверить раздел 3.5».
Сверено. Три content-path (native CALayer properties / растеризация /
attached sublayer) описаны верно. Но для этапа 1 всё это неактуально: без
Text/Image/Video растеризация не запускается ни разу, `DisplayScheduler`
простаивает. Вывод — см. раздел 4.

---

## 3. Что найдено в коде и в черновике не описано

Это находки чтения, а не пересказ. Каждая — конкретная правка при переносе.

### 3.1 `LayoutResult.placement(for:)` — линейный поиск, на дереве даёт O(N²)

```swift
// Sources/WeaveUI/LayoutResult.swift
public func placement(for identity: UInt64) -> LayoutPlacement? {
    placements.first { $0.identity == identity }
}
```

`Node.applyRecursively` вызывает это **для каждой ноды**, и
`UIKitLayerRenderer.update` — ещё раз для каждой. Это даёт квадратичную сложность по числу нод;
точное число сравнений зависит от порядка и успешности поиска. **Правка при переносе:** `LayoutResult` хранит
`[NodeID: LayoutFrame]` (плюс упорядоченный массив, если порядок нужен),
`placement(for:)` — O(1).

### 3.2 `Node.findNode(id:)` — тоже линейный обход, вызывается на каждый artifact

`RenderCoordinator.handleLayoutResult` ставит
`transaction.nodeRevisionValidator = { root.findNode(id: nodeID)?.displayRevision == revision }`
— полный обход дерева на каждую проверку. В этапе 1 не срабатывает (нет
контент-нод), и сам validator в этап 1 не переносится. Отдельный weak node registry
сейчас не нужен. Вернуться к индексированному lookup при появлении
потребителя; необходимые словари placements и layers переносить уже сейчас.

### 3.3 `makeLayoutInputSnapshot` передаёт детям constraint **корня**, а не свой

```swift
// Sources/WeaveUI/Node.swift
let contentConstraint = SizeConstraint(...)          // посчитан для себя
return LayoutInputSnapshot(
    content: layoutContentMetrics(for: contentConstraint),
    children: children.map {
        $0.makeLayoutInputSnapshot(constraint: constraint, isRoot: false)  // ← constraint, не contentConstraint
    },
    ...
)
```

На геометрию flex это **не влияет** (`FlexSolver` резолвит `.fraction` от
собственного `availableMain` на каждом уровне — проверено). Влияет на
`layoutContentMetrics(for:)`: вложенная контент-нода меряет свой intrinsic
размер против ширины **корня**. Для этапа 1 (нет контент-нод) — латентно,
но это ровно та мина, которая взорвётся в первый же день работы над Text:
многострочный текст в узкой колонке измерится по ширине экрана.

**Правка при переносе:** передавать известные ограничения с учётом явных
размеров и padding, не называть их окончательной шириной ребёнка.
Grow/shrink/wrap и соседние элементы могут изменить доступную ширину уже
в solver. Одной правки передачи constraint недостаточно для Text: его
измерение по фактически выделенной ширине требует отдельного контракта.
См. также 3.12: coordinator сейчас вообще не передаёт root bounds в snapshot.

### 3.4 `Node.style { didSet { setNeedsLayout() } }` — инвалидация без сравнения

`LayoutStyle` — `Hashable`. Присвоение идентичного значения всё равно крутит
`layoutRevision` и будит весь конвейер. `RenderCoordinator` потом это
коалессирует, но лог будет шумный, а на устройстве в цикле
`style { }` — лишняя работа. **Правка:** `didSet { guard oldValue != style else { return }; setNeedsLayout() }`.
То же для `appearance`.

Texture этот guard имеет: сеттер `ASLayoutElementStyle` дёргает делегата
только при реальном изменении (`ASLayoutElement.mm:244`,
`BOOL changed = ...; if (changed) { ...CallDelegate... }`). Становится
критично после правки 5.1, где присваивание одного поля — обычная
операция, а не редкая пересборка через `Draft`.

### 3.5 `Node.dispose()` не снимает хостовые колбэки

```swift
open func dispose() {
    children.forEach { $0.dispose() }
    children.removeAll()
    subscriptions.cancelAll()
    lifecycle.transition(.dispose)
    parent = nil
    backing = nil
    // onInvalidate / onInvalidateVisualStyle / onScrollStateChanged остаются
}
```

Disposed-нода продолжает держать замыкание на хост. **Правка:** обнулять все
колбэки в `dispose()`.

### 3.6 `setNeedsLayout` и `setNeedsDisplay` — две разные идиомы одного и того же

`setNeedsLayout` — рекурсия вверх с вызовом `onInvalidate` на корне.
`setNeedsDisplay` — цикл `while` вверх, потом `rootNode.onInvalidate?(self)`.
Разное поведение при отсутствии родителя, разная стоимость. **Правка:**
один приватный `propagateInvalidation(_ kind:)`, обе публичные функции —
тонкие обёртки. Заодно это единственное место, куда надо повесить trace
(раздел 6).

### 3.7 `RenderCoordinator.handleLayoutResult` — retry без бюджета

При провале ревизионных guard'ов coordinator вызывает `invalidate(...)`
заново. Если дерево меняется каждый кадр быстрее, чем считается layout,
это self-sustaining цикл без счётчика и без лога. **Правка:** счётчик
последовательных retry, лог `warn` начиная с 3-го, `error` + отказ от
retry на, скажем, 8-м, с описанием того, какой именно guard не сошёлся.
Бюджет ограничивает повторы одного ошибочного состояния. Dirty/latest state
сохраняется; новая внешняя инвалидация и resume возобновляют работу, успешный
commit сбрасывает бюджет. Отмена/supersede не расходуют этот бюджет как
ошибка solver. В раннем срезе автоматический retry можно не включать: guard
failure логируется, следующее внешнее изменение снова запускает расчёт.

### 3.8 `LayoutScheduler` создаёт новый `FlexMeasureCache` на каждый запрос

Отмечено и в черновике (§1.5). Кэш живёт один проход и умирает. Для этапа 1
оставляем как есть — но **лог должен показывать hit/miss**, чтобы к моменту
оптимизации были цифры, а не догадки.

### 3.9 Линтер не вырезает комментарии и строковые литералы

`check_policy.py` гоняет регулярки по сырому тексту файла. Правило
`FORCE_OPERATION` = `\btry!|\bfatalError\s*\(|(?<=[A-Za-z0-9_\]\)])!(?!=)`.
Значит `/// Готово!` в doc-комментарии или `"Failed!"` в строке — это
violation. **Правка при переносе:** для code-only правил использовать маскированное представление с сохранением
строк и исполняемой интерполяции. PUBLIC_DOCUMENTATION, SECRET и TODO должны
читать исходный текст. Fixtures покрывают вложенные комментарии, raw и
multiline strings; глобальное удаление всего текста строк небезопасно.

### 3.10 Нулевой размер — главная ловушка ручного тестирования

Дефолт `LayoutStyle`: `flexDirection = .row`, `width = .auto`,
`height = .auto`, `alignItems = .stretch`. Свежий лист `Node()` без детей и собственных размеров может измериться
в **0×0**. Но корень в текущем placement-pass получает переданный host frame:
его невидимость нельзя автоматически объяснять `.auto`. Это первая вещь,
об которую спотыкаешься при ручном тестировании нод.

**Правка:** диагностировать нулевую ширину или высоту рисующей ноды,
не только случай 0×0. Для невидимого корня сначала проверить bounds,
ownership и наличие commit. Один этот лог экономит часы на устройстве.

### 3.11 Два адаптерных рендерера отличаются одной строкой из 506

Главная находка для решения «какой адаптер переносить».
`Sources/UIKitAdapter/UIKitLayerRenderer.swift` (506 строк) и
`Sources/AppKitAdapter/AppKitLayerRenderer.swift` (506 строк) — это 1012
строк, из которых различается **ровно одна**:

```
414c414
<     let scale = UIScreen.main.scale
---
>     let scale = NSScreen.main?.backingScaleFactor ?? 1
```

И эта строка — fallback-масштаб внутри вспомогательного текстового пути,
даже не геометрия. Всё остальное — `CALayer`, `CATransaction`, `CGRect`,
`CGPoint`, то есть **QuartzCore и CoreGraphics, а не UIKit и не AppKit**.
Платформенный фреймворк импортируется ради одной строки.

`AGENTS.md` Weave отдельно предупреждает: «These two are not symmetric —
verify a fix landed in both», и перечисляет баги, починенные только в UIKit.
Причина видна: 506 строк, которые надо править синхронно вручную.

**Решение для Trellis — не переносить два рендерера, а сделать один
платформо-нейтральный.** Рендерер целиком живёт в `TrellisRender` и импортирует
только QuartzCore/CoreGraphics; масштаб и bounds ему **передаёт хост**
параметром (он их и так уже получает через `HostRenderRequest.scale`).
Платформенные таргеты сжимаются до ~50 строк каждый: владеть нативной
`view`, отдавать `bounds`/`scale`/safe area, звать `invalidate`.

Следствия:
- Проблема рассинхронизации адаптеров исчезает как класс, а не отлавливается
  линтером (правило `ADAPTER_PARITY` из первой редакции этого плана больше
  не нужно).
- Общая математика и renderer сокращают расхождения, но не доказывают
  равенство разных bounds/scale/insets. Fixed-input и native-input проверки
  выполняются отдельно.
- tvOS использует тот же UIKit-host; его safe area и lifecycle всё равно
  требуют проверки на устройстве.

Единственная реальная платформенная разница в геометрии — на macOS у
`NSView` система координат снизу-вверх. Weave решает это через
`public override var isFlipped: Bool { true }` на host-view
(`AppKitAdapter.swift:67`) — один override, после которого математика
рендерера совпадает с iOS. Дополнительно хост обязан корректно отдавать scale/insets, следить за окном
и освобождать связи. `isFlipped` и wantsLayer проверяются на реальном NSView;
голый CALayer-тест этого не доказывает.

---

### 3.12 Coordinator строит snapshot без root constraint

Факт Weave: `RenderCoordinator.invalidate` передаёт `bounds` в scheduler,
но сам снимок получает вызовом `root.makeLayoutInputSnapshot()` без параметра.
Дефолт — `SizeConstraint()` с неопределёнными осями. Поэтому в живом пути
проблема 3.3 не только в передаче одного constraint детям: размеры хоста
вообще не входят в snapshot-time content measurement.

Перенос: root constraint приходит из bounds. В раннем срезе safe-area insets
хоста добавляются к padding root только в snapshot; stored style не меняется.
Полный EnvironmentScope и boundary/ignore rules появляются в C10 позже.

### 3.13 В solver нет внутренних checkpoints отмены

Факт Weave: `LayoutEngine.request` проверяет `Task.isCancelled` до и после
синхронного вызова solver. В measure/place нет внутренних checkpoints;
отмена старого worker не прекращает уже выполняющийся расчёт немедленно.
При запуске нового detached worker старый может продолжать расходовать CPU
и удерживать snapshot/cache.

Перенос: внутренний solver получает LayoutContext и возвращает результат
через `throws -> LayoutResult`. Checkpoints первоначально на входах
layoutContainer и границах flex-линий; задержка отмены проверяется в C31,
особенно на широкой одиночной линии. Scheduler ждёт выхода старого solver,
держит только последнее pending state и не commit отменённый результат.

Пустой result опасен: renderer использует fallback calculatedFrame, а затем
удаляет layers вне active set. Отмена может выглядеть как старый успешный
кадр либо удаление слоёв. Ни пустой, ни частичный result не кодирует отмену.

---

## 4. Матрица переноса: файл за файлом

Легенда:
- **ВЗЯТЬ** — переносится как есть, только переименование/адаптация модуля.
- **ВЗЯТЬ+** — переносится с конкретными правками (ссылка на раздел 3 / 5).
- **ЧАСТЬ** — переносится только указанный кусок, остальное отрезается.
- **НЕ БРАТЬ** — не в этапе 1 (не выбрасывается навсегда, просто позже).
- **ВЫБРОСИТЬ** — мёртвый код, не переносить никогда.

### `Sources/WeaveUI` → `Sources/TrellisCore`

| Файл | стр. | Вердикт | Что делаем |
|---|---:|---|---|
| `Layout.swift` | 482 | **ВЗЯТЬ+** | Геометрия и `LayoutStyle` — фундамент. Правка 5.1: поля `let` → `var`, дефолты переезжают к полям, `init` с 23 параметрами исчезает, нормализация в `didSet`. Плюс литералы для `SizeValue`. |
| `FlexSolver.swift` | 480 | **ВЗЯТЬ+** | Измерительный проход → `FlexboxEngine` (D11); throws/LayoutContext/checkpoints по 3.13. Геометрические ожидания завершённых расчётов сохраняются. |
| `LayoutResult.swift` | 320 | **ВЗЯТЬ+** | Правка 3.1 (словарь вместо линейного поиска). Позиционный проход в отдельный файл `FlexboxPlacement.swift` — сейчас 250 строк алгоритма живут в файле с названием «result». |
| `LayoutEngine.swift` | 116 | **ВЗЯТЬ+** | → `LayoutScheduler.swift` (2.6). Добавить логи запросов/отмен/stale (раздел 6). |
| `Node.swift` | 471 | **ЧАСТЬ+** | Ядро берём. Отрезаем: accessibility (5 полей + `accessibilityActionsPipe` + `emitAccessibilityAction`), focus (`focusEligibility`, `focusable`), `semantics`, `onScrollStateChanged`, `onEdgePullChanged`, `bind(id:_:update:)`/`subscriptions` (Flux), `NodeBacking`+`backing`+`isLoaded`, `compose()`/`reconciliationDescriptor` (мёртвая точка расширения, никто не вызывает), `enteredViewport`/`leftViewport`, `handleCapture`/`handleEvent`/`handleBubble`. **Добавляем:** `open func arrangeSubnodes()` (5.2). Правки 3.4, 3.5, 3.6, 3.3. Итог ≈180 строк. |
| `StyleBuilders.swift` | 310 | **ВЫБРОСИТЬ** | Вся машинерия `StyleBuildable`/`buildStyle`/`Draft` не нужна, если поля `LayoutStyle` сделать `var` — см. 5.1. Формы `node.style { }` и `node.appearance { }` сохраняются, но обе работают над копиями самих mutable-стилей без Draft. Одной смены LayoutStyle недостаточно: VisualStyle тоже требует правки. |
| `NodeTreeDSL.swift` | 98 | **ВЗЯТЬ+** | `style`/`appearance`/`frame`/`addSubnodes`/`configure`/`ignoresSafeArea` — это и есть API, которым будешь строить дерево при тестировании. |
| `VisualStyle.swift` | 86 | **ВЗЯТЬ+** | Верхний VisualStyle mutable с нормализацией; appearance closure работает над копией значения без Draft. Border/Shadow можно оставить immutable. |
| `Theme.swift` | 424 | **ЧАСТЬ** | Только `ThemeColor` (нужен `Fill.color`) и минимальный `Theme`/`ThemeColors` под `Fill.theme(role)`. `ThemePalette`, `ThemeStore`, typography/spacing/radius/motion, подписки — **НЕ БРАТЬ**. ≈60 строк вместо 424. |
| `Environment.swift` | 438 | **ЧАСТЬ** | Только `EnvironmentKey`, `EnvironmentValues`, `EnvironmentScope`, `EnvironmentSnapshot`, `SafeAreaInsets`/`SafeAreaEdges`/`SafeAreaInsetsKey`, `LayoutDirectionKey`. Остальные ключи — по мере надобности. |
| `Lifecycle.swift` | 276 | **ЧАСТЬ** | `LifecycleState`, `LifecycleEvent`, `LifecycleMachine`. `ConnectionScope`/`EffectRecord`/`LifecycleHooks` — **НЕ БРАТЬ** (это про эффекты и Flux, не про дерево). |
| `Reconciliation.swift` | 135 | **НЕ БРАТЬ** | Переезжает в этап 2 вместе с `Collections` — единственным потребителем (5.2). Правки 2.2/2.3 остаются в силе, но исполняются там. |
| `NodeReconciliation.swift` | 131 | **НЕ БРАТЬ** | То же (5.2). При переносе в этапе 2: лог каждого патча, `isApplicable`-отказ логируется, а не молча возвращает `applied: false`. |
| `NodeBuilder.swift` | 140 | **НЕ БРАТЬ** | Дескрипторы и `ForEach` — часть механизма реконсиляции, уезжают в этап 2. Правка `AnyHashable` вместо `String(describing:)` (черновик §1.3, подтверждается) — там же. |
| `LayoutSpec.swift` | 205 | **ВЫБРОСИТЬ** | Мёртвый код, проверено (2.1 / раздел 1). Идея реализуется заново как `Arrangement` (5.2), но не через этот файл: он умеет только `measure` и с `Node` не связан. |
| `NodeState.swift` | 82 | **НЕ БРАТЬ** | Этап state/Flux. |
| `Text.swift`, `Image.swift`, `Controls.swift`, `TextInput.swift`, `Forms.swift`, `Table.swift`, `Video.swift`, `ImageMemoryCache.swift` | ~1900 | **НЕ БРАТЬ** | Этап 2+ (Text → Image → Button). |
| `Scroll.swift`, `Collections.swift`, `Gestures.swift`, `Events.swift`, `Focus.swift`, `Accessibility.swift`, `Feedback.swift` | ~2900 | **НЕ БРАТЬ** | Этап 3+. `Scroll.swift`/`Collections.swift` разобраны отдельно в [weave-scroll-analysis.md](weave-scroll-analysis.md) (implementation-plan-6.md, R06/R10) — контракт переносим, native scroll mechanics и наследование `VirtualizedView : ScrollNode` — нет. |
| `Navigation.swift`, `NavigationRestoration.swift`, `DeepLink.swift`, `Coordinator.swift`, `SceneCoordinator.swift`, `Commands.swift` | ~1400 | **НЕ БРАТЬ** | Этап навигации. |
| `Controller.swift` | 355 | **НЕ БРАТЬ** | В этапе 1 корень монтируется напрямую (раздел 7). |
| `Window.swift` | 195 | **НЕ БРАТЬ** | То же. |
| `Animation.swift` | 201 | **НЕ БРАТЬ** | Поле HostRenderRequest.animation тоже не переносить: nil-заглушка требует непереносимого типа. Вернуть типизированное поле вместе с анимацией. |
| `Transfer.swift`, `Localization.swift`, `LocalizationProvider.swift` | ~470 | **НЕ БРАТЬ** | |

### `Sources/WeaveAdapters` → `Sources/TrellisRender`

| Файл | стр. | Вердикт | Что делаем |
|---|---:|---|---|
| `RenderCoordinator.swift` | 406 | **ЧАСТЬ+** | Берём: `HostRenderRequest`, mount/unmount/suspend/resume/replaceRoot, `invalidate`, коалессинг, ревизионные guard'ы, `handleLayoutResult`, `onCommitGeometry`, `onPostCommit`. **Отрезаем:** весь `DisplayTransaction`/`scheduleDisplayPasses`/`scheduleDisplayPass` (это Text/Image), `onCommitDisplayArtifact`, `invalidateDisplay`, `nodeRevisionValidator`. Правка 3.7 (бюджет retry). Плюс лог на каждой стадии. Итог ≈220 строк. |
| `VisualStyleRenderer.swift` | 90 | **ВЗЯТЬ** | Ровно то, что нужно: background/corner/border/shadow напрямую на `CALayer`. |
| `DisplayPipeline.swift` | 463 | **НЕ БРАТЬ** | `DisplayScheduler`/`DisplayRequest`/`DisplayArtifact` — растеризация. Возвращается вместе с Text. |
| `CoreTextRasterRenderer.swift`, `ImageRasterRenderer.swift` | 511 | **НЕ БРАТЬ** | Этап Text/Image. Код зрелый, вернуться к нему как есть. |
| `AnimationTiming.swift`, `LayoutTransformNative.swift` | | **ЧАСТЬ** | Только `LayoutTransform → CGAffineTransform` (renderer его использует). |

### `Sources/UIKitAdapter` + `Sources/AppKitAdapter` → `TrellisRender` + два мини-хоста

Ключевое отличие от Weave: рендерер **не платформенный** (находка 3.11).

| Кусок | Куда | Что делаем |
|---|---|---|
| `*LayerRenderer.applyCommitted` + `update(node:...)` + `makeLayer` + `unmount` + `applyVisualOnly` | **`TrellisRender/LayerRenderer.swift`** (нейтральный) | Основа рендера, одна копия вместо двух. Отрезать: swipe presentation (≈200 строк), `applyScrollOffset`, `applyEdgePull`, `applyArtifact`, ветки `TextNode`/`ImageNode`/`VideoNode`. Правка 3.1 (O(1) placement). Единственная платформенная строка (`UIScreen.main.scale`) не переносится: `scale` приходит параметром из `HostRenderRequest`. Итог **≈130 строк вместо 1012**. |
| `UIKitHostView.attach/detach` (проводка колбэков) | **`TrellisRender/NodeHostBridge.swift`** (нейтральный) | Вся логика «связать `Node.onInvalidate` → `RenderCoordinator` → `LayerRenderer`» платформо-нейтральна. Хосту остаётся отдавать bounds/scale/insets. ≈70 строк. |
| `UIKitHostView` — `UIView`-обвязка | **`TrellisUIKit/TrellisHostView.swift`** | `layoutSubviews` → `bridge.updateBounds(...)`, `traitCollectionDidChange`/`safeAreaInsetsDidChange` → `bridge.updateInsets(...)`, `window?.screen.scale`. ≈50 строк. Покрывает iOS + iPadOS + tvOS. |
| `AppKitHostView` — `NSView`-обвязка | **`TrellisAppKit/TrellisHostView.swift`** | То же + `wantsLayer = true` и `override var isFlipped: Bool { true }` (без него координаты снизу-вверх). ≈55 строк. |
| `UIKitHostView` / `AppKitHostView` input handling (touch/mouse/press) | **НЕ БРАТЬ** | Нет событий в этапе 1. |
| `installLifecycleObservers` | **ЧАСТЬ** | Только `didBecomeActive`/`willResignActive` → `suspend`/`resume`. По 6 строк на платформу. |
| `UIKitWindowHost` / `AppKitWindowHost` | **НЕ БРАТЬ** | Требуют `Window`/`Controller`, которых в этапе 1 нет. Playground кладёт `TrellisHostView` в свой контроллер сам. |
| `UIKitAdapter` / `AppKitAdapter` (фабрики text/image/video/haptics/drop/menu) | **НЕ БРАТЬ** | ~2700 строк платформенных фабрик на двоих. |
| `DebugOverlay.swift` | **ВЗЯТЬ** | 50 строк, прямо по теме этапа: визуальная отладка на устройстве. Тоже нейтральный (`CALayer`-рамки). |

Первоначальная оценка адаптерного слоя — ~105 строк. Это не лимит и не
доказанная итоговая величина: host lifecycle, начальная safe area, смена
окна/scale и teardown должны быть реализованы полностью.

### `Sources/Weave` (bootstrap)

| Кусок | Вердикт | Почему |
|---|---|---|
| `Application.swift` (306) — `Application`/`Scene`/`AppRuntime`/`SceneDescription`/`@ApplicationBuilder` | **НЕ БРАТЬ** | Для «увидеть ноду на устройстве» не нужно ничего из этого. |
| `ApplicationEntryPoint.swift` (165) — `UIApplicationMain` + генерируемый делегат | **НЕ БРАТЬ** | И более того — **сознательно не брать**. Своя точка входа мешает отлаживать: приложение перестаёт быть обычным Xcode-проектом. В этапе 1 Playground — обычное UIKit-приложение со своим `AppDelegate`, которое просто кладёт `TrellisHostView` в свой `UIViewController`. Это даёт брейкпоинты, View Debugger и Instruments «из коробки». |

### Остальные таргеты

`Networking`, `NetworkingLogging`, `Storage`, `Analytics`, `Syntax`,
`AppKitAdapter`, `WeaveTesting` — **НЕ БРАТЬ** в этапе 1.
`Logging` — **НЕ БРАТЬ в текущем виде**, см. раздел 6 (нужна другая
подсистема, async-логгер для hot path не подходит).

### Первоначальная оценка объёма (не критерий приёмки)

| | Weave | Trellis этап 1 |
|---|---:|---:|
| Строк Swift в `Sources` | ~21 500 | **~1 900** |
| из них платформенного кода | ~3 200 | **~105** |
| Таргетов | 12 | 4 |
| Файлов | 76 | ~20 |
| Внешних зависимостей | 1 (`Flux`) | **0** |

---

## 5. Структура пакета Trellis

```
Trellis/
├── Package.swift
├── policy.json
├── trellis-public-api.json
├── AGENTS.md
├── README.md
├── Scripts/
│   ├── check_all.py
│   ├── check_policy.py
│   ├── check_api.py
│   ├── test_policy.py
│   └── verify_bootstrap.py
├── Sources/
│   ├── TrellisCore/                    # платформо-нейтральное ядро
│   │   ├── Node.swift
│   │   ├── NodeIdentity.swift
│   │   ├── NodeTreeDSL.swift
│   │   ├── Lifecycle.swift
│   │   ├── Environment.swift
│   │   ├── Layout/
│   │   │   ├── LayoutGeometry.swift          # Point/Size/Frame/Insets/Offsets
│   │   │   ├── LayoutStyle.swift             # mutable flex-поля без Draft
│   │   │   ├── LayoutContext.swift           # исполнение solver / cancellation
│   │   │   ├── LayoutSnapshot.swift          # LayoutInputSnapshot, LayoutContentMetrics
│   │   │   ├── LayoutResult.swift            # + словарь placement (правка 3.1)
│   │   │   ├── FlexboxMeasure.swift          # measure снизу вверх, FlexLine, кэш
│   │   │   ├── FlexboxPlacement.swift        # placement сверху вниз
│   │   │   └── LayoutScheduler.swift         # бывший LayoutEngine
│   │   ├── Style/
│   │   │   ├── VisualStyle.swift
│   │   │   └── ThemeColor.swift
│   │   ├── Arrange/                          # 5.2
│   │   │   ├── Arrangement.swift             # Leaf / Row / Column / Overlay
│   │   │   ├── ArrangementBuilder.swift
│   │   │   ├── ArrangementModifiers.swift
│   │   │   └── ArrangementResolver.swift
│   │   └── Log.swift                         # НОВОЕ, раздел 6 — один файл
│   ├── TrellisRender/                  # платформо-нейтральный рендер (QuartzCore)
│   │   ├── RenderCoordinator.swift
│   │   ├── HostRenderRequest.swift
│   │   ├── LayerRenderer.swift        # ← единственная копия, находка 3.11
│   │   ├── NodeHostBridge.swift       # проводка Node ↔ Coordinator ↔ Renderer
│   │   ├── VisualStyleRenderer.swift
│   │   └── DebugOverlay.swift
│   ├── TrellisUIKit/                   # iOS + iPadOS + tvOS, ~50 строк
│   │   └── TrellisHostView.swift
│   └── TrellisAppKit/                  # macOS, ~55 строк
│       └── TrellisHostView.swift
├── Tests/
│   ├── TrellisCoreTests/
│   └── TrellisRenderTests/
└── Playground/                        # Xcode-проект для железа
    ├── Playground.xcodeproj           # 3 таргета: iOS(+iPad), tvOS, macOS
    ├── Shared/
    │   └── Scenarios/                 # по файлу на сценарий, общие для всех
    ├── iOS/       AppDelegate.swift + PlaygroundViewController.swift
    ├── tvOS/      AppDelegate.swift + PlaygroundViewController.swift
    └── macOS/     AppDelegate.swift + PlaygroundViewController.swift
```

### `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trellis",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "TrellisCore", targets: ["TrellisCore"]),
        .library(name: "TrellisRender", targets: ["TrellisRender"]),
        .library(name: "TrellisUIKit", targets: ["TrellisUIKit"]),
        .library(name: "TrellisAppKit", targets: ["TrellisAppKit"]),
    ],
    targets: [
        .target(name: "TrellisCore"),
        // Зависит только от QuartzCore/CoreGraphics — собирается на всех
        // четырёх платформах одним и тем же кодом.
        .target(name: "TrellisRender", dependencies: ["TrellisCore"]),
        .target(
            name: "TrellisUIKit",
            dependencies: ["TrellisCore", "TrellisRender"]
        ),
        .target(
            name: "TrellisAppKit",
            dependencies: ["TrellisCore", "TrellisRender"]
        ),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore"]),
        .testTarget(name: "TrellisRenderTests", dependencies: ["TrellisCore", "TrellisRender"]),
    ],
    swiftLanguageModes: [.v6]
)
```

`TrellisUIKit` подключается на iOS/iPadOS/tvOS, `TrellisAppKit` — на macOS.
Отдельные таргеты не являются доказательством доступности их импортов при
общем swift build/test. C02 проверяет фактическую сборку. Рекомендуется
узкий `#if canImport(UIKit)`/`#if canImport(AppKit)` в соответствующих host
файлах, как уже сделано в Weave. В общем Core/Render платформенные ветки
не появляются. Пример манифеста выше — схема зависимостей, не готовая
проверенная замена Package.swift.

**Про `Flux`:** в этапе 1 зависимости нет. `Node.bind`, `Pipe`, `ActionPipe`,
`NodeState` не переносятся. Минимальный реактивный путь C29 реализуется
без зависимости Flux, с явным владельцем и отменой доставки состояния. Пакет собирается без сети и без внешних
зависимостей — заметно упрощает первую сборку на устройстве и на Apple TV.

### 5.1 Стили: `node.style.width = 100`, как в Texture

Требование: задавать ноде стили так же, как это делает Texture
(`ASLayoutElementStyle`, `old/Texture/Source/Layout/ASLayoutElement.h`).

#### Как это устроено у Texture

`node.style` — **mutable объект-ссылка**, у которого каждое свойство
присваивается напрямую:

```objc
node.style.width      = ASDimensionMake(100);
node.style.flexGrow   = 1.0;
node.style.alignSelf  = ASStackLayoutAlignSelfCenter;
node.style.spacingAfter = 8;
```

Механика сеттера (`ASLayoutElement.mm:244`):

```objc
- (void)setWidth:(ASDimension)width {
  BOOL changed = ASLayoutElementStyleSetSizeWithScope({ newSize.width = width; });
  if (changed) {                                   // ← no-op не будит layout
    ASLayoutElementStyleCallDelegate(ASLayoutElementStyleWidthProperty);
  }
}
```

То есть: присвоил → если значение реально изменилось, стиль дёргает
делегата (`ASLayoutElementStyleDelegate`), делегат — это нода, нода зовёт
`setNeedsLayout`. Заметь: проверка «а изменилось ли» у Texture есть — это
ровно то, чего не хватает в Weave (находка 3.4).

#### Почему сейчас так не написать

`LayoutStyle` в Weave — иммутабельная структура, **все поля `let`**:

```swift
public struct LayoutStyle: Sendable, Hashable {
    public let flexDirection: FlexDirection
    public let width: SizeValue
    ...
}
```

Поэтому единственный способ мутации — замыкание над отдельным типом
`Draft` с последующей пересборкой:

```swift
node.style { $0.width = .points(100) }        // единственная форма сегодня
node.style.width = .points(100)               // ❌ не компилируется
```

Ради этого существует `StyleBuilders.swift` — 310 строк: протокол
`StyleBuildable`, функция `buildStyle`, и по отдельному типу `Draft` на
каждый стиль, где каждое поле продублировано **трижды** (в `LayoutStyle`,
в `Draft`, в `Draft.init(_ style:)`) плюс четвёртый раз в `bake`.
23 поля × 4 = 92 строки чистого дублирования только для `LayoutStyle`.

#### Решение: поля `var`, и вся машинерия Draft уходит

```swift
public struct LayoutStyle: Sendable, Hashable {
    public var flexDirection: FlexDirection = .row
    public var justifyContent: JustifyContent = .start
    public var width: SizeValue = .auto
    public var flexGrow: Double = 0
    ...
}
```

На `Node` — обычное свойство с проверкой на no-op (находка 3.4, ровно как
у Texture):

```swift
public var style = LayoutStyle() {
    didSet {
        guard oldValue != style else { return }   // no-op guard; сравнение имеет стоимость
        setNeedsLayout()
    }
}
```

Всё. После этого работает Texture-форма — Swift мутирует структуру
**на месте** через сеттер ноды, `didSet` срабатывает один раз:

```swift
node.style.width = .points(100)
node.style.flexGrow = 1
node.style.alignSelf = .center
```

И одновременно остаётся форма для батча, но уже без отдельного типа
`Draft` — прямо над самим `LayoutStyle`:

```swift
extension Node {
    /// Мутирует стиль одной транзакцией: один didSet, одна инвалидация.
    @discardableResult
    public func style(_ configure: (inout LayoutStyle) -> Void) -> Self {
        var copy = style
        configure(&copy)
        style = copy
        return self
    }
}
```

Обе формы живут рядом и делают ровно то, чего от них ждёшь: одиночное
присваивание — одна инвалидация, замыкание с пятью полями — тоже одна.

**Что это даёт по объёму:** `StyleBuilders.swift` (310 строк) не
переносится вообще. `LayoutStyle` сокращается примерно на треть — исчезает
`init` с 23 параметрами, потому что дефолты переезжают к полям.
Экономия строк здесь — предварительная оценка. Нужен явный public init()
для внешнего consumer. VisualStyle.Draft удаляется только после аналогичной
адаптации VisualStyle и appearance closure; нормализацию init/записей нужно
проверить отдельно.

#### Литералы: короче, чем у Texture

У Texture есть `ASDimensionMake(@"50%")` — парсинг строки в рантайме.
В Swift то же самое делается типобезопасно и без парсинга:

```swift
extension SizeValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self = .points(Double(value)) }
    public init(floatLiteral value: Double) { self = .points(value) }
}
```

```swift
node.style.width  = 100            // = .points(100)
node.style.height = .fraction(0.5) // явно, когда доля
node.style.gap    = 8              // Double, литерал и так работает
```

Компромисс: неявное приведение числа к `.points` может удивить того, кто
ждал долю. Но в CSS/Yoga/Texture голое число всегда значит точки, так что
ожидание совпадает с индустриальным. **Рекомендация: добавить.**

#### Что Trellis уже умеет сверх `ASLayoutElementStyle`

Существенно для предыдущего вопроса про «описать поведение дочерних»:
у Texture стиль ноды содержит **только child-половину** (как со мной
обойтись родителю), а container-половина (как я раскладываю детей) живёт
в `ASStackLayoutSpec`, то есть в возвращаемом спеке, а не в стиле.
`LayoutStyle` держит обе.

| | Texture `ASLayoutElementStyle` | Trellis `LayoutStyle` |
|---|---|---|
| **Container-половина** | нет (в `ASStackLayoutSpec`) | `flexDirection`, `flexWrap`, `justifyContent`, `alignContent`, `alignItems`, `gap`, `crossGap`, `padding` |
| Размеры | `width`/`height`/`min*`/`max*` (`ASDimension`) | то же (`SizeValue`) |
| Flex-child | `flexGrow`, `flexShrink`, `flexBasis`, `alignSelf` | то же |
| Отступы у ребёнка | `spacingBefore`, `spacingAfter` (по оси) | `margin` (4 логических края) |
| Абсолютное позиционирование | `layoutPosition` (CGPoint) | `positionType` + `offsets` (4 опциональных края, с RTL) |
| Соотношение сторон | нет (`ASRatioLayoutSpec`) | `aspectRatio` |
| Baseline | `ascender`/`descender` в стиле | `LayoutContentMetrics.firstBaseline` — измеряемая величина, а не стилевая |
| Удобные CGSize | `preferredSize`/`minSize`/`maxSize` | `Node.frame(width:height:)` |
| Расширяемость | `ASLayoutElementExtensibility` (типизированные слоты) | нет, и не нужно |

То есть модель уже шире. **Не хватало только формы записи** — и она
чинится сменой `let` на `var`.

#### Одно решение, которое надо принять

Сейчас `LayoutStyle.init` нормализует значения: `flexGrow`/`flexShrink`/
`gap`/`crossGap` зажимаются в неотрицательные, `aspectRatio ≤ 0` становится
`nil`, нефинитные числа обнуляются. При переходе на `var` эта нормализация
теряет единственную точку входа. Варианты:

1. **`didSet` на каждом нормализуемом поле.** Присваивание внутри `didSet`
   в Swift не рекурсирует, так что это безопасно. Плюс: инвариант держится
   на самом типе. Минус: пять `didSet`-блоков.
2. **Нормализовать в солвере, а `LayoutStyle` оставить тупым значением.**
   Солвер и так защищён (`SizeValue.resolved` возвращает `nil` на мусоре,
   `MeasuredSize`/`LayoutFrame` зажимают в конструкторе). Плюс: тип
   становится прозрачным. Минус: `node.style.flexGrow = -1` тихо доедет до
   солвера и там превратится в 0, а при чтении обратно вернёт `-1`.

**Рекомендация: вариант 1** — сохранить инвариант на типе. Это ровно то,
что делает Texture (`ASLayoutElementStyle` зажимает в сеттерах), и это
избавляет от класса вопросов «почему в логе `flexGrow=-1`, а ведёт себя
как 0».

### 5.2 `arrangeSubnodes()` — аналог `layoutSpecThatFits:` (входит в этап 1)

Требование: наследоваться от `Node`, переопределить метод и описать в нём
положение внутренних нод — как `-[ASDisplayNode layoutSpecThatFits:]`.

Сегодня в Weave такого метода нет. Точки переопределения на `Node`:
`compose()` (список детей-дескрипторов, и его **никто не вызывает** —
проверено грепом по `Sources/`), `layoutContentMetrics(for:)` (собственный
intrinsic-размер листа), `didApplyLayoutResult(_:)` (постфактум).
`LayoutSpec.swift` похож на Texture, но это мёртвый код: умеет только
`measure`, не позиционирует, дети — `[any LayoutSpec]`, ни одной ссылки на
`Node`.

#### Единственное, что мешает скопировать Texture дословно

`ASDisplayNode+Subclasses.h:129`, контракт `calculateLayoutThatFits:`,
из которого зовётся `layoutSpecThatFits:`:

> This method is called on a **non-main thread**.

И в `ASDisplayNode+LayoutSpec.mm:134` видно, чем это обеспечено:
`_locked_layoutElementThatFits:` работает под `__instanceLock__` — то есть
**`ASDisplayNode` потокобезопасен по построению**, и раскладка идёт прямо
по живым объектам нод вне главного потока. Это и есть «Async» в
AsyncDisplayKit.

Trellis выбрал противоположную модель, и она уже вшита во всё:

```
Node — @MainActor класс                     ← живые объекты только на главном
   ↓ makeLayoutInputSnapshot()
LayoutInputSnapshot — immutable Sendable    ← это и уезжает в Task.detached
   ↓
FlexboxEngine — чистая функция, до Node не дотягивается вообще
```

Позвать `open func` на `Node` из солвера невозможно: Swift 6 в strict
concurrency этого просто не скомпилирует, а обходные пути
(`@unchecked Sendable`, `nonisolated(unsafe)`) запрещены `policy.json` —
и запрещены правильно.

Значит выбор ровно из двух:

1. **Снять с `Node` `@MainActor` и городить мьютексы, как Texture.**
   Это другой фреймворк, а не правка. Плюс Texture платит за это
   `__instanceLock__` на каждое обращение к свойству.
2. **Звать override на MainActor до сборки снимка.** Ниже — это.

#### Форма: `arrangeSubnodes()` без констрейнта

```swift
/// Фрагмент объявления метода внутри класса Node, не в extension.
@MainActor
open class Node {
    /// Декларативно описывает раскладку своих детей.
    /// Вызывается на MainActor в объединённом flush до сборки снимка.
    /// Ownership: возвращённое дерево временное, ноды принадлежат получателю.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func arrangeSubnodes() -> (any Arrangement)? { nil }
}
```

**Констрейнта в сигнатуре нет намеренно.** На момент вызова известен
только констрейнт корня — констрейнты отдельных нод появляются лишь в
результате измерения, а измерение идёт уже по снимку. Обещать в API
`constrainedSize`, которого в этой точке нет, значит повторить
противоречие, которое уже есть в черновике (там `arrangeSubnodes(in: LayoutContext)`
с констрейнтом, но текстом — «вызывается при `setNeedsLayout()` инвалидации»;
одновременно и то и другое невозможно).

На практике потеря небольшая: подавляющее большинство реализаций
`layoutSpecThatFits:` параметр не читают вообще, а строят статическое
дерево спеков. Респонсивное ветвление («узкий экран → колонка») приходит
позже через environment (size class), считанный один раз от окна — так же,
как это решает SwiftUI.

#### Как выглядит

```swift
final class ProfileCard: Node {
    let avatar = Node()
    let title = Node()
    let subtitle = Node()

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(spacing: 12, align: .center, padding: .all(16)) {
            Leaf(avatar).size(width: 48, height: 48)
            Column(spacing: 4) {
                Leaf(title)
                Leaf(subtitle)
            }
            .grow(1)
        }
    }
}
```

Типы — минимальный набор, ~150 строк:

```swift
@MainActor public protocol Arrangement {}

/// Лист: ссылка на живую ноду, которой владеет получатель.
public struct Leaf: Arrangement { let node: Node }

/// Контейнеры.
public struct Row: Arrangement { ... }
public struct Column: Arrangement { ... }
public struct Overlay: Arrangement { ... }

@resultBuilder public enum ArrangementBuilder { ... }

/// Модификаторы копят отложенные мутации LayoutStyle.
extension Arrangement {
    public func grow(_ value: Double) -> ModifiedArrangement
    public func size(width: SizeValue?, height: SizeValue?) -> ModifiedArrangement
    public func align(_ value: AlignSelf) -> ModifiedArrangement
    public func margin(_ insets: DirectionalEdgeInsets) -> ModifiedArrangement
}
```

Именование — по таблице §2.6 черновика: `Arrangement`, а не `LayoutSpec`;
`arrangeSubnodes`, а не `layoutSpecThatFits`. Зафиксировать сразу, пока
публичных потребителей нет.

#### Резолвер: эффективные стили, ownership и транзакция

Это проектные рекомендации D04–D06; детали подтверждаются перед C23.

1. Корневой контейнер Arrangement описывает self, без дополнительной ноды.
2. Leaf ссылается на уже существующую ноду. Её удаление из описания
   отсоединяет связь, но не dispose объект пользователя.
3. Вложенный wrapper переиспользуется по `(ownerID, structuralPath, kind)`.
   Для неизменной структуры identity стабильна; вставки перед wrapper не
   обещают сохранения без отдельного keyed API. Нужен ли каждому wrapper
   CALayer, проверяется экспериментом C30; это пока не принятое решение.
4. `node.style` — база; resolver заново вычисляет effective style для snapshot.
   Снятие `.grow(1)` восстанавливает базовое значение, а не оставляет старый grow.
   Он не перезаписывает необратимо базовые настройки пользователя.
5. Ненулевой Arrangement управляет полным списком layout-детей владельца.
   Рекомендуемая семантика nil — очистить управляемые связи/wrappers и вернуть
   ручной режим без dispose Leaf. Root Leaf, Overlay auto-size, ручное изменение
   управляемых children, дубликат Leaf, self/cycle и чужой mounted Leaf имеют
   явные контракты C21; некорректный proposal не применяется частично.

Инвалидация только отмечает dirty state и планирует один flush. Перед
snapshot resolver валидирует proposal и применяет его в транзакции дерева:
revisions меняются, повторный callback подавлен, dirty state не теряется.

```text
invalidate → mark dirty / schedule one flush
flush (когда worker slot доступен)
  → resolve изменившихся описаний в транзакции
  → capture окончательных revisions / snapshot с root constraints
  → scheduler: один solver + pending latest state
```

Тесты проверяют отсутствие reentrant scheduling, сброс модификаторов,
identity, cleanup и сохранение изменений. Эквивалентность с ручной сборкой —
геометрия по semantic paths при одинаковых входах, не bytes LayoutResult.

#### Размен: `Reconciler` уходит из этапа 1

Чтобы этап не разбух, `Reconciler` / `NodeReconciliationController` /
`ForEach` переезжают в этап 2. Обоснование, а не экономия:

- В Weave `NodeReconciliationController` используется **ровно одним
  потребителем** — `Collections.swift` (`TableView`/`GridView`), которого
  в этапе 1 нет. Проверено грепом.
- `Node.compose()`, второй половиной этого механизма, не пользуется никто.
- Это **другой** механизм: реконсиляция строит детей из данных по
  дескрипторам (`typeName` + `key`), арранжмент описывает раскладку уже
  существующих нод. Для цели этапа («наследуюсь от ноды и описываю
  положение внутренних») нужен второй, не первый.

Соответственно правки 2.2 и 2.3 (идентичность при позиционном матче,
политика дубликатов ключей) и `ReconcilerPropertyTests` тоже переезжают
в этап 2 — вместе с кодом, к которому относятся. Разбор в разделе 2
остаётся: он всё ещё верен, просто исполняется позже.

По объёму размен примерно нейтрален: минус ~270 строк реконсиляции,
плюс ~190 строк арранжмента и резолвера.





---

## 6. Логирование: обычный `print`, один файл

Требование: «пока плагин строится, хочу иметь полный спектр логирования —
нода подключилась, нода получила свой размер и так далее». Проверять — на
TV, Mac, телефоне и айпаде. На этом этапе достаточно обычного `print`.

Значит: **никаких sink-протоколов, никаких actor'ов, никакого fan-out.**
Один файл `Sources/TrellisCore/Log.swift`, ~60 строк.

### 6.1 Существующий `Sources/Logging` не переносим

Он actor-based, API асинхронный (`await logDebug(...)`), `FileSink` — actor.
В горячем пути это неприменимо: `Node.setNeedsLayout()` синхронный, а
`FlexboxEngine` считает внутри `Task.detached`. И решает он не ту задачу —
структурированные логи с ротацией файлов нужны продакшену, а не постройке.

Вернуться к нему можно позже, отдельным решением.

### 6.2 Весь логгер

```swift
// Sources/TrellisCore/Log.swift

/// Область лога. Включается независимо от остальных.
/// Ownership: значение копируется. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LogArea: String, Sendable, Hashable, CaseIterable {
    case tree       // addSubnode / removeFromSupernode / connect / dispose
    case style      // изменения LayoutStyle и VisualStyle
    case invalidate // setNeedsLayout и его распространение вверх
    case snapshot   // построение LayoutInputSnapshot
    case measure    // constraint → size, кэш
    case place      // top-down проход: кто где оказался
    case schedule   // request / cancel / stale / commit
    case commit     // ревизионные guard'ы, applyRecursively
    case arrange    // резолв arrangeSubnodes(): записи стиля, wrapper-ноды
    case layer      // CALayer: create / geometry / visual / remove
    case host       // bounds, scale, safe area, mount/unmount
}

/// Печать диагностики конвейера в стандартный вывод.
/// Ownership: состояния нет, `enabled` вычисляется один раз при первом обращении.
/// Isolation: none — вызывается и с MainActor, и из фонового солвера.
/// Errors: none. Cancellation: not applicable.
public enum Log {
    /// Набор включённых областей. Immutable `let`, поэтому Sendable без блокировок
    /// и без `nonisolated(unsafe)`, который запрещён политикой.
    ///
    /// Переключается переменной окружения `TRELLIS_LOG` в схеме Xcode —
    /// работает и при запуске на физическом устройстве, пересборка не нужна:
    ///   TRELLIS_LOG=all
    ///   TRELLIS_LOG=off
    ///   TRELLIS_LOG=schedule,commit,place
    public static let enabled: Set<LogArea> = {
        #if DEBUG
        let fallback = Set(LogArea.allCases)
        #else
        let fallback = Set<LogArea>()
        #endif
        guard let raw = ProcessInfo.processInfo.environment["TRELLIS_LOG"] else { return fallback }
        switch raw {
        case "all": return Set(LogArea.allCases)
        case "off": return []
        default: return Set(raw.split(separator: ",").compactMap { LogArea(rawValue: String($0)) })
        }
    }()

    /// Печатает строку, если её область включена.
    /// Ownership: сообщение строится только после проверки области.
    /// Isolation: none. Errors: none. Cancellation: not applicable.
    @inlinable
    public static func on(_ area: LogArea, _ message: @autoclosure () -> String) {
        guard enabled.contains(area) else { return }
        print("[trellis.\(area.rawValue)] \(message())")
    }
}
```

Всё. `@autoclosure` означает, что при выключенной области строка не
собирается — интерполяция не выполняется, аллокаций нет. `static let`
от `Sendable`-типа законен под strict concurrency, вызывать можно откуда
угодно, включая `Task.detached` солвера.

### 6.3 Формат строки

Свободный текст читать невозможно, когда на кадр приходится 100+ строк.
Договорённость — три поля через пробел: **событие, `#id` ноды, детали**.

```
[trellis.host]      bounds 393.0x852.0 scale=3.0 insets=(59,0,34,0)
[trellis.invalidate] requested #7 → root #1 depth=3 rev=42
[trellis.snapshot]  built nodes=17 depth=4
[trellis.schedule]  request gen=41 frame=393.0x852.0 scale=3.0
[trellis.measure]   #3 constraint=(exact 393, exact 852) → 393.0x852.0 miss
[trellis.measure]   #7 constraint=(atMost 361, unspec)   → 361.0x120.0 miss
[trellis.place]     #7 frame=(16,16,361x120) parent=#3 align=stretch
[trellis.place]     #12 ZERO-SIZE frame=(16,152,361x0) background=set
[trellis.schedule]  commit gen=41 placements=17 solve=0.16ms
[trellis.commit]    guards ok gen=41 tree=88 content=88 env=3
[trellis.layer]     create #12
[trellis.layer]     geometry #12 bounds=(0,0,361x0) position=(196.5,152) parent=#3
[trellis.commit]    done gen=41 nodes=17 layers=17
```

Для раннего среза достаточно schedule/commit/layer/host; остальные области
добавляются до полной приёмки C05. В многоконном режиме каждой строке
конвейера нужен также hostID: generation разных хостов могут совпасть.

Две вещи, которые надо соблюдать с самого начала:

1. **`gen=` в каждой строке конвейера.** `print` из фонового солвера
   перемешивается с `print` с MainActor — порядок строк не гарантирован.
   Номер генерации позволяет сгруппировать строки одного кадра глазами
   или через `grep "gen=41"`. Без него лог на устройстве нечитаем.
2. **`#id` — всегда в одной позиции.** Тогда `grep "#12"` даёт всю историю
   одной ноды: как её измерили, куда поставили, какой слой создали.

### 6.4 Обязательный минимум событий этапа 1

Это тот самый «полный спектр». Реализовать сразу, а не по мере надобности.

**tree** — `created` (id, тип), `added` (child, parent, index), `removed`,
`connected`, `disposed`, `cycle-rejected` (`addSubnode` молча игнорирует
self/цикл — это обязано печататься).

**style** — `changed` (какие поля: старое → новое), `no-op` (присвоили то
же самое, правка 3.4).

**invalidate** — `requested` (кто инициировал, глубина подъёма),
`dropped` (нет `onInvalidate`, то есть дерево не смонтировано — частая
причина «ничего не происходит»).

**arrange** — `resolve` (нода, число контейнеров/листьев), `style.write`
(в какую ноду какие поля), `wrapper.reuse` / `wrapper.create` (путь в дереве
арранжмента), `reentrancy` (резолв породил инвалидацию — это баг, печатать
всегда).

**snapshot** — `built` (число нод, глубина).

**measure** — `#id constraint → size hit|miss`, `line` (номер, число
элементов, main/cross), `grow`/`shrink` (свободное место, коэффициенты).

**place** — `#id frame parent align reversed`, `absolute`, `ZERO-SIZE`
(ловушка 3.10), `OVERFLOW` (ребёнок вышел за родителя).

**schedule** — `request`, `coalesced`, `cancelled`, `stale`, `commit`,
`solve=Nms`.

**commit** — `guards ok` / **`guards failed`, с указанием какой именно
guard не сошёлся и с какими числами** (сейчас это невозможно понять),
`retry n=` (правка 3.7), `applyRecursive nodes=`.

**layer** — `create`, `geometry`, `visual`, `reparent`, `remove-stale`.

**host** — `bounds`, `scale`, `safe-area`, `mount`, `unmount`,
`suspend`, `resume`.

### 6.5 Что это даёт при отладке на четырёх устройствах

Практический сценарий, ради которого всё это: нода видна на iPhone, но не
видна на Apple TV. `TRELLIS_LOG=host,measure,place` на обоих, и сравниваешь
две колонки. Расхождение будет либо в `host bounds` (tvOS даёт другой
размер и overscan-insets), либо в `measure` (`.fraction` от другой ширины),
либо в `place`. Три строки лога вместо получаса в отладчике.

Для DoD №7 сравниваются одинаковые fixed inputs: bounds, scale, insets,
direction и структура. Placements сопоставляются по semantic paths, а не
разным runtime ID. Native bounds проверяются отдельно по правилам flex;
текстовое сравнение логов разных экранов само по себе не является тестом равенства.


## 7. Адаптер и Playground: путь до четырёх устройств

Адаптер здесь — не цель, а транспорт. Задача: минимальным кодом дать
возможность положить ноду в обычное UIKit- или AppKit-приложение.

### 7.1 Границы: что платформенное, а что нет

```
TrellisCore     Node, LayoutStyle, FlexboxEngine, LayoutResult, LayoutScheduler, Log
               импорты: Foundation
                    ↓
TrellisRender   RenderCoordinator, LayerRenderer, NodeHostBridge, VisualStyleRenderer
               импорты: QuartzCore, CoreGraphics          ← НЕ UIKit, НЕ AppKit
                    ↓
TrellisUIKit (~50 строк)          TrellisAppKit (~55 строк)
UIView-обвязка                   NSView-обвязка
iOS / iPadOS / tvOS              macOS
```

`TrellisRender` работает с `CALayer` — а `CALayer` одинаков на всех четырёх
платформах. Именно поэтому 1012 строк двух рендереров Weave отличались одной
строкой (находка 3.11): платформенного в них почти ничего и не было.

Хост передаёт геометрические значения и события lifecycle. Сокращённый
контракт ниже не заменяет полный список обязанностей C17/C18:

```swift
// Sources/TrellisRender/NodeHostBridge.swift
@MainActor
public final class NodeHostBridge {
    public init(root: Node, hostLayer: CALayer)

    /// Хост сообщает новый размер. Isolation: MainActor.
    public func updateBounds(_ bounds: LayoutFrame, scale: Double)
    /// Хост сообщает безопасные отступы (чёлка, home indicator, overscan tvOS).
    public func updateSafeArea(_ insets: PhysicalEdgeInsets)
    /// Хост уходит с экрана / возвращается.
    public func suspend()
    public func resume()
    public func detach()
}
```

Вся проводка (`Node.onInvalidate` → `RenderCoordinator` →
`LayerRenderer.applyCommitted`) живёт внутри `NodeHostBridge`. Bridge сильно
удерживает root до detach/replace, обратные callbacks слабые. Bounds/scale/
insets поступают согласованно до snapshot. Тесты на CALayer не заменяют
проверки нативного host lifecycle, screen scale и реального отображения.

### 7.2 UIKit-хост: сокращённый эскиз

Эскиз показывает проводку; это не весь необходимый платформенный код.
C18 добавляет window/scale/lifecycle и teardown. Insets нужно передать сразу
при attach, не полагаясь на будущий safeAreaInsetsDidChange.

```swift
// Sources/TrellisUIKit/TrellisHostView.swift
import UIKit
import TrellisCore
import TrellisRender

/// Нативная граница для дерева нод Trellis.
/// Ownership: view владеет bridge; bridge удерживает root и owned layers до detach.
/// Isolation: MainActor. Errors: none. Cancellation: `detach()` снимает связи.
@MainActor
public final class TrellisHostView: UIView {
    private var bridge: NodeHostBridge?

    /// Подключает дерево нод к этой view.
    /// Ownership: bridge удерживает корень. Isolation: MainActor. Errors: none.
    /// Cancellation: повторный вызов заменяет предыдущее дерево.
    public func attach(root: Node) {
        bridge?.detach()
        bridge = NodeHostBridge(root: root, hostLayer: layer)
        updateBridgeSafeArea()
        setNeedsLayout()
    }

    /// Снимает дерево с этой view. Ownership: связи освобождаются.
    /// Isolation: MainActor. Errors: none. Cancellation: работа этого подключения отменена; повторный attach допустим.
    public func detach() { bridge?.detach(); bridge = nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = Double(window?.screen.scale ?? 1)
        bridge?.updateBounds(
            LayoutFrame(width: Double(bounds.width), height: Double(bounds.height)),
            scale: scale
        )
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateBridgeSafeArea()
    }

    private func updateBridgeSafeArea() {
        bridge?.updateSafeArea(
            PhysicalEdgeInsets(
                top: Double(safeAreaInsets.top), left: Double(safeAreaInsets.left),
                bottom: Double(safeAreaInsets.bottom), right: Double(safeAreaInsets.right)
            )
        )
    }
}
```

На tvOS ровно этот же файл. `safeAreaInsets` там отдаёт overscan-поля —
приезжает бесплатно.

### 7.3 AppKit-хост: сокращённый эскиз

```swift
// Sources/TrellisAppKit/TrellisHostView.swift
import AppKit
import TrellisCore
import TrellisRender

@MainActor
public final class TrellisHostView: NSView {
    private var bridge: NodeHostBridge?

    /// Слой обязателен: весь рендер Trellis — это CALayer.
    public override var wantsUpdateLayer: Bool { true }
    /// Без этого у NSView система координат снизу-вверх и вся раскладка
    /// оказывается вверх ногами относительно iOS. Единственная реальная
    /// платформенная разница в геометрии.
    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    public required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

    public func attach(root: Node) { ... }   // идентично UIKit
    public func detach() { ... }

    public override func layout() {
        super.layout()
        let scale = Double(window?.backingScaleFactor ?? 1)
        bridge?.updateBounds(
            LayoutFrame(width: Double(bounds.width), height: Double(bounds.height)),
            scale: scale
        )
        bridge?.updateSafeArea(
            PhysicalEdgeInsets(
                top: Double(safeAreaInsets.top), left: Double(safeAreaInsets.left),
                bottom: Double(safeAreaInsets.bottom), right: Double(safeAreaInsets.right)
            )
        )
    }
}
```

### 7.4 Почему не переносим `Application` / `Scene` / `UIApplicationMain`

Weave подменяет точку входа приложения (`ApplicationEntryPoint` вызывает
`UIApplicationMain` с генерируемым делегатом, `AppKitApplicationEntryPoint` —
`NSApplication.shared.run()`). На этапе, где раскладка проверяется руками на
железе, это мешает: приложение перестаёт быть обычным Xcode-проектом.

**Playground — обычные приложения.** Свой `AppDelegate`, свой контроллер,
внутри — `TrellisHostView`. Работают брейкпоинты, View Debugger, Instruments,
Console. И ровно так же Trellis будет подключаться в чужое приложение —
что и есть требование «чтобы я мог подключить ноды в UIKit-приложение».

```swift
final class PlaygroundViewController: UIViewController {   // или NSViewController
    private let host = TrellisHostView()

    override func viewDidLoad() {
        super.viewDidLoad()
        host.frame = view.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host)
        host.attach(root: Scenario.current.makeRoot())
    }
}
```

Восемь строк на подключение. Это и есть весь публичный контракт этапа 1.

### 7.5 Проект Playground: три таргета, общие сценарии

```
Playground.xcodeproj
├── Playground-iOS     (iPhone + iPad, один таргет)
├── Playground-tvOS
├── Playground-macOS
└── Shared/Scenarios/  ← входит во все три таргета
```

Сценарии — по файлу на проверяемое свойство. Не переписываем один файл
каждый раз (как было с `manual/ManualApp.swift`), а накапливаем, чтобы можно
было вернуться и перепроверить регрессию:

```
Shared/Scenarios/
├── S01_SingleNode.swift          # корень с фоном — виден ли вообще
├── S02_RowOfThree.swift          # flexDirection = .row, три ребёнка
├── S03_Column.swift              # .column
├── S04_Justify.swift             # все 6 значений justifyContent
├── S05_Align.swift               # все 5 значений alignItems + alignSelf
├── S06_Gap.swift                 # gap + crossGap
├── S07_PaddingMargin.swift       # padding vs margin, вложенно
├── S08_Grow.swift                # flexGrow / flexShrink / flexBasis
├── S09_Sizes.swift               # points / fraction / auto, min/max
├── S10_Nesting.swift             # 4 уровня вложенности ← главный сценарий
├── S11_Absolute.swift            # positionType = .absolute + offsets
├── S12_Wrap.swift                # flexWrap + alignContent
├── S13_RTL.swift                 # layoutDirection = .rightToLeft
├── S14_SafeArea.swift            # чёлка/home indicator/overscan tvOS
└── S15_DynamicMutation.swift     # добавление/удаление нод по таймеру
```

Статический сценарий — функция `@MainActor () -> Node`, без платформенных
типов. S15 получает отдельный ScenarioSession, владеющий timer/Task и отменой.
C29 добавляет S16_ReactiveUpdates с подпиской и восстановлением latest state.
Для сравнения геометрии есть fixed-input режим и semantic paths; native-input
режим проверяет реальные размеры устройств отдельно. Первый запуск требует
только S01/S10, полного набора пока нет.

Переключение — одной константой `Scenario.current`.

### 7.6 Подключение пакета

Локальная SPM-зависимость (`Add Local...` → папка `Trellis`), как было в
`manual`. Каждый таргет линкует `TrellisUIKit` или `TrellisAppKit`.
Remote-зависимостей нет — `Flux` не нужен (раздел 5).


---

## 8. Тесты

### Переносим как регрессионную базу

| Файл | стр. | Куда |
|---|---:|---|
| `FlexSolverAlgorithmTests.swift` | 328 | `TrellisCoreTests` |
| `FlexSolverBaselineTests.swift` | 117 | `TrellisCoreTests` |
| `FlexSolverFlexFeaturesTests.swift` | 116 | `TrellisCoreTests` |
| `NodeTreeDSLTests.swift` | 219 | `TrellisCoreTests`, вычистив ссылки на неперенесённые типы |
| `EnvironmentTests.swift` | 146 | `TrellisCoreTests`, только safe area / direction / scope |
| `RenderCoordinatorTests.swift` | 386 | `TrellisRenderTests` (сейчас лежит в `AppKitAdapterTests`, хотя платформо-нейтрален) |

Все они гоняются через `swift test` на Mac — ни один не требует
симулятора. То же относится и к тестам рендера: `CALayer` доступен на
macOS напрямую (см. п. 9 ниже).

### Не переносим

`LayoutSpecTests` (тестирует мёртвый код), `DisplaySchedulerTests`,
`TextRasterTests`, `ImagePresentationTests`, `AsyncRenderIntegrationTests`,
`EventTests`, `VideoTests`, `CollectionsTests`, `FocusTests`,
`NavigationRestorationTests`, все Storage/Networking/Analytics/Syntax.

### Пишем новые (закрывают находки раздела 3)

1. **`ArrangementResolverTests`** (5.2) — четыре свойства резолвера:
   (а) корневой контейнер пишет в `self.style`, лишней ноды не создаётся;
   (б) `Leaf` не создаёт нод, только переупорядочивает существующие;
   (в) повторный резолв неизменного дерева **переиспользует** неявные
   wrapper-ноды (сравнение по `===`) — иначе на каждый кадр пересоздаются
   слои; (г) резолв не порождает повторной инвалидации (`requestedCount`
   координатора не растёт) — защита от re-entrancy.
   Плюс эквивалентность: дерево, собранное `arrangeSubnodes()`, и то же
   дерево, собранное вручную через `style`/`addSubnode`, дают
   одинаковую геометрию по semantic paths при одинаковых inputs. NodeID
   и revisions сравниваются отдельно; bytes результата не являются контрактом.
2. **`LayoutResultLookupTests`** — `placement(for:)` за O(1), корректность
   на дубликатах identity.
3. **`SnapshotConstraintTests`** — правки 3.3/3.12: корень получает bounds
   хоста, дети — известные ограничения с учётом размеров/padding. Это не
   обещание окончательного flex constraint до solver. Safe area не накапливается.
4. **`InvalidationTests`** — правки 3.4/3.6: идентичный стиль не крутит
   ревизию; `setNeedsLayout` и `setNeedsDisplay` дают одинаковый путь вверх.
5. **`DisposeTests`** — правка 3.5: после `dispose()` колбэки обнулены.
6. **`RetryBudgetTests`** — правка 3.7: бесконечный retry обрывается,
   новая валидная инвалидация восстанавливает commit.
7. **`LogTests`** — выключенная область глушит вывод; при выключенной
   области `@autoclosure` **не вызывается** (проверяется побочным эффектом);
   `TRELLIS_LOG` разбирается корректно, включая `all`, `off` и список.
8. **`ZeroSizeTests`** — нода с фоном и нулевым размером печатает `ZERO-SIZE`.
9. **`LayerTreeTests`** (`TrellisRenderTests`) — **самый важный из новых**:
   дерево из 3–4 уровней прогоняется через `NodeHostBridge` на голом
   `CALayer` под macOS, тест читает `hostLayer.sublayers` и сверяет
   `frame` каждого слоя. Это весь конвейер (Node → snapshot → solver →
   coordinator → renderer → CALayer) **без симулятора и без устройства**.
   Он проверяет общий конвейер, но native view lifecycle, координаты AppKit
   и отображение требуют отдельных host/device проверок.

Дополнительно: просмотреть FlexSolverTests.swift, отсутствовавший в таблице.
Сигнатуры тестов адаптируются под throws/LayoutContext без отмены; прежние
геометрические ожидания сохраняются, пока не доказан отдельный баг.
Отмена тестируется отдельно: нет результата/commit, один solver, latest pending.
Reactive/lifetime и ранние perf fixtures определены в C29/C31 плана.

---

## 9. Линтер: что переносим и что добавляем

Линтер (`check_policy.py`) — то, что стоит перенести практически целиком.
Он детерминированный, на голой стандартной библиотеке, с негативными
фикстурами на каждое правило (`test_policy.py` + `Tests/PolicyFixtures/`)
— то есть сам линтер протестирован. Это редкость и это надо сохранить.

### Переносим

- `check_policy.py` целиком, 8 правил: `PLATFORM_IMPORT`,
  `PLATFORM_CONDITION`, `COCOA_LIFECYCLE`, `UNSAFE_CONCURRENCY`,
  `FORCE_OPERATION`, `PUBLIC_DOCUMENTATION`, `SECRET_*`, `MARKDOWN_LINK`.
- `test_policy.py` + все 8 фикстур из `Tests/PolicyFixtures/`.
- `check_api.py` + baseline (`trellis-public-api.json`).
- `check_all.py`, `verify_bootstrap.py`.
- `policy.json` → `policyVersion: "2.0.0"`,
  `platformImplementationPrefixes: ["Sources/TrellisUIKit/", "Sources/TrellisAppKit/"]`.
  Список из двух коротких файлов — правило `PLATFORM_IMPORT` теперь реально
  что-то сторожит, а не покрывает 3200 строк «разрешённого» кода.

### Правки при переносе

**П1. Разделить исходный текст и code-only представление** (3.9).
Для синтаксических swift-правил маскировать комментарии и literal text,
сохраняя строки, позиции и исполняемый код интерполяции. Проверить nested
comments, raw/multiline strings. PUBLIC_DOCUMENTATION, SECRET и TODO читают
исходный текст. Простой глобальный стриппер не удовлетворяет этому контракту.

**П2. `PUBLIC_DOCUMENTATION` — оставить как есть.** Требование четырёх
секций (Ownership/Isolation/Errors/Cancellation) на каждом публичном
объявлении — это то, почему кодовая база Weave читается спустя месяцы.
Раздувает файлы, но окупается. Не смягчать.

**П3. `check_api.py` нужно адаптировать, не просто переименовать baseline.**
Текущий скрипт знает единственный модуль Weave, macOS triple и paths к его
модулям. Новый явно перечисляет Core/Render/AppKit и UIKit с их SDK/paths.
Verifier также удаляет Flux/Package.resolved checks и старые target names,
переносит toolchain/formatter configuration. C04 не блокирует ранний срез,
но обязателен до завершения этапа. Обновление baseline отделено от проверки.

**П4. `PLATFORM_CONDITION` (запрет `#if os(`) — оставить и не ослаблять.**
Соблазн написать `#if os(macOS)` внутри общего кода теперь есть (два
хоста), и именно это правило заставит вместо ветвления вынести различие
в отдельный таргет. То есть правило прямо поддерживает архитектуру 3.11.

### Добавляем (новые правила)

**Н1. `TODO_OWNER`** — формат определить в C03. Рекомендация: стабильный
ID задачи вместо обязательной произвольной даты. Проверка использует исходные
комментарии, не code-only представление.

**Н2. `LINEAR_IDENTITY_LOOKUP`** — запрет паттерна
`.first { $0.identity ==` и `.first { $0.id ==` в `Sources/TrellisCore/Layout/`
и `Sources/TrellisRender/`. Это ровно находка 3.1: линейный поиск в горячем
пути. Правило узкое и точное, поэтому детерминированное.

**Н3. `RAW_PRINT` — НЕ добавляем.** В первой редакции этого плана правило
предлагалось (единственный легальный вывод — через `Trace`). После решения
«логгер = обычный `print`» оно теряет смысл: `Log.on` сам вызывает `print`,
и запрещать `print` ради обёртки над `print` — бюрократия. Вместо правила
линтера — договорённость: печатаем через `Log.on(_:_:)`, чтобы работало
`TRELLIS_LOG` и чтобы строки были в общем формате. Нарушение видно на
ревью, а не требует регулярки.

**Н4. `ADAPTER_PARITY` — НЕ нужен.** В первой редакции планировался (два
рендерера в Weave расходились, `AGENTS.md` про это прямо предупреждает).
После решения 3.11 — один нейтральный рендерер, расходиться нечему.
Хорошая иллюстрация принципа: правильная граница таргетов убирает целый
класс правил линтера.

---

## 10. Порядок работ — перенесён в план исполнения

Единственный действующий порядок и приёмки: [implementation-plan.md](implementation-plan.md),
разделы 4–5. Прежний линейный список шагов удалён, чтобы не конкурировать
с полными и минимальными приёмками тех же карточек.

Первый запуск — C01/C02 в минимальном объёме, C03, затем приёмки «срез»
C05–C20: один UIKit-host, S01/S10, одно физическое устройство. Сразу нужны
request trace, root safe area, strong root, один solver/pending latest,
throws cancellation и stale guards. Lifecycle-машина Node, API baseline,
полная матрица, EnvironmentScope и остальные сценарии завершаются позже
в тех же карточках. Teardown host/worker обязателен и в срезе.

DoD первой картинки: видимая вложенность, связный trace до CALayer,
живой root после attach и отсутствие stale/cancelled commit. Производительность
не блокирует первый запуск, но C31 следует сразу за рабочим конвейером.
Уже в срезе LayerTreeTests C17 через `swift test` на macOS проверяют общий
путь до CALayer без NSView и симулятора; iOS-приложение проверяет тот же
renderer на физическом устройстве. До полной C18 отложен AppKit-host,
а не проверка всего render-пути на macOS. Тип LayoutContext создаётся
в C06, применяется в C12 и подключается к отмене Task в C13.
C29 остаётся внутри первого этапа; C30 — ограниченный эксперимент, а не
утверждённая замена модели слоёв.

## 11. Решения: текущий статус

Принятые D01/D03/D09/D10 и ранний срез записаны в
[decisions.md](decisions.md). Остальные рекомендации и их
зависимости — в разделе 3 плана исполнения. Ниже сохраняется обоснование
части предложений, а не дополнительный список блокеров перед ранним срезом.

1. **`NodeID` вместо `ElementID`?** Сейчас `public typealias ElementID = UInt64`
   — сырой `UInt64`, любое число подходит по типу. Предложение:
   `struct NodeID: Sendable, Hashable` c приватным `rawValue`. Плюс:
   нельзя перепутать с `generation`/`revision`, которые тоже `UInt64`
   (в `RenderCoordinator` их четыре штуки рядом). Минус: чуть больше
   писанины. **Рекомендация: сделать.**

2. **`Node` — `open class` или `final class` + композиция?** Сейчас
   `open class` с восемью `open`-методами для наследования. Наследование уже нужно в этапе 1
   для arrangeSubnodes(), а позднее пригодится под Text/Image/Button.
   **Рекомендация: оставить `open class`** — доказавшая себя модель
   Texture, и менять её надо не в момент переезда.

3. **Имя `TrellisHostView` в обоих платформенных таргетах.** Один и тот же
   символ в `TrellisUIKit` и `TrellisAppKit` — приложение линкует ровно один
   из них, конфликта нет, а кросс-платформенный код приложения пишется без
   `#if`. **Рекомендация: одно имя.**

4. **Нормализация значений `LayoutStyle` после перехода на `var`** —
   `didSet` на полях или проверка в солвере. Разобрано в 5.1.
   **Рекомендация: `didSet`**, инвариант остаётся на типе, как у Texture.

5. **`SizeValue` как `ExpressibleByIntegerLiteral`/`FloatLiteral`** —
   `node.style.width = 100` вместо `.points(100)`. Разобрано в 5.1.
   **Рекомендация: добавить**, голое число значит точки во всех
   родственных системах (CSS, Yoga, Texture).

6. **Что хост отдаёт: `bounds` или весь `HostRenderRequest`?**
   Предложено (7.1) — три простых значения (`bounds`, `scale`, `insets`).
   Альтернатива — отдать хосту собирать `HostRenderRequest` целиком.
   **Рекомендация: три значения.** Тогда хост не знает про генерации и
   ревизии, и весь риск ошибки остаётся в тестируемом нейтральном коде.

---

## 12. Чего в этом плане сознательно нет

- **Grid-движок, `LayoutEngineKind`, `CustomEngineRegistry`** (§2 черновика)
  — этап 2, после того как flex подтверждён на железе. Спроектировать
  multi-engine поверх непроверенного flex — значит закрепить его ошибки в
  контракте. `Arrangement`/`arrangeSubnodes()` из того же раздела черновика,
  наоборот, **входит** в этап 1 — см. 2.6 и 5.2.
- **Реконсиляция по дескрипторам** (`Reconciler`, `NodeReconciliationController`,
  `ForEach`, `Node.compose()`) — этап 2, вместе с `Collections`, её
  единственным потребителем. Размен обоснован в 5.2.
- **Констрейнт в `arrangeSubnodes()`** и ветвление по измеренной ширине самой
  ноды — отдельный будущий контракт. Environment окна не подменяет ширину
  контейнера. LayoutContext закреплён за исполнением solver (D10).
- **`NodeBacking`/`NodeBackingFactory`/`PlatformHost`** (§3 черновика) —
  формализовывать контракт backing, когда backing один и тот же голый
  `CALayer` для всех нод, нечего.
- **Raster scheduler** (§3.5 черновика) — вернётся вместе с Text.
- **`CustomEngineRegistry`** (§4 черновика) — расширяемость до того, как
  есть второй движок, это спекуляция.
- **Кэш `LayoutInputSnapshot` по ревизиям** (§1.6 черновика) — оптимизация.
  Сначала пусть лог покажет реальные цифры, потом решать, надо ли.
- **Полноценный логгер** (sink'и, уровни, файлы, ротация) — вернётся, когда
  плагин перестанет строиться и начнёт использоваться. Сейчас `print`
  решает задачу целиком.
- **События, ввод, жесты** — ни одного `touch`/`mouse`/`press` в этапе 1.
  Ноды строятся и раскладываются; трогать их пока нельзя.

Всё перечисленное — не «отменено», а «после того, как на четырёх
устройствах надёжно строятся вложенные ноды». Именно это и было условием.
