# R13 — Pager и вкладки

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R13.
Зависимость: R09. Решение: [ADR 0036](../adr/0036-pager-and-tabs.md). Статус: **закрыта**.

Решения пользователя (2026-09-23):
- страницы двигает собственный pan pager (как в Telegram), а не нативный paging scroll view;
- смонтированы выбранная страница и по одной соседней с каждой стороны.

## Что реализовано

| Файл | Содержание |
|---|---|
| `Sources/TrellisCore/Pager/Pager.swift` | `Tab` (фабрика или готовая нода), `PagerProgress`, `PageState`/`PageStateRestoring`, `PagerPanRecognizer`, `PagerNode` |
| `Sources/TrellisCore/Pager/TabsNode.swift` | `TabsNode`, `TabsAppearance`: кнопки-`ControlNode`, индикатор от того же progress |
| `Sources/TrellisCore/Collections/CollectionNode.swift`, `TableNode.swift` | `pagePosition`/`restore(_:)`, состояние страницы (позиция чтения, выбор таблицы) |
| `Sources/TrellisCore/Scroll/ScrollTypes.swift`, `Collections/HostedContainer.swift` | `ScrollCommand.timed`, `ContainerHost.presentedScrollOffset` |
| `Sources/TrellisRender/Scroll/*`, `LayerAnimator.swift` | `scroll(to:animation:)` и `presentedContentOffset` у `NativeScrollBacking`; общий `makeAnimation` |
| `Sources/TrellisUIKit/Scroll/UIScrollViewBacking.swift`, `Sources/TrellisAppKit/Scroll/NSScrollViewBacking.swift` | timed-анимация offset с той же кривой, видимый offset, остановка при перехвате |
| `Playground/Shared/Scenarios/S38_PagerTabs.swift` | consumer: 5 страниц (3 простые, `ListNode`, `TableNode`), статус `r13-status` |
| `Playground/UITests/iOSScrollTests.swift`, `tvOSScrollTests.swift` | XCUITest: касания на iPhone, пульт на Apple TV |

## Пункты карточки

**Ленивые фабрики и вытеснение (P6.9).**
- Фабрика вызывается только при монтировании. Страница `c`, через которую перешли дальним
  `select`, не создаётся вовсе.
- Вытесненная лента пересоздаётся новой нодой (`made feed:2`) и возвращается в ту же позицию
  чтения:
  - bridge-тест: тот же якорь, ±0.5 pt;
  - iPhone Simulator: `feed=10@-7` до и после.
- Загруженные данные повторно не запрашиваются: `refreshes == 0`.
- Выбор строки `TableNode` тоже сохраняется при вытеснении.
- Фокус: выбранная страница никогда не вытесняется. Фокус, ушедший со страницы, забирает
  fallback движка фокуса. Память фокуса по страницам не хранится (ADR 0036).

**Стабильные ID, progress/selection, ввод.**
- Жесты и доводка:
  - drag идёт за пальцем, selection фиксируется только при отпускании;
  - за один жест — не больше одной страницы, у первой и последней страницы жёсткая граница;
  - медленный короткий drag возвращает страницу, быстрый flick листает;
  - pan, перехвативший доводку, продолжает от видимого offset;
  - detach во время pan возвращает на выбранную страницу.
- Изменения набора вкладок:
  - reorder сохраняет выбор по ID;
  - при удалении выбранной страницы выбирается страница на её индексе;
  - пустой набор — выбора нет.
- Ограниченное монтирование: выбранная ±1; до того как известна ширина — только выбранная.
- Ввод на платформах:
  - касания на iOS;
  - клик-drag на macOS;
  - пульт через вкладки на tvOS;
  - Return/Space/AX activate на вкладках.

**Индикатор, RTL, resize, Reduce Motion.**
- Индикатор интерполируется между кадрами кнопок `from`/`to` по тому же `fraction`. После
  отпускания он анимируется тем же `Animation`, что и offset страниц (та же CA-кривая в
  UIKit).
- RTL зеркалит жест и раскладку.
- Resize сохраняет страницу.
- Reduce Motion: доводка без анимации, вытеснение сразу.

## Найдено по ходу

- Первая реализация двигала полосу страниц трансформом слоя. На iPhone Simulator
  `UIScrollView` ленты остался на layout-позиции: он был виден за правым краем pager, и
  вертикальный drag его не прокручивал (`feed=0@0`). Причина общая — **#91**: нативный scroll
  view не следует трансформу и обрезке предка из Trellis. Pager переведён на собственный
  горизонтальный `ScrollNode`, после чего iOS UI-тест прокрутил ленту (`feed=10@-7`).
- **#90**: горизонтальный `ScrollNode` в RTL кладёт контент в отрицательные x, и все offset
  обрезаются до 0. Pager обходит это: в RTL у его scroll стоит `rowReverse`. Общее
  исправление не сделано.
- **#48** воспроизвёлся на подписях вкладок («Feed» → «Fe…» на iPhone Simulator). `TabsNode`
  растягивает подпись на всю кнопку и центрирует текст; после этого подписи целые.
- Две ошибки в собственном коде, исправлены до сдачи:
  - завершение движения приходило синхронно, до фиксации selection, и нормализация видела
    старую страницу;
  - `scrollTo` для восстановления позиции делал первый шаг без отступа.

## Проверки

**Bridge и платформы:**
- `PagerNodeHostTests`: 15 тестов на настоящем bridge. `AppKitPagerTests`: настоящий
  `TrellisHostView` и `NSScrollView`. Страница-лента вложена в scroll view pager (x = 300),
  видимый offset во время доводки лежит между 1 и 299 и приходит в 300.
- `PagerContractTests`: 2 теста — распознаватель (скорость, вертикальный отказ, вето) и
  перехват доводки от видимого offset.
- Мутации ловятся все шесть: RTL, восстановление, скрытие соседей из AX, заморозка скролла
  страниц, отказ при скролле страницы, перехват от видимого offset.
- iPhone 18 Pro Simulator, XCUITest с касаниями (`testPagerSwipeTabsAndFeedPositionAfterEviction`):
  - swipe листает страницу;
  - вертикальный диагональный drag прокручивает ленту и страницу не меняет;
  - горизонтальный drag по строке таблицы листает pager, а действия строки не открываются
    (`action=none`);
  - вытесненная лента восстанавливается.

  Все 5 iOS UI-тестов проходят.
- Apple TV 4K Simulator, `XCUIRemote` (`testRemoteSelectsPagesThroughTabs`): фокус идёт по
  вкладкам, `select` открывает страницу, `down` уводит фокус в строку таблицы. Все 3 tvOS
  UI-теста проходят.
- macOS: S38 в настоящем окне — ширина 688, смонтированы `a` и `feed`.

**Сводная таблица:**

| Проверка | Результат |
|---|---|
| `swift format lint -r` | чисто |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| TrellisCoreTests / TrellisFluxTests | 555 / 32 — все зелёные |
| TrellisRenderTests (частями) | 216 + 42 + 37 + 61 = 356; в группе m1 один раз упал `m12_…` (#82), отдельно 3/3, группа при повторе зелёная |
| `swift build --build-tests -Xswiftc -warnings-as-errors` | чисто |
| `check_api.py` (5 модулей) | PASS; baseline TrellisCore (+70) и TrellisRender (+5) по ADR 0036 |
| Playground: macOS, iOS Simulator, tvOS Simulator | собираются |

## Не закрыто (явно)

- Двухпальцевый swipe трекпадом на macOS не листает страницы: Trellis не маршрутизирует
  события колеса. На macOS страницы переключаются клик-drag и вкладками.
- У первой и последней страницы нет rubber band.
- На AppKit spring-кривая доводки заменена ease-out той же длительности.
- Память фокуса по страницам не хранится.
- Замеры кадров во время pan не сняты (класс R06 §6). Эталон скриншота S38 не добавлен:
  gate сломан (#83).
- `TabbedScrollNode`, сворачиваемая шапка и вертикальная координация — R14.
