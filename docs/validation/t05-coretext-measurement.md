# T05 — CoreText-измерение (`TrellisRender`)

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует D50/D51 ([decisions.md](../decisions.md)), зависит от T03
([t03-content-measurement.md](t03-content-measurement.md)) и T04
([t04-text-node.md](t04-text-node.md)). Растеризация — не эта карточка (T06);
`TextRenderer` остаётся measure-only.

## 1. Что добавлено

`Sources/TrellisRender/Text/`:

- `CoreTextRenderer.swift` — публичный `CoreTextRenderer: TextRenderer`, единственный
  реальный (не fallback) конформер протокола; `measure` целиком делегирует
  `CoreTextTypesetter`.
- `CoreTextTypesetter.swift` — module-internal `enum` с самим измерением:
  построение `NSAttributedString` из `TextLayoutInput.document`'s runs и base
  `TextStyle` (шрифт/размер/вес по run, para­graph-стиль по документу),
  `CTFramesetter`/`CTFrame`/`CTLine` для переноса строк, `maxLines`/высота как
  два независимых ограничителя (D56), baseline и высота из реальных
  typographic bounds. Не публичный тип — переиспользуется T06 из того же модуля
  без расширения публичного API.

## 2. Как устроено измерение

1. Пустая строка — особый путь: без `CTFramesetter`, высота/baseline берутся
   из `CTFontGetAscent/Descent/Leading` резолвленного шрифта (или
   `TextStyle.lineHeight`, если задан) — не guess-константа, реальные метрики
   шрифта даже без единого глифа (D56).
2. Непустой текст: `NSMutableAttributedString` строится из
   `document.plainCharacters`, затем каждый run документа (через
   `AttributedString.runs`) кладёт `kCTFontAttributeName`, резолвленный из
   run-level `trellisText.fontName`/`.pointSize`/`.weight`, наследуя
   отсутствующие поля от базового `TextStyle` — смешанные шрифты/размеры в
   одном документе реально влияют на `CTFramesetter`, не только на
   `PortableTextMeasurer`'s символьную модель. `color` не участвует в
   измерении (D55 — цвет только для растра).
3. `kCTParagraphStyleAttributeName` несёт alignment (физический edge по
   `LayoutDirection`), `lineBreakMode = .byWordWrapping`,
   `baseWritingDirection`, и — если `TextStyle.lineHeight > 0` —
   `minimumLineHeight`/`maximumLineHeight`, forcing CoreText's own line
   spacing вместо постфактум-умножения; `kCTLanguageAttributeName` несёт
   `localeIdentifier` (закрывает половину #39).
4. Ширина под `CTFramesetterCreateFrame`: `.exact`/`.atMost` дают constraint
   как ширину пути, `.unspecified` — большую конечную ширину
   (`1_000_000pt`, не `.greatestFiniteMagnitude` — устойчивее для `CGPath`).
   Кадр строится с неограниченной высотой, чтобы получить **все** естественные
   строки одним проходом (`CTFrameGetLines`), а не оценивать число строк по
   высоте (закрывает #36).
5. Для каждой строки — `CTLineGetTypographicBounds` (ascent/descent/leading/
   width) один раз; высота строки = `TextStyle.lineHeight` (если задан) или
   `ascent+descent+leading` реальной строки (не разбитый на строки-неизвестного-
   размера constant).
6. `maxLines` и высота (`constraint.height.knownValue`) — два независимых
   ограничителя видимого числа строк (D56): каждый может уменьшить
   `visibleLineCount` и выставить `didTruncate`, независимо от другого.
7. `firstBaseline` = ascent первой строки напрямую (не через геометрию origin
   всего кадра) — тот же аскент, который T02's прототип показал совпадающим
   с `firstBaselineFromTop` в пределах typographic padding (closes #38).
8. `truncation` (`clip`/`tail`) **не влияет на измеренный размер** — оба стиля
   обрезают видимое число строк одинаково; разница — только в том, что T06
   нарисует на последней строке (ellipsis vs явный обрез). Явно
   задокументировано и покрыто тестом, чтобы будущая рассинхронизация
   measure/raster (класс дефекта #37) была видна сразу.

## 3. Вес шрифта и `CTFontDescriptor`

`TextWeight` не сопоставляется с конкретными именами шрифтов — вместо этого
`kCTFontWeightTrait` на копии дескриптора (стандартный CoreText-идиом
best-match по трейтам), со значениями, совпадающими с задокументированными
`UIFont.Weight`/`NSFont.Weight` raw values (`ultraLight: -0.8` … `black:
0.62`). `fontName == "system"` резолвится через
`CTFontCreateUIFontForLanguage(.system, size, locale)` (не `"Helvetica"` —
class дефекта W02), с фоллбэком на `Helvetica`, только если платформа не
вернула системный шрифт (тот же паттерн, что уже был проверен в T02's
прототипе).

## 4. Устойчивость указателей `CTParagraphStyleSetting`

Первая версия `makeParagraphStyle` передавала `&localVar` прямо в
`CTParagraphStyleSetting.init(value:)` — компилятор (Swift 6.3.3) явно
предупредил, что такой указатель валиден только на время самого вызова
инициализатора, а не до `CTParagraphStyleCreate`, вызываемого позже с уже
собранным массивом. Исправлено вспомогательным `ParagraphSettingStorage` —
классом, который выделяет `UnsafeMutablePointer<T>` под каждое значение и
освобождает их в `deinit`, после того как `CTParagraphStyleCreate` уже скопировал
значения. Без этого исправления код собирался бы (это предупреждение, не
ошибка), но был бы undefined behavior — записано как находка процесса, не как
дефект в `defects.md`, потому что баг не попал в закоммиченный код ни разу.

## 5. Тесты и результаты

12 новых тестов в `Tests/TrellisRenderTests/Text/CoreTextRendererTests.swift`,
зелёные вместе со всем пакетом на всех трёх платформах:

| Платформа | TrellisCoreTests | TrellisRenderTests |
|---|---|---|
| macOS (`swift test`) | — | — (538 тестов пакета целиком) |
| iOS 26.5 Simulator | 407/407 | 128/128 |
| tvOS 26.5 Simulator | 407/407 | 128/128 |

- `t05_emptyStringIsOneLineAtNaturalLineHeight` — реальные метрики шрифта, не
  guess.
- `t05_narrowerWidthWrapsIntoMoreRealLines` — реальный `CTLine`-перенос:
  разная ширина даёт разное число строк из одного и того же прохода
  framesetter (#36).
- `t05_firstBaselineIsRealAscentNotAConstant` — демонстрирует расхождение с
  `lineHeight * 0.8` (#38).
- `t05_exactWidthReportsConstraintNotNaturalWidth` — `.exact` даёт constraint,
  `.atMost` — `min(natural, max)`, а не одинаково (#39, первая половина).
- `t05_localeIsNotSilentlyDropped` — non-English locale не падает и не
  no-op'ится по мёртвому коду (#39, вторая половина).
- `t05_maxLinesAndHeightAreIndependentLimiters` — оба ограничителя реально
  независимы (D56).
- `t05_clipAndTailTruncationReportTheSameMeasuredBox` — truncation-стиль не
  меняет размер/lineCount, только `didTruncate` у обоих `true`.
- `t05_rightToLeftDirectionMeasuresWithoutFailing` — RTL не падает, ширина
  укладывается в constraint.
- `t05_runLevelOverrideWidensBeyondBaseStyleAlone` — run-level `pointSize`
  реально доходит до `CTFramesetter`, а не только до `PortableTextMeasurer`'s
  модели символов.
- `t05_cancelledContextThrowsBeforeMeasuring` — контракт `TextRenderer`
  соблюдён и здесь.
- `t05_measurementIsDeterministicAcrossOneHundredRepeats` — 100 повторов той
  же `TextLayoutInput`/constraint дают побитово равный `TextMetrics`
  (`Hashable`-равенство).
- `t05_measurementIsSafeFromAWorkerThread` — измерение с `Task.detached`
  (worker-поток solver'а) даёт тот же результат, что и синхронный вызов;
  `CoreTextRenderer`/`CTFont`/`CTFrame`/`CTLine` создаются и используются
  синхронно внутри одного вызова, ничего не перетекает между потоками.

## 6. Дефекты

Закрыты #36, #38, #39 (см. [defects.md](../defects.md)) — все три были о
стороне измерения. #37 закрыт частично: `didTruncate`/lineCount больше не
зависят от строковой арифметики Weave (тест
`t05_clipAndTailTruncationReportTheSameMeasuredBox`), но собственно отрисовка
ellipsis по ширине (`CTLineCreateTruncatedLine`) остаётся за T06, у которого
уже будет `DisplayArtifact` для результата растра — запись обновлена, не
закрыта, чтобы не потерять оставшуюся часть.

## 7. API baseline

`check_api.py --tvos` показал только `added` для `TrellisRender`
(`CoreTextRenderer`, его `init()`/`measure(_:constraint:context:)`) —
`CoreTextTypesetter` не публичный, в baseline не попадает. `changed`/`removed`
пусты, ADR не потребовался. Обновлено командой `check_api.py --tvos --update
--review-note docs/validation/t05-coretext-measurement.md`.

## Приёмка T05

- `CoreTextRenderer.measure`: `CTFramesetter`, строки/baseline из `CTLine`,
  `.exact`/`.atMost`, `maxLines`, truncation, RTL, locale, системный шрифт,
  пустая строка, смешанные runs, единая логика line breaks для measure (и,
  через тот же internal `CoreTextTypesetter`, для будущего raster T06) — done,
  §2-3 выше и тесты §5.
- Детерминизм и thread-safety: измерение с worker-потока, 100 повторов → равные
  метрики; отмена — done (`t05_measurementIsDeterministicAcrossOneHundredRepeats`,
  `t05_measurementIsSafeFromAWorkerThread`, `t05_cancelledContextThrowsBeforeMeasuring`).
- Дефекты #36–#39 закрыты при переносе (см. §6 — #37 частично, остаток на T06).

Следующая карточка — T06 (Display pipeline: `DisplayScheduler`/
`DisplayTransaction`/`DisplayArtifact`, D53/D54).
