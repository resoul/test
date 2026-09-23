# Trellis — план 6: Flux, ScrollNode и большие экраны

Дата: 2026-09-14. Статус на 2026-09-23: R01–R09 закрыты (результаты A и B);
R10–R11, R12a–R12c, R13 закрыты; R12 (закрытие C) закрыта частично (нет числовых бюджетов на устройстве); R14 в работе (этап 1 написан, не собран); R15 не выполнена. Подключение собственной библиотеки Flux и создание
ScrollNode — цель пользователя. Имена новых API и решения P6 ниже — предложения,
а не изменения уже принятых D01–D74. Этот документ не объявляет зависимость
подключённой и не заменяет [decisions.md](decisions.md).

Ориентация для исполнителя R-карточек: сначала AGENTS.md и decisions.md,
затем **карточка этого плана**, её зависимости и evidence, затем weave-analysis.md
и источники §3. Ссылка AGENTS.md на implementation-plan.md описывает исходные
C-карточки; R01–R15 (включая R12a/b/c) выполняются по плану 6. Перед началом
реализации R01 обновить навигацию AGENTS.md на планы по префиксам карточек;
не объявлять предложенные P6-контракты принятыми D-решениями автоматически.

## 1. Результат и порядок

Целевой экран — профиль: сворачиваемая шапка, закреплённая полоса вкладок,
горизонтальное перелистывание, независимая вертикальная позиция каждой страницы.
Данные приходят через Flux; обновления, догрузка и удаление строк сохраняют
позицию чтения. Большая страница не создаёт ноды для всех элементов заранее.

План имеет четыре отдельно проверяемых результата:

| Результат | Состав | Карточки |
|---|---|---|
| A | Flux как SPM-зависимость, доставка состояния и владение эффектами | R01–R05 |
| B | ScrollNode с настоящей нативной прокруткой и корректными координатами | R06–R09 |
| C | ListNode, GridNode, TableNode на общей виртуализированной основе | R10–R12 |
| D | Профиль с общей шапкой, вкладками и страницами на общей основе | R13–R15 |

Сначала A и B; затем C; затем D. Ранний прототип профиля в R06 проверяет,
что scroll-архитектура допускает композицию, но не заменяет приёмку D.
ScrollNode сам по себе не закрывает большие списки. Базовый список C не закрывает
весь N05: универсальный descriptor reconciliation, произвольные grid-solvers,
drag-reorder остаётся отдельным расширением. Swipe actions TableNode входят в C. N07 целиком также не закрывается.

### 1.1. Уточнение пользователя: общий scroll и вложенные страницы

Зафиксировано и уточнено с пользователем 2026-09-14. Композиция, названия
TabbedScrollNode/ListNode/GridNode/TableNode и режимы tabs согласованы как
направление API. Точные сигнатуры и физика paging ещё требуют спецификации.
Принятые D-контракты этим документом не изменяются.

Ожидаемая логическая структура (не решение о числе нативных scroll views):

```text
TabbedScrollNode — общая прокрутка и координация страниц
├── Node — произвольный верхний блок, например профиль
│   └── дочерние Node; высота определяется их реальной раскладкой
└── pager
    ├── TabsNode: segmented, placement .pinned / .inline
    └── страницы со своим содержимым
        ├── ListNode
        ├── GridNode
        └── TableNode
```

Верхний блок не ограничен специальным типом header: это обычная композиция
Node со своими детьми. Ниже находится полноценный pager со страницами и
segmented-переключателем. Разные страницы могут использовать разные контейнеры
данных. ListNode/GridNode/TableNode должны быть доступны и вне pager.

Суммарная высота верхнего Node и pager может составлять примерно **150% высоты
экрана**: например, верхний блок 0.5H и pager 1H. Это пример, не фиксированный
коэффициент. Учитывается вся рассчитанная высота верхнего Node с детьми;
pager не должен автоматически сжиматься до остатка первого экрана. Его viewport
имеет конечную высоту, а длинное содержимое страницы прокручивается внутри него.
Нельзя измерять pager по полной высоте всех его строк — это уничтожит виртуализацию.
Включает ли высота pager segmented-полосу и как учитывать safe area/закрепление —
решено в [ADR 0037](adr/0037-tabbed-scroll-coordination.md) §1–§2: блок «вкладки +
pager» ровно в высоту viewport ниже линии закрепления (верх viewport после
insets/safe area).

Визуальные ориентиры пользователя: экран настроек Twitter и профиль Instagram,
а также ProfilePage-main, TabBarPager и XLPagerTabStrip из §3. Это описание
желаемого взаимодействия, не утверждение об используемых этими приложениями
библиотеках. Скриншоты/видео пользователь может предоставить при обсуждении
жестов и paging; для фиксации этой композиции они не требуются.

### 1.1.1. Видео Telegram — конкретный референс композиции

Пользователь предоставил `IMG_2378.MP4` (локальный оригинал:
`/Users/resoul/Desktop/IMG_2378.MP4`, длительность около 10.43 с) и указал
Telegram/Display как источник реализации. Просмотрена последовательность кадров
через 0.5 с; таймкоды ниже приблизительные, не замер физических параметров жеста.
Видео не копируется в репозиторий; воспроизводимые тестовые данные должны быть
синтетическими, без содержимого аккаунта из записи.

- Начало — верхний профиль с изображением/именем, действиями и информационными
  блоками; ниже segmented Media / Files / Links и контент выбранной страницы.
- Примерно 0–3 с — верхние блоки смещаются вверх, область страниц занимает всё
  большую часть viewport. Верх профиля может менять своё представление при collapse.
- Примерно 3–4.5 с — смена media grid на файлы и ссылки; виден промежуточный
  горизонтальный сдвиг соседних страниц, общий верхний блок остаётся частью экрана.
- Примерно 5–7.5 с — верхние информационные блоки уходят, segmented находится
  под navigation bar, список ссылок продолжает вертикально прокручиваться.
- Примерно 8–10 с — возвращение к файлам и раскрытому верхнему профилю.

Это уточняет ожидаемый результат D: единая воспринимаемая вертикальная прокрутка
профиля и выбранной страницы, закрепление segmented и смена типа содержимого
страницы без отдельного экрана. По записи нельзя установить точный момент касания,
порог direction lock, правила передачи momentum или сохранение позиции всех
неактивных страниц. Эти пункты остаются предметом обсуждения paging и проверки
исходников, а не считаются подтверждёнными видео.

Найдены конкретные места локальной реализации Telegram (пути от корня Trellis):

- `../old/Telegram-iOS/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift`:
  импортирует Display, добавляет paneContainerNode в scrollNode; связывает
  requestExpandTabs/currentPaneUpdated/paneDidScroll с общей областью прокрутки.
- `../old/Telegram-iOS/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoPaneContainerNode.swift`:
  импортирует Display; panGesture вычисляет transitionFraction из горизонтального
  смещения, двигает panes и обновляет переключатель через updateTabSwitchFraction.
- `../old/Telegram-iOS/submodules/TelegramUI/Components/PeerInfo/PeerInfoPaneNode/Sources/PeerInfoPaneNode.swift`
  и каталог `Panes/` рядом с PeerInfoScreen — интерфейс страниц и их
  scroll-контракты. Разбор выполнен 2026-09-23 по upstream `6ad963e`:
  [telegram-peerinfo-analysis.md](telegram-peerinfo-analysis.md) (владение
  жестом, передача инерции, позиции страниц, расхождения с ADR 0029 и P6.5).

Display — фундамент UI, а композиция профиля/pager находится в TelegramUI поверх
него. R06/R13/R14 должны изучить оба слоя. Наличие похожего кадра не доказывает,
что локальный checkout совпадает с версией приложения из записи.

### 1.2. Настройки scroll и контейнеров

Заложить единую конфигурацию ScrollNode, переиспользуемую ListNode/GridNode/
TableNode и страницами pager. Публичные имена и defaults определяются в R06;
параметры с платформенными ограничениями имеют явную поддержку/диагностику.

- Ось, включение пользовательской прокрутки, directional lock, indicators,
  content insets и политика safe area, bounce/overscroll, native deceleration.
- Programmatic scroll/reveal и анимация, сохранение/восстановление позиции,
  реакция на resize и изменение данных, keyboard/focus/AX reveal.
- Refresh и загрузка у границ, preload distance и лимиты кэша/материализации;
  loading/empty/error представления и повтор запроса.
- Для композиции профиля: размеры верхнего блока/pager, режим закрепления
  segmented-полосы, предел сворачивания шапки, сохранение позиции каждой страницы.
- Для pager: доступность swipe и выбора сегментом, политика соседних страниц,
  индикатор/progress; арбитраж внешнего и внутреннего scroll уточняется отдельно.
- Для контейнеров данных: spacing/insets, секции и supplementary nodes;
  GridNode — колонки/размеры ячеек; TableNode — параметры строк и секций.

Согласованные названия и назначение:

| Тип | Назначение |
|---|---|
| ListNode | Лента произвольных элементов, карточки переменной высоты |
| GridNode | Сетка с настройками колонок и размеров ячеек |
| TableNode | Строки/секции, separators, selection и swipe actions; не spreadsheet |

Все три принимают произвольные Node как содержимое элемента. Header/другие
supplementary nodes задаются композицией. Общий профиль с tabs оформляется
TabbedScrollNode, а не тремя отдельными надстройками над каждым видом списка.
Общие state, lifecycle, scroll mechanics, IDs и data transactions не дублируются
тремя независимыми реализациями.

## 2. Что уже есть и где выполняется работа

По исходникам на дату плана:

| Работа | Сейчас в Trellis | Следствие для больших экранов |
|---|---|---|
| Создание/изменение Node, Arrangement, сбор снимка | MainActor | Нельзя создавать 10 000 нод и считать эту работу фоновой |
| Решение layout | LayoutScheduler запускает worker; solver работает на отдельном Thread | Работает с immutable Sendable snapshot, не с live Node |
| Raster текста | DisplayScheduler запускает Task.detached | Ограниченная конкурентность, отмена и проверка актуальности остаются обязательны |
| Commit, CALayer, input, focus/AX, нативные views | MainActor | Стоимость надо ограничить видимой областью и измерять |
| Потоки Flux | Зависит от source/operator/executor | Сам факт подписки не переносит пользовательское вычисление в фон |

Источники: `Sources/TrellisCore/Layout/LayoutScheduler.swift`,
`Sources/TrellisRender/Display/DisplayScheduler.swift`, D01/D03/D13/D14.
Сходство с Texture — ноды, асинхронный layout/display, подготовка до показа.
Различие принципиальное: Texture допускает создание и конфигурацию иерархий
на фоновых потоках (`../old/Texture/README.md`); Trellis сохраняет live tree
на MainActor. Менять эту границу ради похожести не предлагается.

Для длинного экрана нужны вместе: фоновые вычисления, ограниченные очереди,
виртуализация, предзагрузка и небольшой MainActor commit. Фоновый solver один
не является обещанием плавности ни на 60, ни на 120 Hz.

## 3. Источники и что из них берём

Пути ниже относительно корня Trellis; исследованы локальные исходники, а не
актуальные upstream-релизы. Это карта проектирования, не запись о переносе кода.

| Источник | Наблюдаемая идея | Применение в Trellis |
|---|---|---|
| `../old/flux/Sources/Flux/` | CurrentValue/Distinct, Pipe, операторы, Subscription/Bag | Подключить библиотеку зависимостью; не копировать реактивный runtime |
| `../Weave/Sources/WeaveUI/NodeState.swift`, `Node.swift`, `Lifecycle.swift` | State wrapper, bind, ConnectionScope и эффекты | Пересмотреть под владельца mounted session из D14; не переносить автоматически actor wrappers и node-owned bindings |
| `../Weave/Sources/WeaveUI/Scroll.swift`, `ScrollContentView.swift`, `Collections.swift` | Scroll state/commands, visibility/demand, arbitration, collections | Извлечь проверяемые контракты и тесты; отдельно проверить реальную проводку обоих adapters |
| `../old/ProfilePage-main/ProfilePage/ViewControllers/ProfileViewController.swift` | Clamp шапки, синхронизация страниц и блокировка части обновлений при paging | Сценарий и граничные случаи; без глобального Constants.shared и копии UIViewController-архитектуры |
| `../old/TabBarPager/Sources/TabBarPager/TabBarPagerController.swift` | Relay-scroll, распределение offset между header/container и страницей, память offsets | Сравнить relay с coordinated native scroll в раннем прототипе; выбрать одного владельца движения |
| `../old/XLPagerTabStrip/Sources/XLPagerTabStrip/PagerTabStripViewController.swift` | from/to/progress индикатора, подключение ближайших страниц | Pager progress и ограниченное число mounted pages; не держать все страницы активными |
| `../old/Telegram-iOS/submodules/Display/Source/ListViewItem.swift` | Разделение подготовки layout и apply, approximateHeight | Sendable input/result и отдельный MainActor commit; без передачи live nodes в worker |
| `../old/Telegram-iOS/submodules/Display/Source/ListView.swift`, `ListViewTransactionQueue.swift` | Загруженный/видимый диапазоны, preload, последовательное применение транзакций | Оконная материализация и атомарные обновления с anchor; очередь Trellis должна иметь явный предел |
| `../old/Texture/` | Асинхронная подготовка UI и управление диапазонами | Архитектурный справочник, без копирования кода, согласно AGENTS.md |

Display Telegram — UI-слой применения подготовленных элементов, не весь его
data layer. Postbox, сетевой слой и история сообщений этим анализом не покрыты.
SwiftSignalKit и AsyncDisplayKit не становятся зависимостями Trellis.
Перед фактическим переносом файла: проверить его лицензию/атрибуцию и добавить
строку в [source-provenance.md](source-provenance.md) в том же изменении.

### 3.1. Анализ Weave перед scroll/collections переносом

AGENTS.md требует прочесть weave-analysis.md и фиксировать источники в
source-provenance.md; отдельного требования переписывать исторический анализ
каждым переносом там нет. Для плана 6 вводится явный результат R06/R10:
дополнение по Scroll.swift/ScrollContentView.swift/Collections.swift в новом
`docs/weave-scroll-analysis.md` со ссылкой из weave-analysis.md. Сохранить
исторический статус старого текста, не подменять его текущей архитектурой.

Дополнение фиксирует source revision, symbols/контракты, известные дефекты,
проверенную проводку UIKit/AppKit, переносимые тесты и намеренные отличия.
Подтверждённые новые дефекты сразу регистрируются в defects.md; непроверенные
риски явно помечаются. Каждый фактически перенесённый файл по-прежнему получает
строку source-provenance.md в том же изменении; это правило относится ко всем
источникам, не только Flux. Weave не изменяется ради переноса.

## 4. Предлагаемые контракты

### P6.1. Flux — полноценная зависимость с отдельной UI-интеграцией

Предлагается продукт/target `TrellisFlux`, зависящий от Flux, TrellisCore и
TrellisRender. Это часть пакета Trellis с публичными bindings для Flux;
TrellisCore сохраняет Foundation-only, solver/raster не получают реактивный runtime.
Consumer подключает `TrellisFlux` вместе с платформенным host-модулем.

При разработке использовать локальный checkout `../old/flux` через документированный
SPM override. Для распространяемого манифеста — проверенная фиксированная версия
или revision Flux; абсолютный путь разработчика туда не попадает. Weave фиксирует
1.2.0, но это не доказывает наличие нужных исправлений в release: проверить R01.
Обновить consumer, policy, API baseline и сборочные scripts под новый target.
Запрет unsafe-аннотаций в Trellis остаётся; синхронизированные unchecked-типы
внутри внешней Flux оцениваются отдельно, без blanket-исключения для Trellis.

### P6.2. State, actions и lifecycle имеют разные правила

Отображаемое состояние: initial/current + latest, equality no-op, bounded delivery.
События/действия: без replay; overflow и ошибка видимы, нельзя молча потерять
удаление/покупку/навигационную команду как промежуточное состояние.
Существующие control closures по D22 сохраняются; Flux-композиция добавляется
поверх, без обязательной очереди для каждого нажатия.

Сохраняем StateSubject как мост D14 в первом срезе. У произвольного Flux нет
синхронного current: новый binding принимает явное initial либо подготовленное
состояние с revision. Нельзя объявить async replay синхронным первым кадром.
Проверить гонку initial/replay/new value и повторный attach.

Владелец UI-доставки — mounted session; cancel/detach/replaceRoot защищаются
session epoch/token, в том числе когда callback уже ждёт MainActor. Suspend
хранит latest без мутаций UI; resume публикует его до первого нового commit.
У источника/эффекта отдельный lifetime: view-session или model/service. При
detach UI доставка прекращается; model-owned producer может продолжаться.
Политика остановки/перезапуска cold source задаётся явно, без случайного повторения
сетевого запроса на каждом attach. Bag.deinit не заменяет lifecycle-отмену.

Проекции состояния дедуплицируются до Node.update. Тяжёлая обработка получает
Sendable data и явный executor; Node никогда не попадает в Flux worker.
Анимационное намерение проходит до фактического update и действует вокруг
мутации нод. Для coalesced burst выбирается намерение последнего принятого
состояния; replay/первый attach по умолчанию без анимации. Это уточняется R03
в рамках D61–D69, без попытки держать animate closure открытым через await.

### P6.3. ScrollNode — viewport и состояние, нативная механика в adapters

Core: axis, viewport/content extent, logical offset, insets, команды reveal/scrollTo,
phase, visibility и правила вложенности. Render: clipping и отображение контента
через существующий LayerRenderer. UIKit/AppKit: UIScrollView/NSScrollView и
нативные drag, wheel, momentum, deceleration, bounce, indicators.

R06 должен доказать размещение единственного render-поддерева внутри native
scroll content surface: родительские transform/clip/z-order, input и AX совпадают.
У каждого native scroll есть один владелец и один путь dispose. Не создавать
второй renderer или отдельный верхнеуровневый host на каждую строку.
Если embedding требует пересмотра принятого render-контракта, сначала ADR и
обсуждение конкретного расхождения; не обходить его незаметно.

Первая версия поддерживает вертикальную и горизонтальную ось по отдельности.
Поперечный constraint конечный; прокручиваемая ось измеряет content extent.
Процентные/flex размеры вдоль неограниченной оси получают определённую семантику
или явную диагностику до реализации. Insets/safe area учитываются ровно один раз.
Logical offset отделён от временного overscroll. Resize/сжатие контента делают
clamp с сохранением выбранного anchor, без циклов native → state → native.

Изменение только offset не запускает полный layout/raster. Координаты content,
viewport и host имеют одну проверяемую конверсию для hit testing, focus, AX,
reveal и переходов. Геометрия viewport обновляется синхронно с native offset;
отложенный Flux не становится единственным источником положения для input.
Публикация состояния потребителю может coalesce; begin/end/cancel не теряются.

### P6.4. Список — отдельный слой над прокруткой

ListNode, GridNode и TableNode используют общую основу, принимающую immutable
snapshot элементов со стабильными ID. Названия с суффиксом Node согласованы
с пользователем и моделью Trellis; назначение типов определено в §1.2.
Материализуются visible + ограниченный preload диапазон; общий объём моделей
может быть O(N), живые ноды/layers/raster jobs ограничены окном и бюджетом кэша.
Первый срез — ListNode с вертикальными строками переменной высоты. Полный
результат C дополнительно включает GridNode с согласованной сеткой колонок и
TableNode с согласованной моделью строк/секций; универсальный grid engine не входит.

Diff/подготовка метрик работают по Sendable данным вне MainActor. Commit атомарно
проверяет data revision, width/environment revision и mount epoch. Отменённый
результат не применяется. Snapshot может заменить ожидающий snapshot; дельта
требует совпадающего base revision, иначе пересчёт от последнего committed state.
Нельзя выбрасывать промежуточные index-based deltas и применять оставшуюся.

Anchor = item ID + смещение внутри viewport; prepend, delete, reorder, смена
высоты текста и уточнение estimated height сохраняют его. Если anchor удалён,
выбирается ближайший сохранившийся сосед по старому порядку, затем clamp.
Follow-bottom включается явно: вставки не утягивают читающего пользователя вниз.
ID не подменяется индексом; duplicate-key policy сверяется с weave-analysis
и закрепляется до реализации. Пул переиспользования, если нужен, сбрасывает
effects/state/focus/AX и не смешивает identity модели с identity переиспользуемой ноды.

### P6.5. TabbedScrollNode: header, tabs и страницы

Согласованный эскиз API (ещё не реализован):

```swift
TabbedScrollNode(
    header: profileHeader,
    tabs: .segmented(placement: .pinned),
    pages: [
        Tab(id: .media, title: "Медиа", content: mediaGrid),
        Tab(id: .files, title: "Файлы", content: filesTable),
        Tab(id: .links, title: "Ссылки", content: linksList),
    ]
)
```

Header принимает любой Node с детьми; специальный HeaderNode не обязателен.
Tab — описание страницы со стабильным ID, подписью и содержимым, не строка списка.
TabsNode представляет переключатель. Отдельный публичный TabListNode не вводится;
внутренний pager выполняет горизонтальный переход между страницами.

`.pinned`: tabs сначала прокручиваются с header, затем закрепляются под верхней
границей доступного viewport. `.inline`: tabs уходят вверх вместе с header.
Постоянное закрепление с первого кадра — другое поведение, пока не входит.

Отдельный coordinator связывает collapsing header, pinned tabs, pager и страницы.
Шапка имеет общий collapse progress; страницы — собственные anchor/offset.
Модель принята 2026-09-23 — [ADR 0037](adr/0037-tabbed-scroll-coordination.md)
(вариант Telegram): внешний вертикальный scroll с шапкой и pager в высоту viewport;
прокрутка страниц выключена, пока вкладки не закреплены. Разворачивание шапки не
стирает глубокую позицию неактивной страницы; наверх возвращается только выбранная
(видимая) страница. Выбор страницы с глубокой позицией при раскрытой шапке
закрепляет вкладки. Правило проверяется на двух длинных и одной короткой странице.
При горизонтальном drag вертикальное владение фиксируется по правилам
arbitration; изменение вкладки кнопкой использует тот же selected-page state.

Pager публикует fromID/toID/progress/settledID; committed selection отделён от
промежуточного progress. Отмена возвращает исходную вкладку и её состояние.
Mounted pages ограничены текущей и ближайшими; удаление выбранной страницы,
reorder вкладок, RTL, resize, Reduce Motion имеют определённый результат.
Refresh принадлежит одному владельцу на верхней границе; paging-demand
дедуплицирован по cursor/revision и допускает отмену.

### P6.6. TableNode swipe actions

Обязательная возможность результата C: действия с leading/trailing стороны,
несколько кнопок, настраиваемое выполнение полным свайпом. Action получает stable
item ID; индекс строки не захватывается как идентификатор. Удаление/замена строки
во время жеста отменяет её interaction, действие не переезжает на соседнюю строку.
Одновременно открыта максимум одна строка; reuse закрывает actions и очищает state.

Уточнение пользователя: swipe actions — настройка, доступная для самостоятельной
таблицы и отключаемая в сложной композиции. Предлагаемый `swipeActionsPolicy`:
`.automatic` (default), `.disabled`, `.enabled`. Automatic разрешает жест у
standalone TableNode с настроенными actions; TabbedScrollNode задаёт потомкам
контекст, отключающий row swipe. Контекст передаётся существующим environment
путём, не эвристикой по глубине дерева и не глобальным флагом.

Явный `.disabled` всегда выключает жест. `.enabled` — осознанное переопределение:
внутри pager оно допускается лишь с определённым arbitration; в направлении
доступных actions строка получает приоритет, захват не меняется до end/cancel.
Обычный сценарий профиля использует automatic и оставляет горизонтальный жест
pager. Другой составной контейнер может задать тот же контекст отключения.
При смене контекста открытая строка закрывается, незавершённый жест отменяется;
уже отправленное действие не повторяется. Выключение swipe отключает способ ввода,
а не бизнес-действия: они остаются доступны через menu/AX или явные кнопки.

Leading/trailing учитывают RTL. Ошибка async action показывается и позволяет retry;
повторное выполнение во время pending блокируется или имеет явно заданную политику.
На macOS/tvOS и для AX те же действия доступны альтернативно жесту через
согласованный menu/keyboard/remote путь. Жест не единственный способ удалить строку.
Telegram — референс, конкретную реализацию swipe требуется исследовать до переноса.

### P6.7. Реактивные данные и загрузка для всех контейнеров

ListNode/GridNode/TableNode получают общий reactive binding через TrellisFlux:
поток состояния → snapshot/diff → viewport → commit. Сеть и бизнес-логика остаются
в переданном service/model; контейнер не знает URL, авторизацию или декодирование.
Потребитель может вызвать API из обработчика загрузки либо отправить action модели,
которая запускает Flux pipeline. Оба способа используют одного владельца эффекта,
явную отмену и проверку актуальности; нельзя просто запускать бесхозный Task.

Предлагаемые hooks: `onLoad`, `onRefresh`, `onLoadMore`, `onRetry`; точные сигнатуры
фиксируются в R04/R10 на внешнем consumer. `onLoad` означает запрос начальных
данных, а не создание native view, layout pass или каждое появление строки.
Hooks должны возвращать управляемый async/Flux effect либо делегировать запрос
явному model owner, а не терять cancellation в произвольном Void callback.

Правила для первого среза:

- Initial load запускается при первой активации страницы, если данные ещё не
  загружены; соседняя preload-страница не запускает сеть без явной политики prefetch.
- Для lifetime одной модели/набора данных допускается один initial request in-flight.
  Переключение tabs и remount сами по себе не сбрасывают загруженное состояние.
  Смена data key (например, peer/filter) начинает новую generation и invalidates
  старый pending result. После отмены initial остаётся допускающим новую попытку.
- Refresh заменяет актуальный запрос по принятой политике и сбрасывает pagination
  generation; старый ответ не дописывает данные в новый набор. Видимое содержимое
  можно сохранить со статусом refreshing, не заменяя весь экран spinner-ом.
- Load more вызывается по demand возле границы, с cursor/data revision. Повторные
  события deduplicate; один page request на cursor, endReached прекращает запросы.
  Retry использует контекст неудавшейся операции, а не всегда initial load.
- State включает initial/loading/loaded/empty/error и отдельные refreshing/
  loadingMore/pageError состояния. Обновления приходят через тот же state binding,
  без отдельного imperative reloadData, конфликтующего с revision/anchor.
- View-owned запрос отменяется при завершении его session. Model-owned запрос
  может продолжаться при уходе страницы, но не получает доступ к отсоединённым Node.
  Suspend и повторная активация следуют P6.2; отсутствие страницы не копит UI updates.

Приёмка: управляемый fake API и тесты количества запросов, позднего ответа,
refresh во время pagination, быстрых переключений tabs, remount, отмены/retry,
смены фильтра и освобождения владельца. Flux subscription сама по себе не является
гарантией фонового исполнения тяжёлого кода до первого await.

### P6.8. Упреждающая загрузка данных и подготовка UI

Уточнение пользователя: загрузить первые 20 элементов и запросить следующие 20
заранее, пока пользователь ещё читает текущие. Это batch fetching/prefetch,
отдельный от подготовки UI механизм. Фраза «доходит до 5» допускает пятый элемент
от начала или пять оставшихся; пример API должен явно задавать remainingItems,
а не двусмысленный индекс. Размер страницы выбирает consumer/API, не layout engine.

Проверено по локальному Texture: `Source/ASTableNode.h` задаёт
leadingScreensForBatching — оставшееся расстояние в высотах viewport, default 2.
`Source/Private/ASBatchFetching.mm` проверяет in-flight, направление, видимость,
короткий контент и оставшуюся дистанцию; optional delegate учитывает время до конца
из скорости. Это не фиксированное правило «каждый пятый элемент».
`Source/Details/ASLayoutRangeType.h` отдельно задаёт display/preload ranges с
leading/trailing buffers и режимами minimum/full/visible-only/low-memory.
Код Texture не переносится; эти источники дополняют справочную строку §3.

Предлагаемая конфигурация Trellis разделяет:

1. Data pagination: pageSize (например, 20), trigger remainingItems (например, 5)
   **или** remainingViewportLengths (например, 2), cursor/endReached, максимум
   один запрос следующей страницы на data generation. Для variable-height строк
   и grid предпочтителен геометрический trigger; items считается от последнего
   видимого элемента в направлении загрузки, не от первой строки на экране.
2. UI preparation: независимые display/preload диапазоны впереди и сзади viewport,
   лимиты нод, raster jobs и bitmap cache. Получение 20 моделей не требует сразу
   создать и растеризовать 20 сложных деревьев.
3. Page activation: отдельный prefetch соседних tabs; готовность данных страницы
   не равна её mount/visibility и не запускает onLoad повторно.

Ориентир для первого consumer: первые 20 моделей → при пяти оставшихся после
последнего видимого элемента запрос ещё 20 → публикация нового snapshot через
Flux → подготовка нужной части окна. Для запроса уже при пятом элементе из 20
порог задаётся соответственно раньше; это отдельная настройка, не default.

Расчёт/декодирование моделей, diff, layout и raster исполняются на явно заданных
workers по Sendable inputs. Live Node и commit остаются MainActor; материализация
ограничена окном и бюджетом за проход. Приоритет видимого контента выше prefetch.
Движение назад отменяет ненужную speculative UI-подготовку; политика кэширования
полученных данных отдельная. Memory pressure сокращает диапазоны/кэш.

Сеть может не успеть: предусмотрен footer loading/error/retry; предзагрузка не
обещает отсутствие ожидания при любой скорости. Повторные demand не дублируют
запрос; после успешного append расстояние пересчитывается. Короткий контент может
вызвать последовательную догрузку до заполнения viewport, но без бесконечного
цикла: no-progress (нет новых IDs/cursor), endReached и лимит автоматических
страниц останавливают её. Ошибка не запускает бесконечный auto-retry.

R10/R12 проверяют: разные высоты и grid, быстрый fling/разворот, медленный API,
повторный cursor, пустая страница, короткий контент, refresh во время prefetch,
лимиты работ/памяти. Адаптация расстояния по скорости и latency — последующее
измеряемое расширение, не обязательная сложность первого среза.

### P6.9. Ленивый UI, состояние и общий бюджет подготовки

Предложения после проверки полноты плана; точные API принимаются в R10/R13.

**Фабрики.** `Tab` допускает `makeContent` на MainActor вместо заранее созданной
страницы. Создание — при demand, eviction — по бюджету; page ID не меняется при
создании нового Node. Фабрика строки также вызывается только для materialized
окна; отдельный update обновляет существующую ноду. Повторная фабрика не является
onLoad и не запускает сеть. Eager content остаётся удобством для маленьких сцен,
но не используется в нагрузочной приёмке. Заранее созданный Node нельзя одновременно
вставить в две страницы/два host.

**Состояние.** Durable UI state (expanded/selected и т.п.) принадлежит модели,
ключ `(dataKey, itemID)`; живой Node отображает его. Page model, anchor и selected
page сохраняются владельцем экрана при eviction UI. Swipe progress/pressed и
прочее временное interaction state сбрасываются. Удаление модели определяет
очистку её state; кэш состояния не растёт бесконечно. Reuse не меняет принадлежность
actions и callbacks к item ID. State restoration после уничтожения всего экрана
не обещает дисковую персистентность — для неё нужен отдельный owner/контракт.

**Планирование.** Общий бюджет хоста ограничивает подготовку всех списков и
соседних страниц вместе: visible > ближайшее окно > соседние tabs. Использовать
существующие LayoutScheduler/DisplayScheduler и определить точку arbitration;
не добавлять независимые неограниченные очереди на каждую страницу. Нужны fairness,
отмена устаревшего demand, ограничения MainActor materialization и памяти. Несколько
хостов имеют отдельные квоты; общего process-wide лимита этот срез не обещает.

**Измерение.** Первый путь для произвольной пользовательской строки:
Sendable model → ограниченное создание/update Node на MainActor → snapshot →
worker layout/raster → проверка revision/epoch → commit. Высота сначала может быть
estimated, затем уточняется с компенсацией anchor. Measurement cache учитывает
item content revision, width, typography/environment (включая размер шрифта,
LocaleKey и TextRendererKey/его measurement identity). ThemeKey учитывается
через фактические зависимости строки: смена только цветов обновляет paint/raster,
не геометрию текста (D52); изменение theme-dependent структуры/метрик пользовательской
строки invalidates measurement. Если зависимость неизвестна, используется
консервативная invalidation, не объявляется, что любая тема geometry-neutral.
UI-state, влияющий на высоту, тоже invalidates запись. R10/R11 проверяют color-only,
metric/structure theme changes и смену renderer при сохранённых item IDs. Отдельный renderer-
независимый API измерения строки без создания Node не вводится до замеров.

**Scroll target.** `scrollTo(itemID:)` работает с известными dataset элементами,
включая нематериализованные: materialize/measure/reveal с явным результатом
completed/cancelled/notFound и политикой пользовательского прерывания. Неизвестный
ID возвращает notFound. Получение отсутствующего диапазона — отдельная операция
модели/API; после публикации snapshot consumer повторяет reveal. Новая команда
заменяет предыдущую, поздний результат старого reveal не двигает viewport.

### P6.10. Цельный consumer API до реализации

Ниже Swift-подобный **эскиз**, не существующий/проверенный на компиляцию API.
В R04/R10 нужно выбрать реальные типы с явной actor isolation и ownership.
`FilesModel`/`FilesState`/`FileRowProvider` — пользовательские типы. DataSource
подключается через одну интеграцию TrellisFlux по P6.11; отдельный bind поверх
него не создаёт вторую подписку.

```swift
@MainActor
func makeFilesPage(model: FilesModel) -> TableNode {
    let table = TableNode(
        dataSource: model.files,
        itemProvider: FileRowProvider(),
        swipeActionsPolicy: .automatic,
        pagination: .init(pageSize: 20, trigger: .remainingItems(5))
    )

    table.onSelect { itemID in
        model.openFile(itemID)
    }
    table.onLoad { context in
        await model.loadIfNeeded(context: context)
    }
    table.onRefresh { context in
        await model.refresh(context: context)
    }
    table.onLoadMore { context in
        await model.loadNext(context: context)
    }
    table.onRetry { context in
        await model.retry(context: context)
    }
    table.trailingActions { itemID in
        [RowAction("Удалить") { context in
            await model.delete(itemID, context: context)
        }]
    }
    return table
}

let screen = TabbedScrollNode(
    header: profileHeader,
    tabs: .segmented(placement: .pinned),
    pages: [
        Tab(id: .files, title: "Файлы", makeContent: {
            makeFilesPage(model: filesModel)
        })
    ]
)
```

`onLoad` и остальные hooks здесь регистрируют async effects; владелец integration
создаёт/отменяет их Tasks, context несёт data generation/причину/cursor по операции.
Методы модели вызывают инжектированный API service, объединяют результат со state
и публикуют его через Flux. Model methods проверяют актуальность после await;
context не даёт worker доступ к Node. Ошибки/отмена имеют явное отображение P6.7.
`model.files` — DataSource с синхронным current MainActor и потоком обновлений
Flux; current не является синхронным чтением actor-backed Flux CurrentValue. Регистрация hooks/binding до attach не выполняет
запросы; session подключается при mount согласно D14/P6.2.

Самостоятельный `makeFilesPage` разрешает настроенные swipe actions; тот же
TableNode внутри TabbedScrollNode получает отключение жеста по automatic policy.
GridNode/ListNode используют ту же загрузку и lifetime. Expanded/selection
обновляются действиями модели, а не живут исключительно внутри FileRowNode.
Приёмка примера: отменить mount, пересоздать page, проверить один запрос на нужную
generation и восстановление состояния без ручных Task/SubscriptionBag в сцене.

### P6.11. DataSource, ItemProvider, Delegate и loading hooks

Разделение согласовано с пользователем как направление API. Реальные generic/
protocol сигнатуры фиксирует R10; существующий публичный API пока не изменён.

| Часть | Ответственность |
|---|---|
| DataSource | Согласованный current snapshot и поток обновлений: data key/revision, секции, элементы со stable IDs, состояние загрузки |
| ItemProvider | Ленивые make/update Node для элемента и supplementary content |
| Delegate | Selection, изменение видимого диапазона, begin/end/cancel scroll |
| Loading hooks | Управляемые onLoad/onRefresh/onLoadMore/onRetry эффекты по P6.7 |

Один общий контракт используется ListNode/GridNode/TableNode. Раскладка и
специфические table/grid возможности не требуют независимых источников данных.
DataSource не делает API-запрос из getter или numberOfRows: количество/порядок
строк и секций выводятся из одного принятого snapshot. Индекс имеет смысл только
внутри его revision; наружу события передают stable ID. Equality/content revision
и duplicate policy соответствуют P6.4. Initial current и регистрация потока
должны исключать пропуск/откат состояния между чтением и подпиской (R01/R03).

**Модульная граница.** Snapshot/provider/delegate не зависят от Flux в Core.
TrellisFlux предоставляет подключение реактивного DataSource и при необходимости
удобные initializer/factory; точный дом модуля для каждого публичного типа
определяется R02/R10 без нарушения Foundation-only. StateSubject/существующий
bindState остаются механизмом доставки D14. DataSource использует этот путь,
не вводит второй scheduler/очередь/reloadData. Для локального статического набора
можно предоставить snapshot source с теми же контрактами, без сетевых hooks.

**Владение.** Контейнер удерживает source/provider и зарегистрированные closures;
подпиской владеет mounted integration session. Delegate — weak class-bound,
его удерживает controller/model/coordinator владельца экрана. Delegate не является
неявным владельцем загрузки. Closures не должны сильно захватывать обратно
удерживающий их контейнер; при cancel/dispose освобождаются регистрации согласно
scope. Замена source отменяет старую доставку/связанные view-owned effects,
меняет source epoch и синхронно подготавливает initial нового источника по D14;
model-owned producer при этом не обязательно прекращается. Поздние callbacks
старого source не затрагивают новый dataset.

**События.** Closure API и delegate входят в один dispatcher. Для конкретного
события установленный closure имеет приоритет над одноимённым методом delegate;
при отсутствии closure вызывается delegate. Никогда не вызывать оба как два
независимых действия. Снятие closure восстанавливает fallback на delegate.
Handlers/provider исполняются на MainActor; фон получает только Sendable data,
не ссылки на delegate/provider/live Node. Selection/terminal scroll events не
теряются; частые viewport updates могут coalesce по определённому контракту.

**Загрузка.** Loading hooks отдельны от уведомления didScroll: container demand
порождает управляемый effect по P6.7/P6.8. Фабрика Node, getter данных и delegate
видимости не запускают повторный initial request автоматически. Модель/service
выполняет запрос, обновляет DataSource, integration применяет новый snapshot.
Смена delegate не перезапускает source или запрос.

Для простых сцен используется `onSelect` из P6.10; для сложных допустимо
`table.delegate = coordinator`. Closures для make/update могут быть удобной
обёрткой над ItemProvider, но не отдельным механизмом materialization. Provider
должен типобезопасно связывать модель и тип Node; несовместимая смена типа элемента
приводит к определённой замене ноды, а не unchecked cast или reuse чужого типа.

Приёмка: одинаковые dataset/результаты для всех трёх контейнеров; одна активная
подписка на binding; согласованность current/replay; weak delegate освобождается;
closure переопределяет ровно один callback; provider не вызывается вне MainActor;
source replacement не принимает поздний snapshot; hooks не дублируются после
смены delegate/повторной регистрации. Внешний consumer проверяет closure-only,
delegate-only и смешанный вариант с явным приоритетом.

### P6.12. Диагностика новых подсистем

Использовать существующий Log.on и формат
`[trellis.<area>] <event> host=<h> gen=<g> #<node> parent=#<parent> <details>`.
Первый срез использует существующие области, без нового logging runtime:

| Область | События |
|---|---|
| event | scroll command/phase/cancel, row action, gesture owner |
| host | binding/effect start/stop, source replacement, load success/error/cancel |
| schedule | prefetch demand/dedup, enqueue/cancel/drop stale, materialization budget |
| commit | dataset applied, anchor restored/lost/clamped |
| measure | measurement cache hit/miss/invalidation и причина |

Bridge передаёт correlation context (Sendable value) при создании binding,
command/effect и job. host/node обозначают UI-владельца; gen — render generation,
если она известна. dataRevision/sourceEpoch/requestID/cursor token — отдельные
поля details, они не подставляются вместо render gen. Для события до mount или
model/service без host допустимы `host=none gen=none #none`, как уже допускает
Log; значения не выдумываются и не берутся из глобального current host.
Непрозрачный cursor логируется диагностическим token, не сырым payload/URL/данными.

Worker получает captured context, а при commit дополнительно отмечается текущая
revision и причина отклонения. На offset tick не форматировать длинные snapshots:
только transitions/coalesced summaries; дорогое форматирование ленивое и пропускается
при выключенной области. Correlation служебный, consumer не обязан вручную передавать
host/gen каждому onLoad. R03/R06/R10 добавляют проверку формата, двух хостов,
none до mount, отмены и stale result; R15 включает device diagnostic trace.

## 5. Карточки исполнения

Каждая карточка оставляет `docs/validation/rNN-*.md`: код/API, тесты, замеры,
платформенное evidence и открытые пункты. Чекбокс отмечается только после всей
приёмки. Новые решения переносятся в decisions.md/ADR при принятии.

### R01 — Проверить Flux как фундамент

- [x] Обновить навигацию AGENTS.md для R-карточек согласно введению плана.

- [x] Зафиксировать checkout/revision, лицензию, Swift 6 complete concurrency,
  release/local override и базовый набор тестов.
- [x] Проверить атомарность modify/distinct: в текущем CurrentValue.swift чтение
  и запись разделены await. Проверить replay ordering: регистрация и yield current
  разделены actor hop. Детерминированные interleavings, не только stress.
- [x] Проверить cancel во время доставки на MainActor, flatMapLatest со старым
  ответом, bounded buffering и освобождение подписок.
- [x] Найденные проблемы зарегистрировать до исправления; исправления в Flux
  выпускать/фиксировать отдельно, Weave ради Trellis не изменять.

**Evidence:** [r01-flux-foundation.md](validation/r01-flux-foundation.md).
Проверен release 1.2.0 / `7e98033`; 138 штатных + 11 audit-тестов.
Дефекты #56–#59 открыты во внешнем Flux; R02 требует отдельного исправленного pin.
Исправления в этой карточке не выпускались.

Приёмка: проверенный revision и воспроизводимые concurrency/cancellation тесты;
известные риски не скрыты за успешной компиляцией Swift 6.

### R02 — Подключить TrellisFlux

- [x] `Scripts/verify_bootstrap.py`: обновить PRODUCTS, manifest_issues (запрет
  внешних dependencies, точный набор products/targets), smoke consumer и matrix
  tests для TrellisFlux/его тестов. Проверять разрешённую фиксированную Flux
  dependency, не снимать проверку зависимостей целиком; добавить негативные фикстуры.
- [x] `Scripts/check_api.py`: добавить MODULES/TrellisFlux и
  `api/TrellisFlux.json` через review-note flow. Проверить доступность dependency
  symbols при extraction. TVOS_PROBE сейчас относится к UIKit; не заменять его
  Flux-пробой. Подтвердить сборку/consumer Flux на iOS/tvOS и определить, требуется
  ли дополнительная per-SDK API-проба (при платформенных различиях — требуется).
- [x] `Bench/Package.swift`: обновить комментарий four-library target graph;
  зависимости добавить только для Flux fixtures. Bench остаётся отдельным
  consumer executable, не обязан импортировать каждый продукт. Проверка ровно
  четырёх продуктов находится в verify_bootstrap.py, не в этом комментарии.
- [x] Проверить `Playground/Playground.xcodeproj/project.pbxproj` и app consumers:
  подключение нового продукта для native reactive сцен. Согласовать изменения
  со `Scripts/check_all.py`, policy.json и существующими policy fixtures.

- [x] Реализовать P6.1; зафиксировать module graph и способ локальной разработки.
- [x] Consumer импортирует модуль и использует реальный Flux из зависимости.
- [x] Проверки dependency policy, API extraction, macOS/iOS/tvOS учитывают target.

Зависимость: R01. Приёмка: чистая сборка с фиксированной зависимостью и отдельная
проверка с локальным override; Foundation-only Core сохранён.

**Evidence:** [r02-trellis-flux.md](validation/r02-trellis-flux.md). Flux
исправлен и выпущен как [1.2.1](https://github.com/resoul/flux/releases/tag/1.2.1)
(дефекты #56–#59 закрыты); `TrellisFlux` подключён как пятый продукт
([ADR 0021](adr/0021-trellis-flux-target.md)); `verify_bootstrap.py --matrix`
зелёный на macOS/iOS/tvOS device и iOS/tvOS Simulator; `check_api.py`/
`check_policy.py`/`test_verifier.py`/screenshots — зелёные; локальный override
(`swift package edit`) проверен и задокументирован в README.md.

### R03 — State bindings и анимационное намерение

- [x] Уточнить публичную запись P6.2 на внешнем consumer; initial/replay/projections.
- [x] Реализовать session ownership, bounded latest delivery, epoch и явный cancel.
- [x] Проверить burst, equality, cancel после enqueue, detach/attach, replaceRoot,
  suspend/resume, два хоста, reentrant update и отсутствие retained старого дерева.
- [x] Проверить state → анимированное изменение текста/геометрии; replay без движения.

Зависимость: R02. Приёмка: первый commit с initial, старый callback не мутирует
новый экран, burst не создаёт очередь задач/полных commit на каждое значение.

**Evidence:** [r03-flux-state-binding.md](validation/r03-flux-state-binding.md),
[ADR 0022](adr/0022-flux-state-binding.md). `NodeHostBridge.bindFlux`/
`FluxStateBinding` bridge `Flux<Value>` onto the existing `StateSubject`/`bindState`
delivery path (D14) rather than reimplementing it; found and fixed before commit: a
dropped binding silently stopped delivering (fixed via a retaining capture, matching
`bindState`'s own ownership contract). Burst coalescing of a raw, unthrottled Flux
producer is verified to not happen at the pump layer (empirically, not assumed) —
documented as the producer's job via `.throttle`/`.debounce`, with a passing test
proving that composition. 716/716 tests green (one known flake retry, defects.md
#60); `check_policy.py`/`check_api.py` (`TrellisFlux` — 5 symbols) pass; a
`swift-symbolgraph-extract` blind spot for cross-module extension methods
(`bindFlux` itself) is documented in `check_api.py` and the ADR.

### R04 — Эффекты и действия

- [x] Специфицировать hooks и ownership P6.7 на fake API; проверить initial,
  refresh, pagination, retry и их конкуренцию, без бесхозных Tasks.

- [x] Владение keyed effect, replace/cancel, restart policy; loading/error/retry.
- [x] State отделён от событий, переполнение действий наблюдаемо.
- [x] Запрос A завершается после B; применяется B, A освобождается. Ошибка не
  завершает навсегда UI-подписку без определённого способа восстановления.

Зависимость: R03. Приёмка: всё проверяется управляемым fake service без сети/sleep;
model lifetime и mounted UI lifetime различаются явно.

**Evidence:** [r04-effect-owner.md](validation/r04-effect-owner.md),
[ADR 0023](adr/0023-effect-owner.md). `EffectOwner<Key>` — keyed-эффект владение
(replace/cancel/restart policy) поверх обычного `Task`, не Flux-специфично;
`onLoad`/`onRefresh`/`onLoadMore`/`onRetry` на реальном `ListNode`/`TableNode` —
R10, эта карточка строит и тестирует только примитив владения на fake service.
Найдено при написании тестов: `AsyncStream.Iterator.next()` реагирует на отмену
потребляющей задачи и может вернуть `nil` без `finish()` — тестовый двойник
исправлен, не `EffectOwner`; тесты, зависевшие от блокирующего фиксированного
числа `Task.yield()`, падали только в составе полного `swift test` под нагрузкой
и исправлены переходом на condition-based `waitUntil`. 725/725 тестов зелёные
дважды подряд; `check_policy.py`/`check_api.py` (`TrellisFlux` — 15 символов) —
чисто.

### R05 — Закрыть результат A

- [x] `python3 Scripts/check_policy.py`: 0 diagnostics, в том числе
  PUBLIC_DOCUMENTATION; каждое новое public/open объявление содержит Ownership,
  Isolation, Errors, Cancellation. Документация добавляется вместе с API,
  не откладывается до R15.

- [x] Внешний consumer: фильтр кнопками, задержанные результаты, retry и анимация;
  без скрытой зависимости от отсутствующего text-input control.
- [x] C29 regression, memory/cancellation, API/docs, обычные проверки и matrix.

Зависимость: R04. Приёмка: рабочая Flux-интеграция, не только операторы в unit tests.

**Evidence:** [r05-close-result-a.md](validation/r05-close-result-a.md),
[ADR 0024](adr/0024-host-view-hostbridge-escape-hatch.md),
[ADR 0025](adr/0025-flux-external-consumer-scene.md). Новый
`TrellisHostView.hostBridge` (AppKit/UIKit) — единственный способ достать
`NodeHostBridge` для `bindFlux` без нарушения R02's dependency policy; новая
Playground-сцена S32 (фильтр-кнопки, реальная задержка, гарантированный сбой +
retry, анимация) — настоящий внешний consumer; дублирующий автоматический
уровень `ExternalConsumerFeedTests.swift` (реальное время, реальный
`ControlNode`/hit-test). Найден и обойдён дефект #61 (auto-width `TextNode`
"Odd" обрезалось на macOS — та же семья, что #37/#47/#48, впервые не только на
iOS). 730/730 тестов зелёные; `check_policy.py`/`check_api.py`/
`check_screenshots.py`/`verify_bootstrap.py --matrix` — все чисто. Известные
Simulator-load флейки #52/#60/#62 встретились по пути, не связаны с этой
карточкой (детали в evidence). Результат A (R01–R05) закрыт.

### R06 — Scroll-контракт и ранний native прототип

- [x] Создать native performance harness §6.1 и сохранить воспроизводимый baseline
  до принятия бюджетов; CLI Bench не выдаётся за замер UIKit scrolling.
  `Playground/Shared/PerfRecorder.swift` (bounded `PerfSamples` p50/p95/p99,
  `PerfEnvironment` device/OS/build/refresh/revision, JSON+CSV `PerfReport`,
  `PerfLaunchConfiguration` для `--perf-run --perf-scenario --perf-seed
  --perf-count --perf-viewport --perf-repeats --perf-warmup --perf-output
  --perf-revision`) и `PerfHarness.swift` (сквозной fixture — attach-to-ready
  + resize-to-commit на реальном `TrellisHostView`, через `Task.yield()`
  вместо ручного pump — приложение уже крутит свой run loop). Подключено во
  все три `PlaygroundApp.swift` (`runPerfHarnessIfRequested`, обычный запуск
  без флага не меняется) и в `Playground.xcodeproj`. Реально прогнано и дало
  воспроизводимый, чистый baseline на всех трёх платформах — см. чек-лист
  ниже. XCUITest target в `Playground.xcodeproj` сознательно не создан в этой
  карточке: осмысленные touch/remote-сценарии scroll нечего автоматизировать
  до того, как `ScrollNode` реально существует (R07) — тест был бы тестом
  пустоты. Реальный UI-test target — задача R08's «реальные input-прогоны
  дополнительно к unit tests», когда будет что тестировать; harness/recorder
  здесь уже готовы для него. Instruments trace/hitch-frame-drop evidence —
  тоже R08/R15, когда есть реальная прокрутка для трассировки, не голый
  layout commit. Evidence: [r06-scroll-contract.md](validation/r06-scroll-contract.md).
- [x] Разбор Weave scroll/collections по §3.1 до переноса контрактов/кода.
  [weave-scroll-analysis.md](weave-scroll-analysis.md): подтверждено — в Weave
  нет ни одного `UIScrollView`/`NSScrollView` (вся прокрутка — ручной pan
  gesture + hand-rolled deceleration, дефект #63); `updateItems`'s
  anchor-restore игнорирует измеренные длины для variable-height контента
  (дефект #64); `VirtualizedView` наследует `ScrollNode` (is-a, не owns-a) —
  открытый вопрос для R10's состава `ListNode`-внутри-pager; переносимые тесты
  и намеренные отличия — §6/§7 документа. `ScrollContentView.swift` из §3
  плана не существует в checkout — весь контракт в одном `Scroll.swift`.

- [x] Специфицировать конфигурацию §1.2: defaults, поддержка платформ и изменение
  настроек во время движения; проверить пример верхний Node 0.5H + pager 1H.
  [scroll-configuration.md](scroll-configuration.md) (предложение, не D-решение):
  `ScrollConfiguration` эскиз (axis/lock/indicators/insets/bounce/keyboard/
  edgeLoad), platform support таблица (iOS/tvOS/macOS), таблица mid-motion
  изменений по полю, numeric-проверка примера 0.5H+1H — `ScrollConfiguration`
  применяется дважды в одной композиции (внешний scroll с растущей content
  length + pager с конечным viewport), без числового противоречия; арбитраж
  внешний/внутренний явно оставлен R09, точные enum-типы — следующему пункту
  чек-листа (фиксация P6.3).

- [x] Зафиксировать P6.3: constraints, coordinate spaces, native backing ownership,
  clipping/z-order, insets, phases, command acknowledgement и feedback suppression.
  [r06-scroll-api-sketch.md](validation/r06-scroll-api-sketch.md) (предложение,
  формат как t01-text-contract.md): `NativeScrollBacking` протокол (та же
  граница, что `EdgePullContainer`/`SwipeRevealContainer` в Weave) + parallel
  `LayerRenderer.scrollBackings` table (T07-style); `.scroll` в
  `OverflowPolicy` уже существует в коде и уже участвует в hit-test clip
  (D17), но `LayerRenderer.applyPresentation` сегодня обрабатывает его как
  синоним `.hidden` — этот sketch специфицирует, что должно измениться в той
  же точке; `ScrollCommandOutcome` (completed/superseded/cancelledByUser/
  notAttached) заменяет Weave's синхронный возврат, которого недостаточно
  для native-backed команд; `isUserDriven` — явный feedback-suppression флаг
  (native — источник истины во время жеста, Trellis никогда не пишет offset
  обратно в этот момент). 8 сценариев для будущих тестов R07. Открыто: точная
  передача backing-фабрики через `attach(...)`, арбитраж (R09), tvOS backing.
- [x] Прототип на UIKit и AppKit: viewport с текстом, нативный scroll, control
  внутри и снаружи viewport; один LayerRenderer, без полной пересборки на offset.
  `Tests/TrellisRenderTests/{AppKit,UIKit}NativeScrollEmbeddingPrototypeTests.swift`
  (4 теста, без правок `Sources/`): неизменённый `TrellisHostView` во всю
  высоту контента — единственный `documentView`/`subview` реального
  `NSScrollView`/`UIScrollView`; после нативной прокрутки `host.layer.bounds.
  origin` не меняется (offset — целиком native, не Trellis, в отличие от
  дефекта #63); один и тот же host-локальный hit-test point резолвится в
  control до и после прокрутки. Зелёно на macOS/iOS Simulator/tvOS Simulator
  (см. [r06-scroll-contract.md](validation/r06-scroll-contract.md)). Честно
  не покрыто этим прототипом: реальный жест/momentum/bounce/AX-actions —
  остаётся за R08, здесь только геометрия embedding.
- [x] Минимальная шапка + горизонтальная и вертикальная области: сравнить relay
  и coordinated-native подходы по input/AX/momentum; записать выбранный вариант.
  [r06-scroll-arbitration-comparison.md](r06-scroll-arbitration-comparison.md):
  relay разобран по реальному коду (`TabBarPagerController.swift`,
  `ProfileViewController.swift`) — единственный реальный жест на прозрачной
  relay-scrollview, ручная запись `contentOffset` на container/page,
  `require(toFail:)` не даёт странице получить свой жест. По пути найден и
  исправлен реальный дефект #65 (отсутствующий `UILaunchScreen` у
  `Playground-iOS` — legacy 320×480 scaling на холодном `simctl launch`,
  выдавало корректно вычисленную геометрию за неверную на экране); после
  фикса живой прогон на iPhone 17 Pro Simulator **опроверг** исходную
  гипотезу «вложенные `UIScrollView` дают коллапс шапки бесплатно» — три
  контролируемых свайпа показали, что touch-down на списке никогда не
  передаёт жест шапке, даже длинным свайпом далеко за пределы высоты шапки;
  touch-down на шапке скроллит только её. Итоговая рекомендация —
  coordinated-native, но в форме «одна `UIScrollView` на страницу» (шапка —
  часть контента этой же scrollview, как `tableHeaderView`), а не «два
  вложенных scroll»; для composition (общая шапка над несколькими
  независимыми страницами) — шапка вне hit-testable контента любой page-
  scrollview, presentation управляется чтением (не записью) offset активной
  страницы. Прототип-файл удалён после записи находок. Сознательно оставлено
  R08 (уже его собственный чек-лист, не пробел этой карточки): continuous
  momentum через границу шапка/список и AX-путь требуют реального
  `ScrollNode`-контракта (R07), проверять их до его существования нельзя —
  эта карточка решает архитектуру, R08 её живьём подтверждает.
- [x] До основной реализации записать baseline и числовые бюджеты R15.
  [docs/validation/r06-native-performance/](validation/r06-native-performance/README.md):
  реальный `app-text-list-1000` прогон на всех трёх платформах через
  `PerfHarness`. Первый (перегруженный параллельными сборками) прогон дал
  таймауты на tvOS/macOS — воспроизведено намеренно как урок для протокола
  измерения, затем переснято чистым изолированным прогоном без параллельной
  нагрузки: все три платформы завершили все 20 повторов без единого
  таймаута (attach-to-ready 1.3–11.3ms, resize-to-commit p50 895–969ms,
  согласованный порядок величины на всех трёх, поскольку все три гоняют
  один Swift-код на одном хостовом Mac). Доказывает: pipeline работает
  end-to-end и даёт воспроизводимые числа при правильном протоколе прогона
  (изолированная машина). Сознательно оставлено R15 (его собственная задача
  по тексту плана — «R15 повторяет тот же protocol и сравнивает»): повтор на
  физических устройствах, несколько fixture, разбивка по фазам, Instruments
  trace — это масштабирование протокола, не его отсутствие.

Зависимость: текущий render/input pipeline; может идти до завершения R05.
Приёмка: архитектура подтверждена живыми native scroll views на обеих платформах,
а не одним изменением свойства offset.

**R06 закрыта 2026-09-15.** Приёмка выполнена: embedding-прототип
(`AppKitNativeScrollEmbeddingPrototypeTests.swift`/`UIKitNativeScrollEmbeddingPrototypeTests.swift`)
подтверждает архитектуру живыми `NSScrollView`/`UIScrollView` на обеих
платформах, не изменением offset. Все 7 пунктов чек-листа закрыты; там, где
пункт естественно упирается в ещё не построенный `ScrollNode` (R07) —
continuous momentum через границу шапка/список, AX-путь, XCUITest с реальными
touch/remote-сценариями, физическое устройство для числового бюджета — работа
сознательно передана R07/R08/R15, каждый раз с явной причиной («нечего
тестировать до R07», не «не успели»), не пробел этой карточки. По пути найдены
и закрыты два реальных дефекта: #63/#64 (Weave scroll-источник) и #65
(`Playground-iOS` legacy launch-screen scaling, дефект самого Trellis-проекта,
не источника). Следующее: R07 — ScrollNode и viewport pipeline на контракте
[r06-scroll-api-sketch.md](validation/r06-scroll-api-sketch.md), с
конфигурацией [scroll-configuration.md](scroll-configuration.md) и
архитектурой из [r06-scroll-arbitration-comparison.md](r06-scroll-arbitration-comparison.md)
(одна `UIScrollView`/`NSScrollView`-эквивалент на страницу, не relay, не
наивное вложение двух scroll).

### R07 — ScrollNode и viewport pipeline

- [x] Core state/commands, content measurement, clamp, clipping/coordinate mapping.
- [x] Offset-only путь; visibility/demand delta, отмена устаревшей подготовки.
- [x] Тесты пустого/короткого/длинного контента, вложенного clip/transform,
  resize/insets/RTL, reveal частично видимой ноды и границ.

Зависимость: R06. Приёмка: точная геометрия; на offset-only нет полного solve/raster.

**R07 закрыта 2026-09-16.** Построены и протестированы (57 новых тестов —
49 из первого прохода плюс 8 из `.unspecified`-фикса ниже —
`docs/validation/r07-scroll-node.md`): `ScrollNode`/`ScrollState`/
`ScrollCommand`/`ScrollCommandOutcome`/`ScrollConfiguration` (`TrellisCore`),
`NativeScrollBacking`/`NativeScrollBackingDelegate`/`ScrollCommandIssuing`
(`TrellisRender`), `UIScrollViewBacking`/`NSScrollViewBacking`
(`TrellisUIKit`/`TrellisAppKit`) — реальные native `UIScrollView`/
`NSScrollView`, не синтетический offset, встроенные для `ScrollNode` на любой
глубине дерева (не только в корне), позиционируемые через `setFrame(_:)`
после того, как прямая запись в `CALayer` нашла два реальных дефекта
(#66/#67, `docs/defects.md`) — один из них живым assertion-fail в
`AppKitScrollNodeEmbeddingTests.swift`, не гипотезой. Offset-aware
hit-testing реализует D18 (`ADR 0026`) — маршрутизация по ближайшему предку
композиционно, не первым найденным. Offset-only коммит-путь подтверждён не
триггерить layout snapshot (`test_hitTest_offsetOnlyTickDoesNotRequestANewLayoutSnapshot`).

Первая строка чек-листа закрыта отдельным изменением тем же днём:
`r06-scroll-api-sketch.md` §2 специфицировал `.unspecified`-constraint вдоль
прокручиваемой оси для детей `ScrollNode` (max-content basis, как ADR 0009
для auto-sized контента) — реализовано в `FlexboxEngine.resolveLines`
(`Sources/TrellisCore/Layout/FlexboxMeasure.swift`): контейнер с
`overflow == .scroll` подставляет `nil` вместо `availableMain` в расчёте
grow/shrink delta, так что дети сохраняют natural (max-content) main size
вместо сжатия до viewport'а. Cross-ось и собственный размер контейнера не
тронуты; регрессия для `.hidden`/`.visible` контейнеров исключена явными
тестами. Все `flexShrink = 0` обходные пути, которые тесты первого прохода
использовали для "длинного контента", убраны — `swift test` дважды подряд
после этого: 782/782 (293 TrellisRenderTests + 28 TrellisFluxTests + 461
TrellisCoreTests). Полное обоснование, таблица тестов и точная граница
(что именно осталось не тронуто — `.fraction`-размер вдоль scroll-оси без
диагностики, отдельный от grow/shrink basis-проход) — в
`docs/adr/0026-scroll-node-viewport.md` и `r07-scroll-node.md`.

Честно незакрытое, не влияющее на приёмку карточки: `api/*.json` baseline не
обновлён (окружение сессии — SwiftPM/Swift 6.4 без полного Xcode, продукты
сборки в `.build/out/Products/Debug`, не там, где `Scripts/check_api.py`
ищет `.build/arm64-apple-macosx/debug/Modules` — несоответствие окружения,
не правок этой карточки; повторная попытка после `.unspecified`-фикса дала
тот же результат); `check_all.py --matrix`/`UIKitScrollNodeEmbeddingTests.swift`
не прогнаны живьём (нет iOS/tvOS Simulator в этой сессии); `.fraction`-размер
вдоль scroll-оси без диагностики (узкая часть sketch §2, не задетая
`resolveLines`-правкой); сценарий 4 (`contentInsets` меняется во время
`.decelerating`) не тестирован — требует реального momentum в полёте.
Следующее: R08 (нативный touch/trackpad/wheel input, зависит от этой
карточки) — geometry pipeline, который он верифицирует живьём, существует и
протестирован для реального natural-content-size случая, не только
синтетического.

### R08 — Нативное движение, focus и AX

**В работе, 2026-09-18.** 2026-09-17: проведены configuration в native adapters
и offset-only semantic/AX/focus geometry (defect #71; evidence
[`r08-native-input.md`](validation/r08-native-input.md)).

2026-09-18: первый в проекте живой `xcodebuild`-прогон `Playground-iOS` на
реальном iPhone Simulator (не `swift build`) и первый смонтированный в
Playground `ScrollNode` (новый сценарий `S33_ScrollNodeInteraction`). Попутно
найден и исправлен дефект #74 (`UIScrollViewBacking.makeChildBacking` не
компилировался под реальным Xcode — никогда не ловилось `swift build`/`swift
test` на macOS, которые целиком исключают этот UIKit-only файл). Живой swipe
подтвердил: real UIKit drag/momentum/deceleration по `ScrollNode` работает.
Затем найден и в тот же день исправлен дефект #75 (два компонующихся root
cause, `docs/defects.md`/evidence): (1) `TrellisHostView`'s pointer pipeline
зависел от touch-колбэков на самом хосте, а R07's настоящий `UIScrollView`-
subview перехватывал hit-test раньше без форвардинга назад — ни один потомок
`ScrollNode` не получал pointer-события вообще; (2) после добавления
пассивного `UIGestureRecognizer`/`NSGestureRecognizer`-наблюдателя
(`TrellisTouchObserver`/`TrellisMouseObserver`) как фикса (1), без явного
`shouldRecognizeSimultaneouslyWith` UIKit/AppKit молча переставали доставлять
`touchesEnded`/`Cancelled` наблюдателю, как только `ScrollNode`'s собственный
pan recognizer реально начинал распознавание — оставляя залипшую pointer-
сессию, которая блокировала следующий tap (D30's single-touch enforcement).
Оба исправлены и подтверждены живьём на iPhone 18 Pro Simulator: swipe+tap на
карточку, открытую реальным drag'ом, теперь логирует `session-begin` →
`activated` → `session-end` и запикселено подтверждён `Palette.green`; drag,
начатый на уже активированной карточке, не активирует её повторно (D29
disambiguation не сломан). `swift test` (macOS) 787/787, `xcodebuild test`
(iPhone 18 Pro Simulator, `TrellisRenderTests`) 296/296, `check_policy.py`
чисто.

Далее пользователь сам прогнал `Playground-macOS` на реальном трекпаде
(живой `TRELLIS_LOG`): скролл (отдельный `scrollWheel`-канал, не пересекается
с `mouseDown/Dragged/Up`) и клик-после-скролла — `activated` с первого раза;
отдельно drag карточки в сторону с отпусканием снаружи — корректно без
`activated` между `session-begin`/`session-end`. AppKit-часть п.2/п.3
чек-листа подтверждена живым трекпадом, не только `AppKitPointerInputTests`.

Затем пользователь попытался запустить `Playground-tvOS` и поймал дефект #76:
приложение падало на старте (`UIApplicationEvaluateRuntimeIssueForNoScene
LifecycleAdoption`) — тот же класс, что #73 у iOS (tvOS-таргету не хватало
`INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, `AppDelegate` не
объявлял `UISceneConfiguration`/`UIWindowSceneDelegate`). Исправлено по
образцу iOS; живой запуск на Apple TV 4K Simulator подтверждён (скриншот,
`xcodebuild -scheme Playground-tvOS build` зелёный) — сцена монтируется без
краша.

**2026-09-23: реализация дополнена.** Согласован [ADR 0028](adr/0028-scroll-focus-reveal.md):
раскрытие скрытой committed цели предшествует focus; на tvOS новая identity
подтверждается native callback. Добавлены UIKit/AppKit AX page actions,
проверки scope/live route/offset geometry и корректная отмена native motion.
В Playground появились iOS/tvOS UI-test targets: настоящий touch scroll→tap,
XCUIRemote reveal→Select→reverse и detach из фактической `.decelerating`.
Последний сценарий воспроизвёл и после исправления перестал воспроизводить
UIKit crash при неправильном порядке native view/layer teardown (дефект #80).
Результаты и команды: [evidence](validation/r08-native-input.md).

- [x] Физические input-проверки выполнены пользователем: iPad input/resize,
  UIKit touch/deceleration, AppKit trackpad/momentum, tvOS remote/focus, AX scroll
  и detach во время движения. Это пользовательское подтверждение; конкретные
  модели, версии ОС и отдельные протоколы в этой сессии повторно не записывались.
- [x] Offset-aware hit test, tap after drag, reveal до native focus confirmation,
  AX actions и актуальные frames покрыты regression/UI tests.
- [x] Simulator: iPhone touch scroll→tap и detach во время `.decelerating`;
  Apple TV XCUIRemote reveal→Select→reverse.

**R08 закрыта 2026-09-23** с учётом подтверждения пользователя о проверке на
физических устройствах. Device/OS матрица для аппаратного прогона не заявлена
и не реконструируется из Simulator evidence. Остальная performance-матрица плана
и R15 этим не закрываются.

Зависимость: R07. Аппаратные проверки приняты по подтверждению пользователя;
device/OS матрица остаётся неуточнённой и отделена от Simulator evidence.

### R09 — Вложенность и закрытие результата B

- [x] `python3 Scripts/check_policy.py`: 0 diagnostics, в том числе
  PUBLIC_DOCUMENTATION; каждое новое public/open объявление содержит Ownership,
  Isolation, Errors, Cancellation. Документация добавляется вместе с API,
  не откладывается до R15.

- [x] Direction lock, ближайший eligible scroll, границы и распределение delta;
  явная политика momentum при handoff, без двойного потребления.
- [x] Арбитраж scroll с transition-close из M12/M13: закрытие только в разрешённом
  положении и направлении; после захвата жеста второй владелец не двигает контент.
- [x] Consumer: статья и горизонтальная галерея текстовых карточек; matrix/API/docs.

Зависимости: R05, R08. Приёмка: ScrollNode пригоден сам по себе; это ещё не C/D.

**R09 закрыта 2026-09-23** ([ADR 0029](adr/0029-scroll-gesture-arbitration.md),
[validation/r09-scroll-arbitration.md](validation/r09-scroll-arbitration.md)).
Арбитр фиксирует одну ось и одного владельца, возвращает consumed/unconsumed delta,
не выбирает нового владельца для momentum и не передаёт жест другому ScrollNode после
захвата. Нативный close-controller проверяет точку и начальное направление до arm:
scroll-предок, способный потребить движение, имеет приоритет; presented transition
закрывается только downward у ведущей границы. Consumer S34 собран во всех Playground
целях; focused R09 tests и iOS Simulator SDK build прошли. Ручной прогон S34 на физических
устройствах не выполнялся в этой сессии и остаётся дополнительной проверкой поведения
нативных recognizers.

### R10 — Контракт данных и окно материализации

**R10 закрыта 2026-09-23.** Решения пользователя: контейнер владеет своим ScrollNode через
композицию; дубли ID — first-wins с логом; trigger догрузки по умолчанию — 2 высоты viewport.
[ADR 0030](adr/0030-collection-data-contract.md); `Sources/TrellisCore/Collections/`:
snapshot, окна, пагинация, кэш измерений по `layoutRevision`, provider/dispatcher,
`MaterializationWindow`, общий `MaterializationBudget` хоста, `CollectionLoader`; 47 тестов,
10 000 моделей → ограниченное число нод. Попутно исправлен дефект #81 (ревизия environment).
Anchor/delta реализуются в R11, сборка контейнеров — R12. Подробно —
[evidence](validation/r10-data-contract.md).

- [x] Дополнить анализ collections по §3.1; measurement invalidation P6.9
  и correlation/log events P6.12 включить в контракт и тесты.

- [x] Зафиксировать DataSource/ItemProvider/Delegate/hooks P6.11: типобезопасность,
  module graph, source replacement, weak delegate и приоритет closures.

- [x] Уточнить make/update, state lifetime, общий host budget и measurement
  pipeline P6.9; внешний consumer P6.10 до реализации публичного API.

- [x] Разделить data batch trigger и UI preparation ranges по P6.8; определить
  page size/remaining items/viewport distance и защиту от no-progress loop.

- [x] Проверить согласованное разделение ListNode/TableNode и GridNode на consumer API;
  зафиксировать общую основу и настройки §1.2, без трёх копий scroll/runtime.

- [x] P6.4: IDs, duplicate policy, revision, snapshot/delta, anchor и estimated heights.
- [x] Visible/preload windows, ограниченные cache/jobs, отмена ушедших из demand.
- [x] Прототип 10 000 моделей создаёт ограниченное число Node/layers; стабильная
  identity остающихся в окне элементов, очистка вышедших проверяется weak-ссылками.

Зависимость: R09. Приёмка: размер live UI зависит от окна, не числа моделей.

### R11 — Транзакции и сохранение позиции

**R11 закрыта 2026-09-23 в пределах TrellisCore** ([ADR 0031](adr/0031-collection-transactions.md),
[evidence](validation/r11-collection-transactions.md)). Подготовка на воркере
(`PreparedCollection`, `CollectionUpdateQueue`), атомарный `commit` с отклонением устаревших
результатов, якорь для commit/измерений/resize, follow-bottom opt-in, ID-based
`CollectionDelta`; property-тест 5 seed × 120 шагов. Drag/deceleration смоделированы сдвигом
viewport между подготовкой и commit; применение offset к native scroll view во время реальной
прокрутки проверяется в R12a.

- [x] Фоновая подготовка diff/метрик, атомарный commit, bounded pending snapshots.
- [x] Prepend/delete/reorder/update heights, anchor deletion, follow-bottom;
  stale base revision, resize и detach между подготовкой и apply.
- [x] Property tests: порядок/identity соответствуют эталонной модели, anchor
  устойчив в оговорённом pixel tolerance, частичных commit нет.

Зависимость: R10. Приёмка: обновления из Flux во время drag/deceleration не
перемещают читаемую строку неожиданно и не применяют старые индексы к новым данным.

### R12a — ListNode и реактивная загрузка

**R12a закрыта 2026-09-23** ([ADR 0032](adr/0032-hosted-collection-containers.md),
[evidence](validation/r12a-list-node.md)). `ListNode` подключается к хосту сам
(`HostedContainer`/`ContainerHost`), сдвиги якоря применяются в том же geometry commit.
iPhone 18 Pro Simulator, XCUITest с удержанием настоящего drag во время прихода постов:
`drift=0.0 native=0.0` в 5 проверках; догрузка у конца. Попутно исправлены #84 (решение
пользователя, уточнение ADR 0026), #85, #86. Инерция на устройстве — ручная проверка.

- [x] Реализовать ListNode на R10/R11; lazy make/update, состояние по ID (P6.9).
- [x] Consumer 20 + 20: hooks P6.7, медленный API, prefetch P6.8, bounded preparation.
- [x] Проверить remount/data key, отсутствие повторных requests и stale commits.

Зависимость: R11. Приёмка: standalone список с переменной высотой и сохранением anchor.

### R12b — GridNode

**R12b закрыта 2026-09-23** ([ADR 0033](adr/0033-grid-node.md),
[evidence](validation/r12b-grid-node.md)). Ряды — прокручиваемая единица того же окна;
`ListNode`/`GridNode` — тонкие подклассы общего `CollectionNode`, второй копии runtime нет.
Попутно исправлен #87.

- [x] Общая data/lifecycle основа; колонки, spacing, размеры ячеек по контракту R10.
- [x] Изменение колонок/ширины, visible range, anchor и reactive hooks.

Зависимость: R12a. Приёмка: standalone grid; отдельной копии reactive runtime нет.

### R12c — TableNode и действия строк

**R12c закрыта 2026-09-23** ([ADR 0034](adr/0034-table-node.md),
[evidence](validation/r12c-table-node.md)). Секции, разделители, выбор и swipe-действия P6.6
на общем `CollectionNode`; настоящий swipe внутри вертикальной прокрутки проверен XCUITest на
iPhone Simulator; действия доступны через AX custom actions.

- [x] Строки/секции, separators, selection на общей основе; reactive hooks.
- [x] Swipe actions P6.6: leading/trailing, несколько действий, full swipe, RTL,
  update/delete/reuse, failure/retry, alternative input/AX и политики включения.

Зависимость: R12a. Приёмка: standalone таблица; pager для её закрытия не требуется.

### R12 — Закрыть результат C

**R12 закрыта частично 2026-09-23** ([ADR 0035](adr/0035-collection-reveal-and-row-focus.md),
[evidence](validation/r12-close-result-c.md)). Добавлены `scrollTo(_:)` с явным результатом и
фокусируемые строки таблицы; исправлен #88 (догрузка при Flux-публикации). Внешний consumer,
10 000 моделей, reveal/focus/AX, P6.9 и 100 циклов проверены; замеры сняты на macOS, iOS и
tvOS Simulator. Числовые бюджеты R06 не назначены: нет физических устройств и trace (§6).

- [x] `python3 Scripts/check_policy.py`: 0 diagnostics, в том числе
  PUBLIC_DOCUMENTATION; каждое новое public/open объявление содержит Ownership,
  Isolation, Errors, Cancellation. Документация добавляется вместе с API,
  не откладывается до R15.

- [x] Внешний consumer P6.10/P6.11 для всех трёх контейнеров: одна подписка,
  source replacement, closure/delegate dispatch, release и actor isolation.

- [x] Все три контейнера проверены standalone на доступных платформах.
- [x] Consumer: 10 000 моделей, prepend/delete/догрузка, обновления при scroll.
- [x] Focus/AX и reveal виртуализированного известного item; отсутствие дубликатов.
- [x] P6.9: возврат состояния после eviction, общий host budget, известный и
  отсутствующий scroll target, смена environment между prepare/apply.
- [x] Cold/warm scroll, fling/разворот, 100 циклов открытия/закрытия; matrix/API/docs.
- [ ] Числовые бюджеты R06 — открыто: только Simulator/хост, нет устройства и trace (§6);
  повтор протокола на устройствах — R15.

Зависимости: R12a/R12b/R12c. Приёмка: bounded materialization и рабочие контейнеры.
Интеграция страниц в pager проверяется только R14 и не блокирует результат C.

### R13 — Pager и вкладки

**R13 закрыта 2026-09-23** ([ADR 0036](adr/0036-pager-and-tabs.md),
[evidence](validation/r13-pager-tabs.md)). Решения пользователя: собственный pan, смонтированы
выбранная ±1. Страницы лежат в собственном горизонтальном `ScrollNode` pager (#91); индикатор
и страницы движутся одной `Animation` (`ScrollCommand.timed`). Проверено касаниями на iPhone
Simulator и пультом на Apple TV Simulator. Найдены #90, #91; #48 обойдён в `TabsNode`.

- [x] Lazy page factories и eviction P6.9: смена NodeID не теряет page ID,
  состояние модели/anchor/focus, фабрика не запускает API.

- [x] Stable page IDs, progress/selection, swipe/click/remote, cancel/retarget,
  динамический reorder/delete, ограниченное подключение соседних страниц.
- [x] Индикатор движется от того же progress; RTL/resize/Reduce Motion.

Зависимость: R09. Самостоятельная приёмка на простых страницах; списки — R14.
Приёмка: одна модель выбранной страницы, нет отдельных несогласованных анимаций.

### R14 — Collapsing header и интеграция профиля

Модель вертикальной координации принята пользователем 2026-09-23:
[ADR 0037](adr/0037-tabbed-scroll-coordination.md) (вариант Telegram, разбор —
[telegram-peerinfo-analysis.md](telegram-peerinfo-analysis.md)). Пороги и физика
горизонтального paging уже зафиксированы в ADR 0036. Карточка идёт в два этапа:
сначала композиция без передачи инерции, затем передача по ADR 0037 §5.

**В работе, 2026-09-23.** Этап 1 написан в облачной сессии без Swift/Xcode и **не собран**:
`TabbedScrollNode`, `ContainerHost.applyScrollConfiguration` (#93), передача колеса на macOS,
13 host-тестов, сцена S39. Проверки и открытые пункты —
[evidence](validation/r14-tabbed-scroll.md); ни один чекбокс не отмечен до прогона на Mac.

- [ ] Реализовать TabbedScrollNode/Tab/TabsNode по P6.5 и ADR 0037, оба режима
  .pinned/.inline; automatic отключает row swipe внутри pager; проверить explicit
  policies P6.6, смену контекста и альтернативный доступ к действиям.

- [ ] Подтвердить композицию §1.1: произвольный Node с детьми сверху, pager ниже,
  segmented и три разных типа страниц; высота около 1.5H и другие размеры.

- [ ] Блокировка прокрутки страниц до закрепления (ADR 0037 §3): действует до следующего
  касания, не откладывается до commit; UIKit и AppKit; AX scroll и колесо на
  заблокированной странице доходят до внешнего scroll.
- [ ] Позиции страниц по ADR 0037 §6: pinned tabs, независимые позиции, короткий контент,
  изменение высоты шапки, safe area и переключение вкладки в середине движения.
- [ ] Reveal/focus внутри страницы при раскрытой шапке сначала закрепляет вкладки (§7).
- [ ] Этап 2: передача инерции внешний → выбранная страница по ADR 0037 §5, скорость
  без приватного API; проверка на устройстве; на macOS — результат или явное «нет».
- [ ] Refresh и pagination имеют по одному владельцу, отмену и dedup demand.
- [ ] Профиль использует обычные ScrollNode/ListNode/GridNode/TableNode/pager; consumer не содержит
  ручной синхронизации native contentOffset, KVO, gesture forwarding и cleanup.

Зависимости: R12, R13. Приёмка: три страницы, включая короткую; глубокая позиция
каждой восстанавливается по принятому правилу, диагональные жесты не дёргают шапку.

### R15 — Закрыть результат D и весь план

- [ ] `python3 Scripts/check_policy.py`: 0 diagnostics, в том числе
  PUBLIC_DOCUMENTATION; каждое новое public/open объявление содержит Ownership,
  Isolation, Errors, Cancellation. Документация добавляется вместе с API,
  не откладывается до R15.

- [ ] Второй consumer: каталог с другой шапкой/вкладками на том же coordinator,
  без изменений инфраструктуры под второй экран.
- [ ] Полные check_all.py --matrix, consumer/API, документация, provenance,
  отдельная таблица macOS/iOS/tvOS, Simulator/device и доступных input-устройств.
- [ ] Native video/input trace, воспроизводимые данные и profiler trace;
  deterministic samples не выдаются за доказательство кадровой плавности.
- [ ] Сравнить с бюджетами R06, отметить все невыполненные пункты явно.

Приёмка: A/B/C/D закрыты отдельно; ни один не объявлен готовым по прототипу.

## 6. Измерения и ограничения приёмки

В R06 записать конкретные hardware/OS/refresh rate, dataset, release build,
число повторов и числовые пределы до оптимизаций. На 60/120 Hz полный frame
имеет 16.67/8.33 ms; это не целиком бюджет Trellis. Отдельно задать меньший
MainActor budget по baseline. Отсутствие устройства не разрешает придумать цифры.

Обязательные метрики: p50/p95/p99 MainActor snapshot/commit; worker layout/raster;
пропущенные кадры; peak/resident bitmap memory; live nodes/layers/subscriptions;
active/pending jobs; время first useful frame и восстановления anchor.
Для 1 000/10 000 моделей с одинаковым viewport сравнить live UI и pending work:
они ограничены одним и тем же оконным бюджетом. Стоимость diff данных отдельно
может зависеть от N, но полный обход live tree не должен выполняться на каждый tick.

Фикстуры: текст переменной высоты, бурсты state, stale requests, длительный fling,
prepend при чтении, смена ширины, повторные detach/attach, переключение страниц.
Любые пороги и допуски сохраняются в evidence до финального прогона. При
недоступном профилировании результат отмечается частичным, не «плавность доказана».

### 6.1. Native performance harness — подготовить в R06

Выбранный путь: реальные app targets `Playground/iOS`, `Playground/tvOS`,
`Playground/macOS` и общие synthetic scenarios/measurement recorder под
`Playground/Shared`. CLI Bench остаётся для solver/diff/raster microbenchmarks.
Он не измеряет UIKit/tvOS input или нативную прокрутку даже при импорте TrellisFlux.

R06 добавляет воспроизводимый launch configuration: scenario ID, seed/count,
viewport, режим/число повторов. Native UI tests с XCUITest выполняют фиксированные
сценарии touch/remote; XCTest measure может агрегировать время, но не заменяет
распределение длительностей commit и кадровый trace. Настроить UI-test targets
в Playground.xcodeproj и документировать точные xcodebuild destinations/команды.
Для AppKit/iPad trackpad momentum сохранить отдельный ручной hardware сценарий
и evidence, если автоматизация не воспроизводит настоящий способ ввода.

Общий bounded recorder собирает timestamp/duration/counters для snapshot, worker,
commit и materialization; не накапливает сами модели или неограниченный event log.
Экспорт JSON/CSV: p50/p95/p99, samples, warmup/repeats, device/OS/build/refresh,
peak nodes/layers/jobs/bitmap bytes и source revision. Native signposts/платформенная
инструментация остаются в adapters/harness согласно import policy.
Кадры/пропуски и MainActor stalls подтверждать Instruments trace на доступном
устройстве; видео и одни только интервалы callbacks не доказывают hitch rate.
Замеры с выключенным подробным логом, отдельно оценить overhead recorder.

Baseline сохраняется в `docs/validation/r06-native-performance/` с командами,
результатами и ссылками на traces; R15 повторяет тот же protocol и сравнивает
одинаковые hardware/configurations. Для iPhone, iPad и tvOS отдельные строки.
Недоступный device/trace означает открытый пункт и отсутствие соответствующего
числового бюджета: Simulator correctness и CLI timing его не заменяют.

## 7. За пределами плана

Полный Telegram data stack, ImageNode/network image cache, произвольные grid-solvers
и универсальный reconciliation, drag-reorder, cross-window navigation,
двухосевой canvas и собственный физический движок прокрутки не входят.
Изображения для профиля — локальные fixtures через уже доступный render-путь;
N02 не становится скрытой зависимостью. Новых гарантий создания live Node
в фоне и полной идентичности Texture этот план не вводит.
