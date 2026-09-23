# R14 — Collapsing header и интеграция профиля (этап 1)

Статус на 2026-09-23: **этап 1 написан и собирается; тесты проверены частично.** Код написан
в облачной сессии на Linux без Swift и Xcode (`download.swift.org` закрыт сетевой политикой
окружения); сборка и тесты — на Mac пользователя по списку в разделе «Проверки». Карточка не
закрыта; этап 2 (передача инерции) не начат.

Прогоны пользователя (macOS, arm64):
- `swift build --build-tests -Xswiftc -warnings-as-errors` — чисто, с первой попытки.
- `swift test --filter test_tabbed_` — 10 из 13. Три падения — ошибка самих тестов, не узла:
  `#expect(height == 640 - 44)` сравнивал `Double` 596.0 с `Int` 596, потому что макрос
  проверяет операнды по отдельности и выражение справа получило тип `Int`. Высоты были верными
  (566.0, 546.0, 596.0). В проверках теперь готовые числа; повторный прогон ещё не выполнен.

Решение: [ADR 0037](../adr/0037-tabbed-scroll-coordination.md) (вариант Telegram), разбор
референса — [telegram-peerinfo-analysis.md](../telegram-peerinfo-analysis.md).

## Что написано

| Файл | Содержание |
|---|---|
| `Sources/TrellisCore/Pager/TabbedScrollNode.swift` | `TabbedScrollNode`, `TabsPlacement`, `TabsConfiguration`, `PageScrollProviding` (+ `CollectionNode`, `ScrollNode`) |
| `Sources/TrellisCore/Collections/HostedContainer.swift` | `ContainerHost.applyScrollConfiguration(of:)` с пустой реализацией по умолчанию |
| `Sources/TrellisRender/Scroll/NodeHostBridge+Containers.swift` | реализация: конфигурация сразу в нативный backing |
| `Sources/TrellisCore/Pager/Pager.swift` | заморозка страниц на время pan применяется сразу (#93) |
| `Sources/TrellisCore/Pager/TabsNode.swift` | внутренний хук `handlesActivation` для нажатия на текущую вкладку |
| `Sources/TrellisAppKit/Scroll/NSScrollViewBacking.swift` | выключенный scroll view передаёт колесо по цепочке responder'ов |
| `Tests/TrellisRenderTests/TabbedScrollNodeHostTests.swift` | 13 тестов на bridge с записывающими backing'ами |
| `Tests/TrellisRenderTests/AppKitTabbedScrollTests.swift` | колесо выключенного `NSScrollView` доходит до superview |
| `Playground/Shared/Scenarios/S39_TabbedProfile.swift` | сцена: шапка во весь экран, Media (grid), Files (table), Links (короткий list) |

## Пункты карточки

| Пункт | Состояние |
|---|---|
| TabbedScrollNode/Tab/TabsNode, `.pinned`/`.inline`, row swipe выключен в pager | написано; row swipe — через `RowSwipeContextKey` pager'а (ADR 0036), отдельно не проверялось |
| Композиция §1.1, три типа страниц, ~1.5H | написано (S39, тесты: блок = viewport ниже линии закрепления) |
| Блокировка страниц до закрепления, немедленно, UIKit/AppKit, AX и колесо | написано: немедленное применение, колесо на macOS; **AX scroll на заблокированной странице не проверен и не специфицирован** |
| Позиции страниц по ADR 0037 §6 | написано и покрыто тестами (сброс только выбранной, закрепление при выборе глубокой, восстановленная страница) |
| Reveal/focus при раскрытой шапке сначала закрепляет вкладки (§7) | для программного reveal — через правило «выбранная страница глубоко → закрепить»; **фокус на tvOS не проверен**: ожидается, что reveal фокуса дойдёт до внешнего scroll, т. к. заблокированная страница его отклоняет |
| Этап 2: передача инерции | не начат |
| Refresh/pagination по одному владельцу | refresh внешнего scroll не подключён: у `ScrollNode` нет своего refresh-контрола; pagination остаётся у контейнеров страниц. **Открыто** |
| Consumer без ручной синхронизации offset/KVO | S39 не содержит такого кода |

## Найдено по ходу

- #92 (открыт): нативный scroll view не упорядочивается среди соседних слоёв Trellis —
  причина отказа от варианта «шапка поверх страниц». Найден чтением кода.
- #93 (исправлен этим изменением): изменение `ScrollNode.configuration` доходило до нативного
  view только на следующем commit; смещение прокрутки commit не вызывает. Найден чтением кода,
  тестом до исправления не воспроизводился.
- Корень дерева учитывает safe area в своих отступах, а environment потомков содержит safe area
  хоста без изменений. Поэтому линия закрепления по умолчанию считается по кадрам — какая часть
  safe area хоста действительно попадает во viewport (ADR 0037, раздел API). Тот же эффект, вероятно,
  даёт двойной отступ у `ScrollNode` с `insetsSafeArea == true` внутри корня с отступами; не
  проверялось, в реестр не внесено до проверки.

## Проверки (выполнить на Mac)

Выполнены пункты 1 и часть пункта 2 (см. статус выше); остальное не запускалось.

1. `swift build --build-tests -Xswiftc -warnings-as-errors`
2. `swift test --filter test_tabbed_` и `swift test --filter r14_`, затем полный `swift test`
   (затронуты `PagerNode`/`TabsNode` — тесты R13 `test_pager_*` обязательны)
3. `swift format lint -r Sources Tests Playground`
4. `python3 Scripts/check_policy.py` — в облачной сессии: PASS, 0 diagnostics
5. `python3 Scripts/check_api.py --update --review-note docs/adr/0037-tabbed-scroll-coordination.md`,
   затем `python3 Scripts/check_api.py --tvos` — baseline не обновлён
6. `python3 Scripts/check_all.py --matrix` (UIKit-тесты — только на Simulator)
7. Playground S39 (`--scene S39_TabbedProfile`) на iPhone Simulator, Apple TV Simulator, macOS:
   - drag по странице при раскрытой шапке сначала сворачивает шапку, страница стоит;
   - вкладки закрепляются под status bar, затем прокручивается страница;
   - бросок из раскрытой шапки останавливается на линии закрепления (этап 1 — ожидаемо);
   - позиции Media/Files сохраняются при переключении при закреплённых вкладках;
   - drag по полосе вкладок вниз раскрывает шапку; выбранная страница уходит наверх,
     остальные сохраняют позицию;
   - выбор страницы с глубокой позицией при раскрытой шапке закрепляет вкладки;
   - нажатие на текущую вкладку: при раскрытой шапке — закрепить, при закреплённой — страницу
     наверх;
   - диагональные жесты: горизонтальный свайп не двигает шапку, вертикальный не листает;
   - Links (короткая): шапка сворачивается, под списком пустое место;
   - Files: swipe строк не открывает действия; VoiceOver custom action «Delete» работает;
   - macOS: колесо/трекпад над страницей при раскрытой шапке двигает шапку;
   - tvOS: фокус вниз в строки страницы сначала закрепляет вкладки.

## Не закрыто (явно)

- Этап 1 собирается; полный `swift test`, `r14_`, тесты R13 и Playground ещё не прогнаны.
- Этап 2 (передача инерции, ADR 0037 §5) не начат.
- AX scroll и tvOS focus на заблокированной странице — не проверены, маршрут не специфицирован.
- Refresh внешнего scroll не подключён.
- XCUITest для S39 не написан; эталон скриншота S39 не добавлен (gate сломан, #83).
- `api/*.json` не обновлён.
