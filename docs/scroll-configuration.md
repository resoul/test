# Конфигурация ScrollNode и общих контейнеров — спецификация (предложение)

Специфицирует §1.2 [implementation-plan-6.md](implementation-plan-6.md) для карточки
R06. Это **предложение**, не D-решение: имена/defaults/платформенная поддержка ниже
предлагаются для обсуждения и фиксируются в [decisions.md](decisions.md) отдельным
D-номером только после явного согласия пользователя, как и остальные P6-контракты
плана 6. Ничего здесь не реализовано в `Sources/`.

Опирается на прочитанный контракт `Scroll.swift` ([weave-scroll-analysis.md](weave-scroll-analysis.md))
и на архитектурный прототип [r06-scroll-contract.md](validation/r06-scroll-contract.md)
(native embedding). Формулировки P6.3/P6.5 плана 6 не переписываются — здесь они
разворачиваются в конкретные поля/defaults/таблицу платформ.

## 1. Область действия

Общая конфигурация применяется к трём поверхностям одинаково: standalone `ScrollNode`,
`ListNode`/`GridNode`/`TableNode` (переиспользуют её как есть, §1.2 плана), и
`TabbedScrollNode`'s собственному верхнеуровневому scroll. Настройки специфичные для
контейнеров данных (§1.2 «для контейнеров данных») и специфичные для pager
(«для pager») — отдельные секции ниже, не часть общей конфигурации.

## 2. Общая конфигурация (`ScrollConfiguration`, эскиз)

```swift
public struct ScrollConfiguration: Sendable, Hashable {
    public var axis: ScrollAxis = .vertical
    public var userInteractionEnabled: Bool = true
    public var directionalLockEnabled: Bool = false
    public var indicators: ScrollIndicatorPolicy = .automatic
    public var contentInsets: DirectionalEdgeInsets = .zero
    public var insetsSafeArea: Bool = true
    public var bounce: ScrollBouncePolicy = .automatic
    public var keyboardDismissMode: KeyboardDismissPolicy = .none
}
```

Имена — эскиз для обсуждения, не финал; порядок полей произвольный. Ниже — что
означает каждое default-значение и почему оно выбрано, не просто список типов.

### 2.1. Axis, directional lock, indicators

- `axis: .vertical` по умолчанию — совпадает с Weave (`ScrollAxis` default в
  `Scroll.swift`) и с типичным первым потребителем (лента).
- `directionalLockEnabled: false` — Weave этого понятия не имело вообще (его
  `arbitrate` — межнодовый арбитраж, не lock внутри одного `.both` скролла);
  предлагается ввести отдельно от `axis: .both`, потому что «два независимых
  направления сразу» (diagonal pan) и «одно из двух, определяется первым
  движением» — разные, наблюдаемые пользователем поведения, и Telegram-видео
  (implementation-plan-6.md §1.1.1) явно показывает второе на pager. Default
  `false` (оба направления сразу для `.both`) сохраняет сегодняшнее поведение
  Weave, где такого различия не было.
- `indicators: .automatic` — системные `UIScrollView`/`NSScrollView` индикаторы
  включены, кроме tvOS (где системных scroll-индикаторов в привычном виде нет
  — remote-driven focus заменяет прокрутку жестом). `.automatic` разворачивается
  в конкретное bool/pair на каждой платформе в момент реализации, не хранится
  как непрозрачный enum без документированного платформенного значения.

### 2.2. Insets и safe area

- `contentInsets: .zero`, `insetsSafeArea: true` — safe area учитывается **ровно
  один раз** (P6.3's explicit requirement), т.е. `contentInsets` и системный safe
  area складываются, а не дублируются: итоговый inset = `contentInsets +
  (insetsSafeArea ? safeArea : .zero)`, по той же directional-edge модели, что уже
  использует `Node.setSafeAreaInsets`/`DirectionalEdgeInsets` (не отдельная
  RTL-нечувствительная left/right пара).
- Явный `insetsSafeArea: false` — это выход из-под системного contentInsetAdjustment
  (`UIScrollView.contentInsetAdjustmentBehavior = .never` эквивалент), не просто
  игнорирование значения на уровне Trellis: если Trellis сам прибавляет safe area
  поверх системного адаптивного поведения, получится двойной inset — тот самый
  «дважды» что параграф явно запрещает.

### 2.3. Bounce/overscroll и native deceleration

- `bounce: .automatic` — `true` на iOS/iPadOS/macOS (trackpad), `false` на tvOS
  (нет физического жеста, которому бы bounce был обратной связью). `.always`/
  `.never` — явные переопределения для контента короче viewport (Weave's
  `EdgePullConfiguration` уже различало elastic-без-запроса и action-режимы;
  здесь это заменяется системным bounce плюс отдельно specified pull-to-refresh
  §2.6, не смешанные в один enum, как было в Weave).
- Deceleration/momentum — **не** конфигурируется отдельным полем: он целиком
  системный (`UIScrollView.decelerationRate`/`NSScrollView`'s native inertia).
  Прототип [r06-scroll-contract.md](validation/r06-scroll-contract.md) уже
  показал, что Trellis не должен и не может участвовать в самой физике —
  экспонировать `decelerationRate` как поле Trellis означало бы владеть тем,
  чем P6.3 явно запрещает владеть.

### 2.4. Programmatic scroll/reveal + анимация

- `scrollTo(_:animated:)`/`reveal(_:alignment:animated:)` — синхронная команда,
  `animated` включает системную анимацию скролла (`UIView.animate`-подобный путь
  на `setContentOffset(_:animated:)`/`NSScrollView`'s собственный animator proxy),
  не `Node.animate` (D61–D69) — offset не входит в шесть анимируемых свойств
  `LayerAnimator` и не должен: это чужая система координат (native scroll layer,
  см. прототип). `animated: false` по умолчанию для программных reveal,
  вызванных не по прямому действию пользователя (совпадает с P6.9's
  `scrollTo(itemID:)`, которое отдельно специфицирует completed/cancelled/notFound).
- Начатая программная команда отменяется пользовательским вводом (тач/wheel
  начинает новый жест) — не наоборот; P6.3 явно требует «отмена programmatic
  scroll пользовательским вводом» (R08's приёмка), здесь это фиксируется как
  правило конфигурации, не только тестового сценария.

### 2.5. Сохранение/восстановление позиции, resize, смена данных

- Logical offset — `ScrollState`-подобный snapshot (Weave's поле уже верно
  формализовано, см. weave-scroll-analysis.md §2) сохраняется хостом сессии
  (D14-style owner), не самим ScrollNode как singleton — совпадает с P6.9's
  «page model, anchor и selected page сохраняются владельцем экрана при
  eviction UI».
- Resize/сжатие контента: clamp с сохранением anchor (P6.3), не сброс в 0.
  Явно: если logical offset ссылается на позицию, которой больше не существует
  (контент стал короче), новый offset = `min(offset, max(0, newContentLength -
  viewportLength))`; anchor item ID (для списков — P6.4) имеет приоритет над
  голым числом offset, когда обе стратегии доступны.
- Смена данных (для списков/pager) не входит в общую `ScrollConfiguration` —
  она в P6.4/P6.9's контракте anchor/estimated height; здесь фиксируется только
  то, что ScrollNode сам по себе (без данных) не имеет мнения о том, что такое
  «данные изменились».

### 2.6. Refresh и загрузка у границ (когда применимо)

- `edgeLoad: EdgeLoadConfiguration?` (nil по умолчанию — обычный `ScrollNode`
  без данных этого не имеет; `ListNode`/`GridNode`/`TableNode`/pager задают
  своё значение) — pull-to-refresh на leading edge, load-more на trailing —
  тот же elastic/action контраст, что Weave's `EdgePullConfiguration`, но без
  смешивания indicator-presentation с pagination policy (P6.8 отдельно решает
  page size/trigger).
- Loading/empty/error представления — не поле `ScrollConfiguration`, а
  свойство контейнера данных (P6.4's `emptyStateNode`/`loadingStateNode` в
  Weave уже был такой паттерн, переносим как направление, не как код).

### 2.7. Клавиатура и AX reveal

- `keyboardDismissMode: .none` — на iOS/iPadOS `.interactive`/`.onDrag`
  доступны как явный выбор (Weave не имел этого понятия вовсе — Control/text
  input были вне scope этапов, где жил `Scroll.swift`); на tvOS/macOS
  игнорируется (нет экранной клавиатуры, которая перекрывала бы контент так же).
- Focus/AX reveal — не поле здесь: это `reveal(frame:alignment:)`'s
  responsibility, вызываемое из focus engine/AX activation (D38-style), не
  отдельная конфигурация видимости.

## 3. Платформенная поддержка

| Поле | iOS/iPadOS | tvOS | macOS |
|---|---|---|---|
| `axis` | полная | полная (focus определяет direction, не жест) | полная |
| `directionalLockEnabled` | да | н/п (нет диагонального жеста) | да (trackpad) |
| `indicators` | системные | нет системных — диагностика вместо визуала | системные (auto-hide) |
| `contentInsets`/`insetsSafeArea` | полная | safe area = overscan-safe area | полная |
| `bounce` | да (elastic) | нет | да (только trackpad/API, не всегда физически ощутимо) |
| `keyboardDismissMode` | полная | н/п | н/п (нет экранной клавиатуры, скрывающей контент так же) |
| `edgeLoad` (pull-to-refresh) | да (touch) | нет прямого жеста — alternative по P6.6's «menu/AX» прецеденту | да (trackpad two-finger, где доступно) |
| Programmatic scroll/reveal | да | да (единственный путь ввода для tvOS) | да |

«н/п» — не диагностируется как ошибка конфигурации (не exception/crash), а
задокументированная точка, где платформа не может выполнить желаемое: значение
принимается, эффекта не производит, диагностируется через `Log.on` в области
`schedule`/`event`, не молчаливо.

## 4. Изменение настроек во время активного движения

Явное правило для каждого поля, которое не следует «применить и ничего не
сломать» само собой — то, что implementation-plan-6.md §1.2 называет
«параметры с платформенными ограничениями имеют явную поддержку/диагностику»:

| Изменение во время `isScrolling == true` | Поведение |
|---|---|
| `axis` | Откладывается до конца текущего жеста/деселерации — смена оси посреди native-driven момента не имеет согласованного native-эквивалента ни на одной платформе; применяется на следующий `updateViewport`/committed кадр после `isScrolling` возвращается в `false`. |
| `directionalLockEnabled` | Немедленно, но не ретроактивно: уже определённое направление текущего жеста не меняется, только следующий жест видит новое значение (совпадает с тем, как `UIScrollView.isDirectionalLockEnabled` уже ведёт себя нативно). |
| `contentInsets`/`insetsSafeArea` | Немедленно, offset корректируется тем же clamp-with-anchor правилом §2.5 — momentum не обнуляется, но целевая точка деселерации может сместиться (native-корректное поведение, не Trellis-специфичное). |
| `bounce` | Откладывается до конца жеста — так же, как `axis`: включение/выключение elastic-эффекта посреди уже начавшегося overscroll не имеет согласованного визуального результата. |
| `indicators` | Немедленно — чисто визуальное, не взаимодействует с физикой. |
| `edgeLoad` | Немедленно для новых demand; уже отправленный in-flight запрос не отменяется сменой конфигурации (P6.7's own cancellation правила остаются отдельным механизмом). |

Отмена/детач во время активного движения — не тема этой таблицы (см. P6.3's
«cancel, unmount и dispose invalidate scrolling and demand revisions», уже
принято текстом плана).

## 5. Проверка примера: верхний Node 0.5H + pager 1H

Плановый пример implementation-plan-6.md §1.1: верхний блок ≈0.5H, pager ≈1H,
суммарная высота TabbedScrollNode ≈1.5H экрана. Проверка, что общая
конфигурация ScrollNode это не запрещает и не требует специального случая:

- **Верхний Node** — обычный layout-контент без своего `ScrollConfiguration`
  (§1.1: «это обычная композиция Node со своими детьми»). Его высота — результат
  обычного flex-измерения; 0.5H не константа, а следствие реального контента
  (аватар/имя/статы/описание), что и говорит пример плана явно.
- **Внешний scroll** (TabbedScrollNode) видит content length = высота верхнего
  Node + высота pager (1H), т.е. ≈1.5H, что больше viewport (1H экрана) —
  корректный, ожидаемый overscroll-able контент, `bounce`/`indicators` работают
  как для любого длинного контента, без особого случая.
- **Pager** имеет **свой собственный**, отдельный `ScrollConfiguration`
  на каждой странице (`ListNode`/`GridNode`/`TableNode`) с **конечной**
  высотой viewport = 1H (не суммой строк — явное требование §1.1: «нельзя
  измерять pager по полной высоте всех его строк»). Значит `ScrollConfiguration`
  здесь применяется **дважды в одной композиции с разной ролью**: один раз для
  внешнего scroll (content length динамический, растёт с контентом), один раз
  для внутреннего (content length от viewport pager'а, не от внешнего). Это не
  противоречие конфигурации — оба независимо валидны, но означает, что
  `directionalLockEnabled`/`axis` для внешнего (vertical) и внутреннего
  (vertical у страницы, horizontal у самого pager-свайпа между страницами)
  задаются раздельно, не наследуются автоматически родителем.
- **Арбитраж вертикали снаружи/внутри** (внешний ScrollNode vertical vs
  ListNode/TableNode's тоже vertical) — не решается этой конфигурацией; это
  прямо P6.3's «арбитраж внешнего и внутреннего scroll уточняется отдельно» и
  R09's чек-лист («direction lock, ближайший eligible scroll»). Здесь
  фиксируется только то, что оба уровня используют один и тот же тип
  `ScrollConfiguration`, не два разных API для «внешнего» и «внутреннего» скролла.
- Численно: если верхний блок реально измеряется в 0.5H (например, 390pt на
  iPhone 844pt viewport → 422pt), а pager получает оставшиеся 844pt (не
  видимый остаток 422pt — §1.1 явно требует «pager не должен автоматически
  сжиматься до остатка первого экрана»), суммарная content length внешнего
  scroll = 422 + 844 = 1266pt (>844pt viewport, корректно прокручиваемо), а
  pager's собственный viewport остаётся 844pt независимо от того, сколько уже
  проскроллено снаружи. Проверка не находит числового противоречия в этой
  композиции с текущим эскизом `ScrollConfiguration`.

## 6. Открытые пункты (не решены этим документом)

- Точный enum `ScrollIndicatorPolicy`/`ScrollBouncePolicy`/`KeyboardDismissPolicy`
  — здесь только словесные default'ы, не финальные Swift-типы (это — задача
  формализации P6.3 как контракта, следующий пункт чек-листа R06, не этот).
- `EdgeLoadConfiguration`'s точные поля (elastic/action, threshold, indicator)
  — предложение выше повторяет форму Weave's `EdgePullConfiguration`
  структурно, но точные значения threshold/resistance не пересчитаны для
  Trellis; P6.7/P6.8 решают семантику, не эту спецификацию.
- Арбитраж между внешним и внутренним scroll (§5's последний пункт) —
  R09, не R06.
- Иerarchия конфигурации: наследуется ли `indicators`/`bounce` от родительского
  `TabbedScrollNode` к странице по умолчанию, или каждая страница обязана
  указать свою — не решено; вероятный ответ (каждая страница — своя
  конфигурация, без implicit inheritance) не проверен on a real composition.
