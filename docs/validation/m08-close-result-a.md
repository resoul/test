# M08 — Закрыть результат A: анимация свойств

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md) §5,
последняя карточка результата A (M01–M08). Зависит от M07
([m07-scene-readiness.md](m07-scene-readiness.md)) и T12 (плана 4,
[t12-scenes-references-docs.md](t12-scenes-references-docs.md)).

## 1. Сцены S27/S28

Две новые Playground-сцены (`Playground/Shared/Scenarios/`), первые в этом плане, что реально
используют `Node.animate`:

- **S27_Disclosure** — план §1's собственный worked example буквально: список из 3
  `DisclosureCardNode` (текст + подпись «Tap to expand/collapse»), каждая — `ControlNode` с
  `description.maxLines: 2` по умолчанию. Нажатие вызывает `list.animate(.smooth) {
  description.maxLines = expanded ? nil : 2 }` — **на `list` (общем родителе), не на самой
  карточке**: раскрытие одной карточки должно сдвинуть карточки ниже в том же переходе (D62),
  а `card.animate` покрыл бы только содержимое нажатой карточки, оставив соседей снапаться —
  ровно та граница, которую D63's таблица области делает явной. `pressCount`/текст подсказки —
  статические сигналы «что произошло» (приём S21's `TapCardNode`), сам переход — нативная
  evidence, не то, что один скриншот может показать.
- **S28_AnimationScopesAndReduceMotion** — три панели статических сигналов того, что
  автоматические тесты M01–M07 уже доказали:
  - **Retarget (D66)** — `RetargetBarNode`: полоса меняет ширину под 900 мс переходом на каждое
    нажатие; счётчик `presses` — единственное, что скриншот может подтвердить про повторное
    нажатие до завершения перехода.
  - **Scopes (D62/D63)** — `ScopeDemoNode`: две карточки в одном ряду, две кнопки — «Animate
    row» оборачивает обе карточки в один `row.animate`, «Animate A only» — только первую;
    показывает границу области как два разных вызывающих, а не один переключатель.
  - **Reduce Motion (D67)** — `ReduceMotionPanelNode`: `Node.setReduceMotion(_:)` — **на
    поддереве**, не bridge-wide настройка; переключатель управляет только своей демо-карточкой.

`waitForRenderReady` (`Playground/Shared/Scenario.swift`, T12) получил третье условие —
`host.sceneReadiness?.displayReady` — рядом с уже существующим `animationReady` (оба из M07):
без первого сцена с многопроходным layout-решением (или, как здесь, сцена с реальным
scope-переходом) могла посчитаться «готовой», пока для узла ещё существует старый,
промежуточной-ширины растр, а новый (финальной ширины) ещё активен/в очереди — раньше
`waitForRenderReady` проверял только «артефакт существует», не «больше никакой растровой
работы не осталось» (см. §2 — это и обнаружило дефект #50). Это — тот самый «шов», который
T12's собственный комментарий ещё в плане 4 заранее пометил как место продолжения M07.

## 2. Найден и исправлен дефект #50 — `CoreTextTypesetter.rasterize`, `maxLines > 1`

Построение S27 с реальным macOS-окном показало: `maxLines: 2` абзац на широком (700pt) окне
рендерился **одной** строкой с многоточием вместо двух, хотя `measure()` для того же
текста/ширины корректно возвращал высоту для двух строк. Изолированный пробник (реальный
`CoreTextRenderer`/`NodeHostBridge`, без Playground) воспроизвёл то же самое на 660pt коробке.

Причина — тот же класс проблемы, что и дефект #47 (T12), но не тот же случай: `CTFrameGetLines`
на коробке ровно в высоту `measure()`'s ответа (плюс #47's 1pt margin) иногда решает, что влезает
**меньше** строк, чем эта высота на самом деле вмещает — единственного фиксированного margin,
достаточного для любого числа строк, не существует (#47's 1pt закрывал только однострочный
случай).

**Исправление** (не патч margin ещё раз, а другой источник числа строк): `rasterize()` больше
не спрашивает `CTFrameGetLines` тесной коробки, сколько строк «влезло». `probeFrame` (unbounded
height — как уже безопасно делает `measure()`) даёт полный список строк и их typographic
bounds; видимое число строк считается явно в Swift (`maxLines`, затем cumulative-height лимитер
с допуском 0.5pt на шум между независимо построенными `CTFrame` для одного и того же текста).
Отдельная щедро-высокая `fittingFrame` даёт только числено пригодные origins для рисования,
сдвинутые обратно в маленькую координатную систему битмапы (`fittingHeight -
request.size.height`) — обе рамки используют одну и ту же ширину, поэтому перенос строк
идентичен между ними. Первая попытка чинить это (просто увеличить только видимое число строк,
оставив `CTFrameGetLineOrigins` на тесной рамке) дала полностью **пустое** изображение — origins
из рамки другой высоты не переносятся на маленький холст без явного сдвига; вторая попытка (без
допуска 0.5pt) снова резала до одной строки из-за float-шума между `probeFrame`'s и
исходной рамки независимо посчитанными `ascent`/`descent`/`leading` для одного и того же текста
— обе промежуточные версии не закоммичены, описаны здесь как часть диагностики.

Регрессия — прямой пробник этой карточки (не отдельный `swift test`, воспроизведён скриптом,
не сохранён в дереве): существующие `CoreTextRasterizeTests.swift`'s #47-регрессии
(`t06_measuredHeightIsAlwaysSufficientToRasterAtLeastOneVisibleLine`, сканирует 6…60pt) остаются
зелёными без изменений — фикс не трогает однострочный путь. Полный пакет: **658/658**
(без изменений — карточка не добавляла новых `swift test`).

D56 дополнена уточнением ([decisions.md](../decisions.md)); дефект #50 заведён и закрыт в
[defects.md](../defects.md).

## 3. Найден, не исправлен — дефект #51 (открыт)

При сборе iOS-скриншотов S28: явный `TextNode.style.width` (проверено 150/170/195/200/300pt)
не увеличивал видимую ширину строки «Animate row (both)» — обрезалась в одном и том же месте
независимо от заданного значения; соседняя кнопка с более коротким текстом в идентичной
структуре узла отображалась полностью. Не диагностировано до точной причины за время, которое
позволяет карточка «закрыть результат A» — заведено в defects.md #51, обойдено в сцене
сокращением текста кнопки («Animate row (both)» → «Animate row»), по прецеденту дефекта #48.

## 4. Bench — 1000 layers + text под реальной анимацией

Новая fixture `animated-text-list-1000` (`Bench/Sources/TrellisBench/main.swift`): 1000
карточек (цветной фон + `TextNode`, «1000 слоёв + текст», не 1000 голых текстовых узлов, как
`text-list-1000`), затем реальный `root.animate(.smooth) { for card in cards {
card.appearance.background = ... } }` — S27/S28's форма списка в масштабе бенча вместо 3 карточек.
`idle-after-animation-settles` опрашивает `NodeHostBridge.sceneReadiness` (M07, D69), а не
фиксированную задержку.

```text
python3 Scripts/bench.py --iterations 20 --label m08-close-result-a --write-summary
```

| Метрика | p50 | p95 | Сравнение с бюджетом |
|---|---|---|---|
| `attach-to-first-commit` | 107.8 ms | 107.8 ms | сопоставимо с `text-list-1000` (109.8 ms) — доп. 1000 фоновых слоёв не удваивают commit |
| `drain-all-artifacts` | 46.0 ms | 46.0 ms | сопоставимо с `text-list-1000` (47.0 ms) |
| `animated-commit-full-list` | 166.2 ms | 167.4 ms | новая метрика — 1000 `backgroundColor` explicit-анимаций в одном commit; не бюджетировалась M02/T11 (текст без анимации), см. ниже |
| `idle-after-animation-settles` | 0.46 ms | 0.48 ms | почти мгновенно — см. интерпретацию ниже |

Счётчики: `display-scheduled`/`display-completed` = 1000 (raster только для исходного текста —
анимация красит фон, ни одного нового raster job она не создаёт, D61's таблица не включает
raster в цену paint-only перехода); `layout-committed` = 1 (только начальная раскладка,
все последующие — paint-only, `layout-coalesced` растёт по числу вызовов `.animate`);
`scene-ready-after-last-animation` = **1** — `sceneReadiness.isReady` стало `true` до конца
прогона.

**Интерпретация `idle-after-animation-settles`.** Значение вводит в заблуждение при поверхностном
чтении: 0.46 ms — это не «переход settled почти мгновенно после commit», а следствие того, что
сам `animated-commit-full-list` (166 ms — синхронная работа MainActor на 1000 узлов) уже
занимает дольше, чем `.smooth`'s 250 ms длительность, и `pump()`, ожидающий commit, прокачивает
RunLoop достаточно долго, чтобы реальная CA-анимация **предыдущей** итерации успела показать
`completeIfCurrent` до того, как эта fixture доходит до собственного опроса готовности. Что
здесь реально ново и важно: `scene-ready-after-last-animation = 1` в **обычном standalone-
процессе** (Bench — не XCTest) — это первое прямое, не-Playground свидетельство, что настоящий
`CATransaction` completion callback (`LayerAnimator.completeIfCurrent`) действительно
доставляется вне XCTest-хостинга, ровно то, что m02-animation-prototype.md §1.4 сузило до
«Playground/manual evidence, не автотест» и что M07 унаследовало как открытый пункт. Он
по-прежнему не закрыт как **автотест** (Bench — не `swift test`), но закрыт как **evidence** —
доказательство, что контракт `.animate` реально работает end-to-end в реальном хосте, не только
внутри `LayerAnimator`'s собственного адресуемого cleanup, который единственный проверяли
M02–M07's тесты напрямую.

Полный отчёт: [measurements/2026-09-13-m08-close-result-a-release.md](measurements/2026-09-13-m08-close-result-a-release.md),
[measurements/2026-09-13-m08-close-result-a-release.json](measurements/2026-09-13-m08-close-result-a-release.json).
`cancel-latency` крашится в **debug**-сборке (`swift run` напрямую) на глубине по умолчанию
1500 — тот же, уже задокументированный класс проблемы, что дефект #45 (стек MainActor); в
**release**-сборке (`Scripts/bench.py`, официальный способ запуска) не крашится — не новый
дефект, замечено при полном прогоне всех fixtures для этого отчёта.

## 5. Свидетельства по платформам

### 5.1. Reference PNG — macOS

`Scripts/check_screenshots.py --update --review-note docs/validation/m08-close-result-a.md`
добавил 4 новые пары (S27/S28 × normal/overlay) — 56 эталонов всего; существующие 52 (S01–S26)
остались побайтово нетронуты **кроме** S24/S25/S26 (нормальные и overlay — 6 файлов), чьи байты
изменились при пересборке после исправления дефекта #50, хотя декодированные пиксели полностью
идентичны (`PIL.ImageChops.difference(...).getbbox() is None` на все 6 пар, проверено до
принятия) — PNG-кодирование не детерминировано побайтово между запусками `NSBitmapImageRep`
(что именно варьируется — не диагностировано, не блокирует: контракт `check_screenshots.py`
сравнивает контент, только байтовое сравнение — суррогат для «нечего вручную сверять»),
непричастно к дефекту #50 (S24/S25/S26 не используют `maxLines > 1`, для чего он актуален).

### 5.2. Simulator-скриншоты — iOS/tvOS

Собраны как в T12 (`--scene <name>` + `xcrun simctl io screenshot`), плюс **настоящая
интерактивность** через `mcp__Claude_Code_iOS_Simulator__control` (`tap`), не только статичные
кадры:

- `docs/validation/screenshots/iOS/S27_Disclosure.png` — исходное (collapsed) состояние.
- `docs/validation/screenshots/iOS/S27_Disclosure_expanded.png` — после реального нажатия на
  Card 2: описание выросло до полного 5-строчного текста, подсказка сменилась на «Tap to
  collapse», **Card 3 сдвинулась вниз** — прямое визуальное доказательство, что
  `list.animate` двигает и соседей, не только нажатую карточку (D62).
- `docs/validation/screenshots/iOS/S28_AnimationScopesAndReduceMotion.png` — после нажатий:
  `presses: 1` на retarget-полосе (расширена), «Reduce Motion: On» и её демо-карточка лит
  (оранжевая) — оба реальных перехода через настоящий `ControlNode.activation`.
- `docs/validation/screenshots/tvOS/S27_Disclosure.png`,
  `docs/validation/screenshots/tvOS/S28_AnimationScopesAndReduceMotion.png` — исходное
  состояние на Apple TV 4K Simulator; на широком TV-экране абзацы S27 умещаются в одну строку
  каждый (не задевает дефект #50 — тот воспроизводится на **более узких** боксах).

Обе платформы (iPhone 17 Pro Simulator iOS 26.5/3×, Apple TV 4K Simulator tvOS 26.5) —
не CI gate, evidence, по прецеденту T12/A11.

### 5.3. `check_all.py --matrix`

См. §7.

### 5.4. API baseline

Аддитивно: `TrellisRender.NodeHostBridge.SceneReadiness`/`.SceneReadinessError`/
`.sceneReadiness`/`.waitUntilSceneReady(timeout:)` — уже закрыто M07's собственным review note;
эта карточка добавляет тонкие passthrough-обёртки того же API на `TrellisAppKit.TrellisHostView`
и `TrellisUIKit.TrellisHostView` (`sceneReadiness`, `waitUntilSceneReady(timeout:)`) — тот же
приём, что T12 уже применила для `displayArtifact(for:)`. `check_api.py --tvos --update
--review-note docs/validation/m08-close-result-a.md` — `TrellisAppKit`/`TrellisUIKit` baseline
обновлены, `TrellisCore`/`TrellisRender` без изменений в этой карточке.

## 6. README

Новый раздел «Анимация (`Node.animate`)» рядом с существующим «Текст (`TextNode`)» — та же
глубина: точка входа, пример из плана, пять пунктов контракта (область/смешение, retarget,
текст-не-растягивается, Reduce Motion, готовность экспорта) со ссылками на decisions.md и этот
отчёт.

## 7. `check_all.py --matrix`

```text
python3 Scripts/check_all.py --matrix
```

policy/test_policy/test_verifier, `verify_bootstrap.py --matrix` (macOS arm64/x86_64 + iOS/tvOS
device destinations build-only), `check_api.py --tvos`, `check_screenshots.py` (56 сцен),
`check_log_env.py` — все PASS. Реальный `xcodebuild test` на iPhone 17 Pro Simulator и Apple TV
4K Simulator (не только build) — см. итог ниже.

## 8. Итоговая таблица — M01–M08 (результат A)

| Карточка | Статус | Где |
|---|---|---|
| Контракт на примерах, D61–D69 (M01) | полностью | [m01-animation-contract.md](m01-animation-contract.md) |
| Нативный прототип до инфраструктуры (M02) | полностью; открытый пункт — CA completion callback не доставляется в XCTest-хостинге, сужение контракта, не блокирует | [m02-animation-prototype.md](m02-animation-prototype.md) |
| Scope intent в pending и commit (M03) | полностью | [m03-animation-intents.md](m03-animation-intents.md) |
| Малый explicit animator внутри renderer (M04) | полностью; дефект #49 найден и исправлен pre-commit | [m04-layer-animator.md](m04-layer-animator.md) |
| Reduce Motion и lifecycle (M05) | полностью | [m05-reduce-motion-lifecycle.md](m05-reduce-motion-lifecycle.md) |
| Реальная карточка с текстом, D65×M04 (M06) | полностью, без изменений в `Sources/` | [m06-text-card-animation.md](m06-text-card-animation.md) |
| Взаимодействие и детерминированная готовность, D68/D69 (M07) | полностью; открытый пункт унаследован от M02 | [m07-scene-readiness.md](m07-scene-readiness.md) |
| Закрыть результат A: S27/S28, bench, матрица, README (M08) | полностью на macOS/iOS/tvOS Simulator; дефект #50 найден и исправлен, дефект #51 найден, открыт, обойдён в сцене | этот файл |

Матрица зелёная на трёх платформах (§7); README и итоговая таблица на месте (§6, эта таблица);
оба новых дефекта этой карточки заведены в реестр (##50 закрыт, #51 открыт, обойдён, не скрыт).
Открытые пункты, унаследованные от M02/M07 (CA completion delivery в XCTest) и от T12/#48-класса
(явная ширина текста в некоторых flex-контекстах) не блокируют — тот же прецедент, что уже
принят для #45/#48. **Результат A (M01–M08) считается закрытым.**

Результат B (M10–M14, составной переход) остаётся обязательным — N07 не закрывается ни этим
срезом, ни результатом B. M09 (`.spring`) — необязательное продолжение после M08, не входит в
приёмку результата A.
