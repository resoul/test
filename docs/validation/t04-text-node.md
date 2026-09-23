# T04 — `TextNode` в `TrellisCore`

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует D55/D56/D52/D51 ([decisions.md](../decisions.md)), зависит от T03
([t03-content-measurement.md](t03-content-measurement.md)). CoreText-реализация —
не эта карточка (T05); здесь `TextRenderer` — протокол и `PortableTextMeasurer`,
детерминированный fallback (D51, дефект #40).

## 1. Что добавлено

`Sources/TrellisCore/Text/`:

- `TextStyle.swift` — `TextWeight`, `TextAlignment`, `TextTruncation`, `TextStyle`
  (`fontName`/`pointSize`/`weight`/`lineHeight`/`alignment`/`color`).
- `TextDocument.swift` — `TrellisTextAttributes: AttributeScope` (font/size/weight/color
  run-ключи), `TextDocument = AttributedString`, `plainCharacters`.
- `TextLayoutInput.swift` — `TextLayoutInput`, `TextMetrics`.
- `TextRenderer.swift` — `TextRenderer` протокол, `TextRendererKey`/`LocaleKey`
  environment-ключи, `EnvironmentValues.textRenderer`/`localeIdentifier`.
- `PortableTextMeasurer.swift` — детерминированный fallback `TextRenderer`.
- `TextNode.swift` — `TextNode: Node` и приватный `TextContentMeasurer: ContentMeasurer`.

`Sources/TrellisCore/Node.swift`: `markGeometryDirty(structural:)` — `private` → module-
internal (тот же метод, TextNode вызывает его из другого файла). Новый `markDisplayDirty()`
(четвёртый канал инвалидации, без собственного revision — ADR 0014, T04).

`Sources/TrellisCore/Invalidation.swift`: `DirtyReasons.display` (`1 << 5`).

`Sources/TrellisRender/RenderCoordinator.swift`: `.display` добавлен в оба «non-layout»
subset-чека (`attachInvalidation`'s cancel-guard и `publishFromLastCommit`'s fast path) —
без этого цветовое изменение проходило бы **мимо** fast path и брало полный
`makeLayoutInputSnapshot`, прямо противоречя приёмке «смена цвета → ноль layout
snapshot». Новый `onDisplayOnly` hook (симметричный `onPaintOnly`/`onSemanticsOnly`) —
пока ничем не заполняется (`NodeHostBridge` его не подключает): реальная реакция на
`.display` — `DisplayScheduler`, T06; T04 отвечает только за то, чтобы `.display`-only
изменение не запрашивало снимок/солв.

## 2. Три уточнения относительно наброска T01

Набросок T01 (`t01-text-contract.md`) не был кодом («Кода здесь нет»); при реализации
обнаружились три места, которые было невозможно оставить как есть:

1. **`TextRenderer.measure` не имел параметра `constraint`.** Без него измеритель не мог
   бы вообще знать, при какой ширине его вызывает solver (весь смысл D49) — очевидный
   пробел наброска. Сигнатура: `measure(_ input: TextLayoutInput, constraint:
   SizeConstraint, context: LayoutContext) throws -> TextMetrics`.
2. **`scale` убран из `TextLayoutInput`.** Перенос строк и репортируемые размеры — в
   points, не зависят от плотности пикселей; `scale` нужен только `rasterize` (T05/T06),
   где он уже был отдельным параметром в наброске. Оставить `scale` в обоих местах —
   источник рассинхронизации, которого можно избежать сейчас.
3. **`TextRenderer` сужен до только `measure`.** Набросок D51 объединял measure+rasterize
   в одном протоколе, но `rasterize(...) -> DisplayArtifact` требует `DisplayArtifact`,
   которого не существует до T06. Стаббировать его сейчас — либо изобретать тип заранее
   (риск разойтись с реальным дизайном T06), либо оставлять недоделанным. `TextRenderer`
   расширяется новым требованием `rasterize` в T05/T06, когда тип уже есть; единственный
   реализатор до этого момента — `PortableTextMeasurer`, так что расширение протокола не
   ломает внешних потребителей.

Дополнительно: D51 предполагал, что «смонтированный хост без backend» получает громкую
ошибку конфигурации, а не тихий fallback. `TextNode` не может отличить этот случай от
искренне headless-контекста, читая только environment (оба видят `TextRendererKey ==
nil`) — различать их значило бы придумывать сигнал «хост подключён», которого T04 не
просили строить. Пока оба случая используют `PortableTextMeasurer`; T09 (хосты реально
выставляют `TextRendererKey` при `attach`) — естественная карточка для настоящего сигнала,
если он понадобится.

## 3. Модель измерения: identity/revision без ссылки на `Node`

`TextContentMeasurer` (private в `TextNode.swift`) — **значение**, не ссылка на ноду:

- `identity = ObjectIdentifier(self)` — берётся у `TextNode` в момент снимка, но
  сохраняется как значение `ObjectIdentifier`, не как ссылка; нода не удерживается.
- `revision = geometryRevision` — существующий счётчик `Node` (не новый), уже устойчив
  к paint-only изменениям по конструкции (`markDisplayDirty()` его не трогает).
- `document`/`textStyle`/`maxLines`/`truncation`/`direction`/`localeIdentifier`/
  `renderer` — копии значений на момент снимка.

Это удовлетворяет контракт D49 буквально: `identity` не создаётся заново на каждом
снимке (тот же `ObjectIdentifier`, пока жив тот же `TextNode`), а равные `(identity,
revision)` действительно гарантируют одинаковый результат `measure(_:context:)`, потому
что все входы, от которых зависит результат, либо неизменны (identity), либо часть
`revision`'а (geometryRevision меняется ровно когда меняется что-то из
document/textStyle-geometry/maxLines/truncation).

## 4. Тесты и результаты

27 новых тестов, зелёные на всех трёх платформах вместе со всем пакетом:

| Платформа | TrellisCoreTests | TrellisRenderTests |
|---|---|---|
| macOS (`swift test`) | — | — (526 тестов пакета целиком) |
| iOS 26.5 Simulator | 407/407 | 116/116 |
| tvOS 26.5 Simulator | 407/407 (после повтора — см. §5) | 116/116 |

- `Tests/TrellisCoreTests/Text/TextNodeTests.swift` (10) — no-op equality
  text/document/textStyle/maxLines/truncation; geometry- vs display-revision split;
  снимок не держит `Node` (`weak var` тест); identity стабилен между снимками; revision
  измерителя не двигается от paint-only изменения.
- `Tests/TrellisCoreTests/Text/PortableTextMeasurerTests.swift` (6) — D56 напрямую:
  пустая строка — одна строка на `lineHeight`; `.exact` даёт constraint, `.atMost` —
  `min(natural, max)`; `maxLines` и высота — независимые ограничители, оба дают
  `didTruncate`; ширина реально определяет перенос строк; отменённый контекст бросает
  до вычисления.
- `Tests/TrellisRenderTests/TextNodeInvalidationTests.swift` (4) — через
  `NodeHostBridge` (реальная интеграция, `PortableTextMeasurer` в деле, хост не
  устанавливал `TextRendererKey`): смена текста → один коммит, новая высота; тот же
  текст → `requested`/`layoutSnapshotCount`/`geometryRevision` не растут; смена только
  цвета → `layoutSnapshotCount` не растёт, `geometryRevision` не растёт,
  `displayRevision` растёт, `calculatedFrame` не меняется; `detach()` во время
  отложенного изменения текста — новый кадр не приходит (via `statistics.committed`
  сразу после detach).

## 5. Наблюдение: нестабильный `LayoutScheduler`-тест на tvOS (не связан с T04)

Один прогон полного `TrellisCoreTests` на tvOS Simulator провалил
`test_layoutScheduler_cancelAndDisposePreventLateResultCallbacks`; повторный прогон
сразу после — зелёный (407/407), как и macOS/iOS при той же подготовке. T04 не трогал
`LayoutScheduler` или что-либо смежное. Записано как [дефект #43](../defects.md) —
открыт, не диагностирован, не привязан к карточке; не блокирует приёмку T04.

## 6. API baseline

`check_api.py --tvos` показал только `added` для `TrellisCore` (весь текстовый API:
`TextNode`, `TextStyle`, `TextDocument`/`TrellisTextAttributes`, `TextLayoutInput`,
`TextMetrics`, `TextRenderer`/`TextRendererKey`/`LocaleKey`, `PortableTextMeasurer`,
`DirtyReasons.display`) и `TrellisRender` (`RenderCoordinator.onDisplayOnly`) — `changed`/
`removed` пусты, обновление не требовало ADR (`check_api.py`'s собственное правило:
ADR обязателен только при breaking-изменениях). Обновлено командой `check_api.py --tvos
--update --review-note docs/validation/t04-text-node.md`.

## Приёмка T04

- Изменение текста → один flush → новая геометрия — done
  (`t04_textChangeFlushesOnceAndProducesNewGeometry`).
- Тот же текст → ноль работ — done (`t04_sameTextIsZeroWork`,
  `t04_settingTheSameTextIsANoOp`).
- Смена цвета → ноль layout snapshot — done (`t04_colorOnlyChangeTakesZeroLayoutSnapshots`)
  — потребовало добавить `.display` в `RenderCoordinator`'s non-layout subset (§1), без
  этого приёмка не выполнялась бы.
- `dispose()` без поздних задач — done
  (`t04_detachDuringPendingTextChangeCommitsNothingLate`); дополнительно верно по
  конструкции — `TextContentMeasurer` не запускает фоновую работу и не требует отмены.
- Snapshot не держит `Node` — done (`t04_snapshotMeasurerDoesNotRetainTheNode`).

Следующая карточка — T05 (`CoreTextRenderer` в `TrellisRender`: `CTFramesetter`,
строки/baseline из `CTLine`, `.exact`/`.atMost`, RTL, locale, системный шрифт).
