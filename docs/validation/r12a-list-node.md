# R12a — ListNode и реактивная загрузка

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R12a.
Зависимость: R11 (закрыта). Решения: [ADR 0032](../adr/0032-hosted-collection-containers.md)
поверх ADR 0030/0031; уточнение [ADR 0026](../adr/0026-scroll-node-viewport.md) (решение
пользователя по #84).

## Что реализовано

| Файл | Содержание |
|---|---|
| `Sources/TrellisCore/Collections/HostedContainer.swift` | `HostedContainer`, `ContainerHost`, `ContainerBinding`, `ContainerCommit` |
| `Sources/TrellisCore/Collections/ListNode.swift` | `ListNode<Provider>`: свой `.column` ScrollNode, окно, loader, очередь, dispatcher; `refresh()`, `retry()`, `followsBottom`, диагностический `appliedOffsetShift` |
| `Sources/TrellisRender/Scroll/NodeHostBridge+Containers.swift` | bridge как `ContainerHost`: обнаружение контейнеров после commit, attach/commit/detach, общий `MaterializationBudget` с проходом на commit, `bindContainerState` через `bindState` (D14), сдвиги offset внутри geometry commit |
| `Sources/TrellisCore/Scroll/ScrollNode.swift` | #84: направление следует за осью, `scroll-axis-mismatch` в логе |
| `Sources/TrellisCore/Layout/FlexboxMeasure.swift` | #86: авторазмер scroll-контейнера вдоль прокручиваемой оси ограничен `.atMost` родителя |
| `Sources/TrellisCore/Collections/CollectionLoader.swift` | #85: нет догрузки до первых данных |
| `Playground/Shared/Scenarios/S35_ListNodeFeed.swift` | consumer: лента, 20 + 20 с медленного API, посты сверху, проба дрейфа |
| `Playground/UITests/iOSScrollTests.swift` | XCUITest: удержание настоящего drag во время прихода постов |

Потребитель пишет только `ListNode(source:provider:)`, hooks загрузки и кладёт узел в
дерево — без `bindState`, Task, KVO, ручного contentOffset и cleanup.

## Проверки

**Core/Render (`swift test`, macOS):**

- `ListNodeHostTests.swift` (6, настоящий `NodeHostBridge`, тестовый backing): 20 + 20 с
  медленным API — один `.loadMore` при серии тиков, повторных запросов нет пока API молчит;
  remount без повторного initial; смена data key — поздний ответ старого ключа не
  применяется; prepend во время drag — позиция читаемой строки ≤ 0.5 pt, native offset
  сдвинут в том же geometry commit, программных scroll-команд 0, следующий тик drag
  продолжается от скорректированного offset; 10 000 моделей → ≤ 48 живых нод; detach
  освобождает binding/загрузки/бюджет; удалённый из дерева список отключается на следующем
  commit.
- `AppKitListNodeTests.swift` (1, настоящий `TrellisHostView` + `NSScrollView`): prepend после
  прокрутки пользователем сдвигает clip view на вставленную высоту в том же commit, строка на
  месте, document view равен протяжённости контента.
- `CollectionLoaderTests.swift` +1 (#85), `ScrollStateTests.swift` +4 (#84, #86).

**iOS Simulator (iPhone 18 Pro, iOS 27.0), XCUITest с настоящими касаниями,**
`testListNodeKeepsReadPostWhileDraggingThroughArrivals`: после загрузки 40 постов палец
медленно тянет список и неподвижно держит его 5 с; посты приходят сверху каждую секунду.
Результат: `posts=50 requests=2 drift=0.0 native=0.0 checks=5 held=5`. `drift` — смещение
читаемого поста сверх сдвигов, которые применил сам список (от движения пальца не зависит);
`native` — изменение native offset сверх этих сдвигов, пока палец держит drag неподвижно,
то есть UIKit сохраняет установленный во время жеста offset. Затем свайпы к концу:
`posts=90 requests=4` — следующие страницы подгружаются у конца.

Команда:

```
xcodebuild test -project Playground/Playground.xcodeproj -scheme Playground-iOS \
  -destination 'platform=iOS Simulator,id=881F0552-3DF5-4A9E-A001-AF0BB7587217' \
  CODE_SIGNING_ALLOWED=NO -only-testing:R08-iOS-UITests/TouchScrollTests
```

Прогон всех iOS UI-тестов (новый + два R08): `** TEST SUCCEEDED **`.

Прочие прогоны: `swift test` — Core 534, Flux 28, Render 321 (в одном из двух полных прогонов
упал нестабильный M12, дефект #82; повтор render-набора чистый); `check_policy.py` — 0;
`swift format lint` чисто; strict build тестов (`-warnings-as-errors`) чисто; API baseline
TrellisCore/TrellisRender обновлены с `--review-note docs/adr/0032-hosted-collection-containers.md`
(в Core изменилась ещё не выпущенная сигнатура `CollectionAdjustment.init`, добавлен `delta`).

Это Simulator, не устройство. Инерционная прокрутка (deceleration) автоматическим тестом не
проверена: во время неё движение пользователя нельзя отделить от сдвига в пробе. Лог
`scroll-adjust-applied … phase=decelerating` на реальном fling — ручная проверка.

## Найдено по ходу

- #84 (исправлен, решение пользователя): у `ScrollNode()` по умолчанию вертикальная ось, но
  `.row` — вертикально не прокручивался.
- #85 (исправлен): догрузка запрашивалась до первых данных.
- #86 (исправлен): авторазмер scroll-контейнера по прокручиваемой оси равнялся контенту.
- Ошибки собственного сценария (не дефекты Trellis): модель не удерживалась, проба засчитывала
  движение пальца, статус обновлялся только при смене видимых постов.
- Ограничение для потребителей: flex-basis списка — вся протяжённость контента, а в Trellis
  нет CSS `min-height: auto`; соседей ListNode в колонке нужно помечать `flexShrink = 0`
  (или задавать списку высоту), иначе они сжимаются. Решение о семантике basis
  scroll-контейнера — открытый вопрос для R12/R14.

## Не закрыто этой карточкой

- Selection/строки/секции — R12c; grid — R12b.
- Инерция на устройстве и trackpad momentum на macOS — ручная проверка.
- Полный `check_all.py` по-прежнему останавливается на screenshot gate (#83); S35 добавляет
  ещё одну сцену без эталона.
