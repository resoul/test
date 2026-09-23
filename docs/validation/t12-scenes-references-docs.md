# T12 — Сцены, эталоны, матрица, документация

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
последняя карточка плана 4 (N01). Зависит от T08–T11.

## 1. Что добавлено

Три новые сцены Playground (`Playground/Shared/Scenarios/`), первые в этом плане,
которые используют реальный `TextNode`:

- **S24_Typography** — пять независимых боксов: смешанные run'ы в одном документе
  (regular/bold/big/colored, D55); три `TextAlignment` (leading/center/trailing) против
  одной и той же ширины; RTL-строка (`שלום עולם`) с физическим разрешением `.leading`
  под `LayoutDirection.rightToLeft` (D49); `maxLines: 2` + `.tail` truncation на
  заведомо длинном абзаце; пустая строка (`TextNode(text: "")`) рядом с
  фиксированным маркером — коммитится без падения/NaN.
- **S25_TextList** — `TextListNode`: 200 строк `TextNode` в колонке
  `flexShrink = 0` внутри `viewport` (288×560, `overflow: .hidden`) — форма
  T11's `text-list-1000`/`text-burst-edits` в масштабе Playground; 5 строк
  переписываются каждый тик (`ScenarioSession`), сохраняя `NodeID`/`CALayer`
  identity (не пересоздавая строки).
- **S26_LabeledSemantics** — переиспользует немодифицированные
  `FocusCardNode` (S22) и `SelectableCardNode`/`VolumeCardNode` (S23),
  добавляя видимую подпись (`TextNode`, 13pt) под каждым — то, что S22/S23
  сознательно проверяли только через VoiceOver/accessibility API, теперь видно
  и зрячему ревьюеру, не трогая собственные деревья/эталоны S22/S23.

`Playground/Shared/Scenario.swift`: `ScenarioNodes.root(mode:)` теперь
устанавливает `ThemeKey` (`Palette.theme`) на корне — не влияет на S01–S23
(ни одна не читала `environment.theme`); новые общие хелперы
`collectTextNodeIDs(_:)`/`waitForRenderReady(root:host:...)` — export ждёт
готовности **и** layout (`calculatedFrame != nil`), **и** текущих display
artifacts для каждого видимого `TextNode` (`host.displayArtifact(for:) !=
nil`) с bounded timeout (200 тиков × 10ms по умолчанию), вместо
фиксированной задержки после geometry commit — сама карточка требовала
именно это ("Export ждёт готовности layout + актуальных display artifacts с
bounded timeout"). `Playground/macOS/PlaygroundApp.swift`'s
`waitForFirstCommit()` использует этот хелпер напрямую.

`Sources/TrellisAppKit/TrellisHostView.swift` и
`Sources/TrellisUIKit/TrellisHostView.swift`: новый публичный метод
`displayArtifact(for id: NodeID) -> DisplayArtifact?` — тонкая обёртка над
`NodeHostBridge.displayArtifact(for:)` (уже существовал), нужная
`waitForRenderReady` выше, чтобы проверить готовность растра снаружи хоста
без `@testable`. Аддитивное изменение API — см. §5.

## 2. Найденные и исправленные дефекты Trellis (не Playground-сцен)

Обе находки — реальные баги в `TrellisCore`/`TrellisRender`, обнаруженные
при построении новых сцен, заведены в [defects.md](../defects.md) **до**
исправления, как того требует приёмка T12.

### 2.1. Дефект #46 — `FlexboxMeasure.measure` игнорировал собственный размер лефа

Леф с явным `style.width` (в row) или `style.height` (в column) измерял своё
содержимое против constraint'а, пришедшего от родителя (`.unspecified` на
главной оси во время basis-прохода, ADR 0009) — не против собственного явного
размера. Для обычных нод это было незаметно; для content-зависимого лефа
(переносящийся `TextNode`) высота, зависящая от переноса, мерилась по
фактически неограниченной ширине и никогда не переносилась, а более поздний
проход с точным constraint'ом не срабатывал (basis уже совпадал с resolved
размером — `FlexboxPlacement.reusableMeasure`'s триггер на переизмерение не
взводился). Найдено при построении S24 (`maxLines: 2` абзац рендерился одной
необрезанной строкой вместо двух). Исправлено — `FlexboxMeasure.measure`
теперь предпочитает собственный resolved `style.width`/`style.height` лефа
входящему constraint'у, когда он задан; регрессия закрыта
`test_contentMeasurer_explicitMainSizeOnALeafConstrainsItsOwnContentMeasurement`
(`Tests/TrellisCoreTests/Layout/ContentMeasurerTests.swift`). D49
([decisions.md](../decisions.md)) дополнена уточнением.

### 2.2. Дефект #47 — `CoreTextTypesetter.rasterize` рисовал пустое изображение на некоторых pointSize

`rasterize()` строил `CTFramesetterCreateFrame`'s path ровно в высоту,
которую `measure()` только что вернул как высоту одной строки. На некоторых
размерах шрифта (проверено сканированием 6…60pt — 13pt и 32pt оказались
сломаны на пиненном тулчейне) `CTFrameGetLines` на коробке именно такой
высоты возвращал ноль строк вместо одной, которая туда должна была влезть —
`rasterize()` молча растеризовал полностью пустое изображение для настоящего
непустого текста. Найдено при построении S26 (13pt подписи рендерились
пустыми несмотря на верные frame/layer/artifact на каждом шаге пайплайна).
Исправлено — `rasterize()` строит path для `CTFramesetterCreateFrame` на 1pt
выше `request.size.height` только для этого внутреннего вызова (ни фактический
размер битмапы, ни то, что репортит `measure()`, не меняется); регрессия
закрыта `t06_measuredHeightIsAlwaysSufficientToRasterAtLeastOneVisibleLine`
(`Tests/TrellisRenderTests/Display/CoreTextRasterizeTests.swift`, сканирует
6…60pt). D56 дополнена уточнением.

Полный пакет: **599/599** (macOS, `swift test`, было 597 после T11, +2
теста выше).

## 3. Дефект #48 — открыт, обойдён в сценах, не исправлен в коде

При сборе iOS/tvOS-скриншотов (см. §4) обнаружилось: короткий `TextNode` без
собственной явной ширины, центрированный (не растянутый) внутри
`column`-родителя, на iOS Simulator визуально обрезался с многоточием
(«Card 1» → «Car…»), хотя macOS с тем же деревом и кодом рисовал его
полностью. Не ошибка конкретной сцены — минимальный пробник через настоящий
`NodeHostBridge`/`TrellisUIKit` (три узла, без Playground) воспроизвёл то же
самое. Диагностика (полностью в defects.md #48): изолированный
`CoreTextRenderer.measure()`/`rasterize()` тем же числом (natural width
38.4541pt) не обрезает текст ни на одной платформе — расхождение возникает
только внутри полного pipeline на iOS-хосте, между тем, что вернул `measure`,
и шириной, реально дошедшей до `CTFramesetterCreateFrame` через
`LayerRenderer`/`NodeHostBridge` (итоговый `calculatedFrame.width` совпадает
с `floor(natural × 3) / 3` — округление вниз до пиксельной сетки 3× экрана).
Знак-впритык natural width делает потерю на округлении (~0.12pt) достаточной,
чтобы раздел последнего символа перестал влезать.

Не диагностировано до точного места (какая функция округляет вниз, а не до
ближайшего/вверх) — заметно больше по объёму, чем позволяет карточка «Сцены,
эталоны, матрица, документация». Оставлено **открытым** в defects.md #48, по
прецеденту #45 (T11). T12 обошла проблему в самих сценах: `S24`'s метки
выравнивания уже имели явную ширину (не задеты); `S26`'s подписи получили
явную, достаточную для одной строки ширину (`captionWidth`, 90pt для двух
коротких подписей в ряду, 240pt для двух самостоятельных) — эталонные
скриншоты корректны на всех трёх платформах (см. §4), но сам дефект в
Trellis-коде не исправлен.

## 4. Свидетельства по платформам

### 4.1. Reference PNG — macOS

`Scripts/check_screenshots.py --update --review-note docs/validation/t12-scenes-references-docs.md`
добавил 3 новые пары (`S24_Typography`/`S25_TextList`/`S26_LabeledSemantics`,
каждая + `_overlay`) в `docs/validation/screenshots/macOS/` — существующие 23
эталона (S01–S23) остались побайтово нетронуты (`check_screenshots.py`
сравнивает каждый файл, а не только считает их количество). Все три новые
сцены визуально корректны: смешанные run'ы, все три выравнивания, RTL,
`maxLines`-обрезание, пустая строка — на S24; 200 строк с живыми правками
внутри clipped viewport — на S25; все четыре подписи полностью читаемы под
своими карточками — на S26.

### 4.2. Simulator-скриншоты — iOS/tvOS

Нет существующего автоматизированного скрипта для Simulator-скриншотов вне
macOS reference pipeline (это признано в самом плане — «Simulator-скриншоты»
это доказательство, не байт-точный гейт). Собраны вручную тем же
инструментом, что и A11 evidence (`Scenario.initialIndex`'s `--scene <name>`
CLI-флаг), сохранены в `docs/validation/screenshots/iOS/` и
`docs/validation/screenshots/tvOS/` (не под общим `check_screenshots.py`
гейтом — это свидетельство, не эталон):

```
xcodebuild -project Playground/Playground.xcodeproj -scheme Playground-iOS \
  -destination "platform=iOS Simulator,id=<udid>" build
xcrun simctl install <udid> <path-to-.app>
xcrun simctl launch <udid> org.trellis.playground.ios --scene S24_Typography
xcrun simctl io <udid> screenshot docs/validation/screenshots/iOS/S24_Typography.png
```

(идентично для `Playground-tvOS`/`org.trellis.playground.tvos`, устройство —
Apple TV 4K Simulator). Обе платформы — iPhone 17 Pro Simulator (iOS 26.5, 3×)
и Apple TV 4K Simulator (tvOS 26.5) — визуально совпадают с macOS-эталонами
по содержимому (с поправкой на letterboxing Playground-чрома и focus-кольцо
tvOS на фокусируемом элементе S26, оба ожидаемы и не относятся к тексту).
Обнаружение и обход дефекта #48 (§3) — прямой результат этого сбора
свидетельств: без реального iOS Simulator-рендера обрезание текста осталось
бы незамеченным (macOS-эталон его не показывает).

### 4.3. `check_all.py --matrix`

См. §6 — прогнан после всех правок выше, зелёный на всех проверках.

### 4.4. API baseline

См. §5.

## 5. API baseline

Аддитивное изменение: `displayArtifact(for id: NodeID) -> DisplayArtifact?`
на `TrellisAppKit.TrellisHostView` и `TrellisUIKit.TrellisHostView` (§1) —
ничего не удалено, ничего не изменено у существующих символов.
`python3 Scripts/check_api.py --tvos --update --review-note
docs/validation/t12-scenes-references-docs.md` — по прецеденту T10 (тоже
чисто аддитивное изменение), ADR не требовался (`check_api.py`'s собственное
правило: ADR обязателен только когда есть `removed`/`changed`, здесь только
`added`).

## 6. `check_all.py --matrix`

Полный прогон (policy, test_policy, test_verifier,
`verify_bootstrap.py --matrix`, `check_api.py --tvos`,
`check_screenshots.py`, `check_log_env.py`) — зелёный. Consumer smoke
(`verify_bootstrap.py`) обновлён новым блоком, использующим `TextNode`
напрямую (`AttributedString`, `.trellisText.weight = .bold`,
`TextStyle`) без `@testable import` — приёмочное требование T12 «consumer
использует `TextNode` без `@testable`» выполнено явно, не только по факту
существующего импорта библиотеки.

## 7. Итоговая таблица — T01–T12 (N01)

| Область | Статус | Где |
|---|---|---|
| Text-контракт, `TextDocument`/`TrellisTextAttributes` (T01) | полностью | [t01-text-contract.md](t01-text-contract.md) |
| Растровый прототип, `DisplayArtifact` (T02) | полностью | [t02-raster-prototype.md](t02-raster-prototype.md) |
| `ContentMeasurer` в солвере (T03) | полностью | [t03-content-measurement.md](t03-content-measurement.md) |
| `TextNode` (T04) | полностью | [t04-text-node.md](t04-text-node.md) |
| CoreText измерение (T05) | полностью | [t05-coretext-measurement.md](t05-coretext-measurement.md) |
| Display pipeline / raster (T06) | полностью | [t06-display-pipeline.md](t06-display-pipeline.md) |
| Внутренний raster layer (T07) | полностью | [t07-text-raster-layer.md](t07-text-raster-layer.md) |
| Accessibility текста (T08) | полностью | [t08-text-accessibility.md](t08-text-accessibility.md) |
| Environment в хостах (T09) | полностью | [t09-host-text-environment.md](t09-host-text-environment.md) |
| Lifecycle и отмена (T10) | полностью | [t10-lifecycle-and-cancellation.md](t10-lifecycle-and-cancellation.md) |
| Нагрузка (T11) | полностью в узком смысле; общая MainActor-side глубина дерева — открытый дефект #45 (не специфичен для текста) | [t11-text-load.md](t11-text-load.md) |
| Сцены/эталоны/матрица/документация (T12) | полностью на macOS/iOS/tvOS; открыт дефект #48 (округление ширины на реальном хосте для знак-впритык auto-width текста — обойдён в сценах явной шириной, не исправлен в коде) | этот файл |

Матрица зелёная на трёх платформах (§6); consumer использует `TextNode` без
`@testable` (§6); оба новых дефекта (#46, #47) заведены в реестр до
исправления и закрыты тестами; дефект #48 заведён в реестр, оставлен
открытым по прецеденту #45, не блокирует приёмку — обойдён в сценах, не
скрыт. **N01 считается закрытым.**

## 8. README/AGENTS

`README.md`/`AGENTS.md` дополнены разделом про CoreText в `TrellisRender`
(измерение/раскладка через `CTFramesetterSuggestFrameSizeWithConstraints`,
рисование через `CTFramesetterCreateFrame`/`CTFrameDraw`, единая
`makeAttributedString` для обоих путей) и про environment-ключи, которые
сцены/хосты используют для текста: `TextRendererKey`, `LocaleKey`, `ThemeKey`.
