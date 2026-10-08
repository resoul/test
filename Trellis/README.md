# Trellis

UI-фреймворк для Apple-платформ: дерево нод на MainActor, flex-раскладка вне
MainActor по иммутабельному снимку, рендер в `CALayer`.

**Статус: этап 1 реализован.** Все майлстоуны плана закрыты: M1 (базовый пакет,
геометрия, mutable-стили), M2 (`Node`, единая инвалидация, `FlexboxEngine` с
отменой, `LayoutScheduler`), M3 (`RenderCoordinator`, единый `LayerRenderer`,
`NodeHostBridge`), M4 (платформенные хосты, `Playground` со сценариями
S01–S20), M5 (`Arrangement`: `Row`/`Column`/`Overlay`, автоматический resolve
перед каждым snapshot) и M6 (`DebugOverlay`, нагрузочные измерения, CI-матрица,
эта документация). Полный конвейер от дерева нод до нативного отображения на
всех Apple-платформах собран и проверен, включая декларативное описание детей
и минимальный реактивный путь model → Node → render.

Два пункта приёмки остаются открытыми и названы явно, а не скрыты: физическая
проверка на iOS/iPad/tvOS недоступна (нет устройств — [C20](docs/validation/c20-physical-verification.md),
[C27](docs/validation/c27-ci-and-matrix.md)), и CI-workflow не прогонялся на
настоящем hosted-раннере (в репозитории нет git remote) — только эквивалентной
командой локально с тем же пином Xcode. Полный список карточек и их приёмка —
[docs/implementation-plan.md](docs/implementation-plan.md); реестр найденных и
исправленных дефектов — [docs/defects.md](docs/defects.md).

## Что это

Trellis — новый продукт, а не версия 2.0 существующего `Weave`. Из Weave
переносится только то, что реально участвует в построении дерева и раскладке;
остальное не переносится. Разбор источника и матрица переноса —
[docs/weave-analysis.md](docs/weave-analysis.md).

Модель в одном абзаце: `Node` живёт на MainActor и владеет своим стилем и
детьми. При изменении дерева собирается иммутабельный `Sendable`-снимок, он
уезжает в фоновую задачу, там чистая функция считает геометрию, результат
проверяется на актуальность и синхронно применяется на MainActor к `CALayer`.
Живые объекты за пределы MainActor не выходят никогда.

## Границы первого этапа

Входит: `Node` и операции дерева, `LayoutStyle` с прямым присваиванием полей,
flex-раскладка, планировщик с отменой, рендер в `CALayer`, тонкие хосты UIKit
и AppKit, `arrangeSubnodes()` для описания раскладки детей в подклассе (хост
резолвит его сам перед snapshot; `markArrangementDirty()` — когда описание изменилось),
минимальный реактивный путь (`StateSubject` → `TrellisHostView.bindState` →
`update(model)` на своей ноде), диагностика через `Log.on` и DebugOverlay.

Не входит: Text, Image, контролы, события и hit-testing, скролл и коллекции,
анимации, навигация, accessibility, focus, Grid, реконсиляция по дескрипторам,
инфраструктура приложения. Полный список и условия старта — раздел 7 плана.

## Требования

| | |
|---|---|
| Swift | 6.0, language mode 6, strict concurrency |
| Платформы | macOS 14, iOS 16, tvOS 16 |
| Внешние зависимости | [Flux](https://github.com/resoul/flux) 1.2.1 (`exact` pin), только для `TrellisFlux` (R02, план 6, P6.1) |

## Подключение

Планируемая форма (D01 — принято, facade `import Trellis` не вводится):

```swift
import TrellisCore     // Node, LayoutStyle, раскладка
import TrellisUIKit    // iOS, iPadOS, tvOS
// import TrellisAppKit   // macOS
```

### TrellisFlux и реактивные данные (план 6)

`TrellisCore`/`TrellisRender`/`TrellisUIKit`/`TrellisAppKit` остаются без внешних
зависимостей — `Flux` не протекает в solver/raster. Consumer, которому нужна
Flux-интеграция (ScrollNode/списки/reactive data, план 6), дополнительно
подключает `TrellisFlux`:

```swift
import TrellisFlux      // реэкспортирует Flux; TrellisCore/TrellisRender не меняются
import TrellisUIKit     // или TrellisAppKit — платформенный host
```

`Package.swift` пинит Flux точной проверенной версией
(`Scripts/verify_bootstrap.py`'s `manifest_issues` не даёт заменить её диапазоном
или другим URL без правки скрипта). Для локальной разработки против
непроверенного checkout Flux (`../old/flux`) манифест не редактируется — вместо
этого используется штатный SPM override:

```sh
swift package edit Flux --path ../old/flux   # начать override
swift package unedit Flux                    # вернуться к pinned-релизу
```

`swift package edit` требует, чтобы `../old/flux` был git-репозиторием с тем же
именем пакета (`Flux`); он не меняет `Package.swift` и не должен коммититься —
`swift package unedit` перед публикацией/CI обязателен.

```swift
final class RootViewController: UIViewController {
    private let host = TrellisHostView()

    override func viewDidLoad() {
        super.viewDidLoad()
        host.frame = view.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host)
        host.attach(root: makeTree())
    }
}
```

Хост удерживает корень до `detach()`, поэтому передавать временное дерево
безопасно.

### Описание детей через Arrangement (рекомендуемый способ)

Подкласс `Node` переопределяет `arrangeSubnodes()` вместо ручного
`addSubnode`/`removeFromSupernode`: хост сам вызывает resolve перед каждым
snapshot, а `markArrangementDirty()` — единственное, что нужно вызвать при
изменении описания.

```swift
final class ProfileCard: Node {
    let avatar = Node()
    let title = Node()
    let subtitle = Node()

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(spacing: 12, align: .center) {
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

Ручная мутация дерева (`addSubnode`/`removeFromSupernode`) и `Arrangement`
взаимоисключающие для одного и того же владельца: ненулевой `Arrangement`
управляет полным списком детей, `nil` возвращает узел в ручной режим (D05).

### Реактивный путь: модель → нода → рендер

`StateSubject` — latest-value источник (без очереди устаревших значений);
`bindState` доставляет каждое отличающееся значение на MainActor, пока хост
attached и не suspended:

```swift
let subject = StateSubject(DownloadModel(progress: 0))

host.bindState(subject) { [card] model in
    card.update(model)   // сравнить, смутировать style/appearance/children,
                          // при изменении описания — markArrangementDirty()
}

subject.send(DownloadModel(progress: 0.4))
```

`detach()` останавливает доставку, не забывая подписку; повторный `attach`
получает текущее значение немедленно.

### Focus, клавиатура и accessibility

Focus-ядро и семантическое дерево живут в `TrellisCore`; хост (`TrellisHostView`)
подключает клавиатуру/Siri Remote и VoiceOver сам — приложению нужны только
metadata на нодах и один обработчик activation (D35–D48, ADR 0013).

```swift
final class BuyButton: ControlNode {
    override init(style: LayoutStyle = LayoutStyle(),
                  appearance: VisualStyle = VisualStyle(),
                  environment: EnvironmentScope? = nil) {
        super.init(style: style, appearance: appearance, environment: environment)
        // ControlNode уже focusable и уже элемент VoiceOver; label задаёт автор.
        accessibility.label = "Buy"
        accessibility.hint = "Adds to cart"
        accessibility.customActions = [AccessibilityCustomAction(id: "share", name: "Share")]
        onAccessibilityAction = { action in action == .custom("share") }
        // Одна activation для tap, Return/Space, Select и VoiceOver activate (D43).
        activation = { [weak self] in
            guard let self else { return }
            print("activated from", self.lastActivationSource as Any)
        }
    }

    // isFocused/isPressed — состояние control; ring и pressed-фон — paint-only.
    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        appearance.border = isFocused ? Border(color: ThemeColor(red: 0.2, green: 0.8, blue: 0.9), width: 3) : nil
    }
}
```

- **Metadata.** `node.focus` (`isFocusable`, `priority`, `preferredNext`) и
  `node.accessibility` (`isElement`, `label`/`value`/`hint`/`identifier`, `role`,
  `isSelected`, `sortPriority`, `childrenPolicy`, `actions`, `customActions`) —
  value-типы; равное значение не делает ничего, изменение публикуется без
  layout pass. `ControlNode.isEnabled` — единственный источник enabled для
  focus, activation и AX. Роли: `button`, `text`, `image`, `header`, `link`,
  `group`, `adjustable`; policies: `.contain`, `.combine`, `.ignoreSelf`, `.hide`.
- **Focus.** `host.focusedID`, `host.focus(id)`, `host.moveFocus(.next)`,
  `host.onFocusChange`. Tab/Shift-Tab — порядок дерева, стрелки — геометрия,
  без wrap; на границе клавиша уходит системе (keyboard trap нет). На tvOS
  focus подтверждает система (proxies без UIView); стрелки там — её.
- **Modal scope.** `host.setFocusScope(dialog.id)` ограничивает focus и
  VoiceOver поддеревом (Tab внутри циклический), `setFocusScope(nil)`
  восстанавливает прежний focus. Scope открывается только для committed
  ноды — после того, как диалог попал в commit.
- **Действия.** `performAccessibilityAction(_:)`/`onAccessibilityAction`
  возвращают `true` только при фактической обработке; disabled, скрытые и
  устаревшие элементы действие не получают.
- **Владение и отмена.** Engine и снимки хранят только `NodeID`; native
  proxies принадлежат хосту и живут ровно столько, сколько их нода в
  опубликованном снимке. `detach()` очищает focus, scope, proxies и открытый
  press-cycle без событий; `suspend()` снимает focus с сохранением для `resume()`.
  Закрытие activation-closure с `[weak self]` — control владеет им.

Подробно: [docs/decisions.md](docs/decisions.md) D35–D48 и
[docs/validation/a01-focus-accessibility-contract.md](docs/validation/a01-focus-accessibility-contract.md).

### Текст (`TextNode`)

`TextNode` — леф с `TextDocument` (`AttributedString`) и `TextStyle`
(шрифт/размер/вес/межстрочный интервал/выравнивание/цвет по умолчанию,
run-level переопределения через `.trellisText`), `maxLines`/`truncation`.
Измерение идёт через `ContentMeasurer` (D49) — солвер вызывает его на
реальном resolved constraint, а не на значении, захваченном один раз в
снимке.

```swift
var document = TextDocument("Regular, ")
var bold = AttributedString("bold")
bold.trellisText.weight = .bold
document.append(bold)

let label = TextNode(document: document, textStyle: TextStyle(pointSize: 15))
label.maxLines = 2
label.truncation = .tail
```

- **CoreText в `TrellisRender`.** `CoreTextRenderer`/`CoreTextTypesetter` —
  единственная типографика в проде: измерение —
  `CTFramesetterSuggestFrameSizeWithConstraints`, рисование —
  `CTFramesetterCreateFrame`/`CTFrameDraw`, оба пути строят
  `NSAttributedString` через одну и ту же внутреннюю
  `makeAttributedString`, чтобы line breaks у измерения и рисования не
  расходились (закрывает класс дефекта #37). `PortableFallbackMeasurer`
  (`TrellisCore`, D51) — детерминированная заглушка только для headless
  тестов `TrellisCore` без реального рендерера; не типографика, не
  используется вне тестов.
- **Environment-ключи текста.** `TextRendererKey` (`(any TextRenderer)?`) и
  `LocaleKey` (`String`) — `TrellisAppKit`/`TrellisUIKit`'s
  `TrellisHostView.attach(root:)` выставляет их на корне сам
  (`CoreTextRenderer()`, `Locale.current.identifier`) и обновляет `LocaleKey`
  при смене системной локали; без хоста (голый `NodeHostBridge`/юнит-тесты)
  `TextRendererKey` не установлен, и `TextNode` меряется
  `PortableFallbackMeasurer`. `ThemeKey` (`Theme`/`ThemeColors`) — не
  специфичен для текста, но тем же путём (`Node.setEnvironment`/
  `EnvironmentScope`) резолвит `ThemeColorRole` в конкретный `ThemeColor`
  (`resolveThemeColor(_:in:)`, `TrellisRender`), в том числе для
  `TextStyle.color`/run-level `.trellisText.color`.

Подробно: [docs/decisions.md](docs/decisions.md) D49–D58 и
[docs/validation/t12-scenes-references-docs.md](docs/validation/t12-scenes-references-docs.md).

### Анимация (`Node.animate`)

Одна точка входа для явной анимации свойств: `node.animate(_ animation:, _
changes:)` задаёт область движения (поддерево `node`), новые значения и
характер перехода — новые значения применяются сразу, переход стартует на
актуальном коммите. `.smooth` — 250 мс ease-in-out, `.none` — мгновенный
переход, `.linear`/`.easeIn`/`.easeOut`/`.easeInOut(duration:)` — явная
длительность. Поддерживаемая таблица свойств (D61):
`position`/`bounds`/`opacity`/`transform`/`backgroundColor`/`cornerRadius`.

```swift
list.animate(.smooth) {
    description.maxLines = expanded ? nil : 2
}
```

- **Область и смешение (D62/D63).** Пересекающиеся вызовы разрешаются по
  sequence (кто позже — тот и побеждает в общей части); обычная мутация вне
  области снапается, даже попав в тот же коммит. Раскрытие карточки в списке
  использует `list.animate`, а не `card.animate`, когда должны сдвинуться и
  соседние карточки — область движения это подтверждает.
- **Retarget (D66).** Повторный вызов до завершения перехода стартует новую
  цель от текущего видимого значения, не от исходной модели — без скачка.
- **Текст под анимацией (D65).** Внутренний raster-слой `TextNode` никогда не
  анимируется сам — при resize старый bitmap остаётся clipped (не
  растянутым) до готовности нового; смена текста/стиля убирает старое
  содержимое немедленно.
- **Reduce Motion (D67).** `Node.setReduceMotion(_:)` — вложенный, не
  bridge-wide переключатель: подключён к environment, резолвит каждый
  `.animate` в этом поддереве к снапу, пока включён.
- **Готовность экспорта (D69).** `NodeHostBridge.sceneReadiness` /
  `waitUntilSceneReady(timeout:)` — три независимые оси (layout/display/
  animation), таймаут — `SceneReadinessError.timeout`, не разрешение снять
  промежуточный кадр.

Подробно: [docs/implementation-plan-5.md](docs/implementation-plan-5.md),
[docs/decisions.md](docs/decisions.md) D61–D69 и
[docs/validation/m08-close-result-a.md](docs/validation/m08-close-result-a.md)
(итоговая таблица M01–M08).

## Диагностика

Вывод включается переменной окружения — работает и при запуске на физическом
устройстве, пересборка не нужна:

```
TRELLIS_LOG=all
TRELLIS_LOG=off
TRELLIS_LOG=schedule,commit,layer,host
```

Формат строк: `[trellis.<area>] <event> host=<h> gen=<g> #<node> parent=#<parent> <details>`.

## Проверки

```bash
python3 Scripts/check_all.py
python3 Scripts/check_all.py --matrix
```

Обычный прогон проверяет policy и её фикстуры, toolchain, форматирование,
manifest без внешних зависимостей, сборку, Swift-тесты, отдельный локальный
consumer, API baseline модулей (`Scripts/check_api.py --tvos`), побайтное
совпадение скриншотов всех сцен Playground с
`docs/validation/screenshots` (`Scripts/check_screenshots.py`; собирает и
запускает Playground-macOS, поэтому нужен window server — `--skip-screenshots`
выключает) и поведение `TRELLIS_LOG` в реальном процессе
(`Scripts/check_log_env.py`). Изменившийся скриншот принимается только явно:
`Scripts/check_screenshots.py --update --review-note <ADR или отчёт>`; условия
воспроизводимости — [docs/validation/screenshot-gate.md](docs/validation/screenshot-gate.md). Матрица
дополнительно собирает macOS arm64/x86_64 и iOS/tvOS device destinations
(build-only — в CI нет подключённого устройства) и **реально запускает**
(`xcodebuild test`, не только build) весь набор тестов на конкретном iOS и
tvOS Simulator нужной SDK — C27, [docs/validation/c27-ci-and-matrix.md](docs/validation/c27-ci-and-matrix.md).
Симулятор не заменяет физическое устройство.

Измерения (C31): `python3 Scripts/bench.py` собирает `Bench/` в Release и пишет
`docs/validation/measurements/`; `--log all` — профиль накладных расходов диагностики.
Время не является gate; точные счётчики закреплены тестами.

Отчёты и команды сохраняются в `.build/bootstrap-validation/`. Не требуется
Flux или получение пакетов из сети. Пины инструментов — `toolchain.json`;
изменение пинов должно быть явным. API baseline снят и зафиксирован в `api/*.json`.
Workflow `.github/workflows/quality.yml` запускает `check_all.py --matrix
--skip-screenshots`; в репозитории нет git remote, поэтому это не заменяет
реальный hosted-прогон — только эквивалентную команду, проверенную локально.

## Документы

| Файл | Назначение |
|---|---|
| [docs/defects.md](docs/defects.md) | Реестр всех найденных дефектов: что было не так, как найден, где исправлен или в какой карточке закрыть |
| [docs/decisions.md](docs/decisions.md) | Принятые контракты |
| [docs/source-provenance.md](docs/source-provenance.md) | Источник переноса, лицензии |
| [AGENTS.md](AGENTS.md) | Правила работы в репозитории |
| [docs/implementation-plan.md](docs/implementation-plan.md) | План исполнения, задачи, приёмка — каждая карточка ссылается на свой evidence-отчёт в `docs/validation/` |
| [docs/implementation-plan-2.md](docs/implementation-plan-2.md), [docs/implementation-plan-3.md](docs/implementation-plan-3.md) | Этап 2: hit-testing и события (H01–H11); focus engine и accessibility (A01–A13) |
| [docs/implementation-plan-6.md](docs/implementation-plan-6.md) | План: интеграция Flux, ScrollNode, виртуализированные списки и профиль с вкладками (R01–R15) |
| [docs/validation/](docs/validation/) | Evidence по каждой карточке C01–C32, H01–H11, A01–A13: что проверено, как, и что осталось открытым |
| [docs/weave-analysis.md](docs/weave-analysis.md) | Анализ Weave и матрица переноса — исторический документ, см. пометку в его начале |
| [docs/history/weave-2.0-draft.md](docs/history/weave-2.0-draft.md) | Исторический черновик |

## Лицензия

[MIT](LICENSE).
