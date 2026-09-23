# ADR 0014 — `LayoutContentMetrics.measurer`, ручной `Hashable`, `DirtyReasons.display`

Дата: 2026-09-12. Решения D49/D52/D59 (T01), карточка реализации T03/T04.

## Изменение

```
 public struct LayoutContentMetrics: Sendable, Hashable {
     public let intrinsic: MeasuredSize
     public let firstBaseline: Double?
+    public let measurer: (any ContentMeasurer)?

     public init(
         intrinsic: MeasuredSize = MeasuredSize(width: 0, height: 0),
-        firstBaseline: Double? = nil
+        firstBaseline: Double? = nil,
+        measurer: (any ContentMeasurer)? = nil
     ) { ... }

+    public static func == (lhs: Self, rhs: Self) -> Bool { ... }
+    public func hash(into hasher: inout Hasher) { ... }
 }

+public protocol ContentMeasurer: Sendable {
+    var identity: ObjectIdentifier { get }
+    var revision: UInt64 { get }
+    func measure(_ constraint: SizeConstraint, context: LayoutContext) throws -> LayoutContentMetrics
+}

 public struct DirtyReasons: OptionSet, Sendable, Hashable {
     ...
+    public static let display = DirtyReasons(rawValue: 1 << 5)
 }
```

`api/TrellisCore.json` фиксирует `LayoutContentMetrics` как `changed` (новое
поле, новый init-параметр, ручные `==`/`hash`), `ContentMeasurer` и
`DirtyReasons.display` — `added`.

## Почему `Hashable` перестаёт быть auto-synthesized

`LayoutContentMetrics` — часть ключа `FlexMeasureCache`
(`LayoutMeasureCacheKey` содержит `LayoutInputSnapshot`, которая содержит
`content: LayoutContentMetrics`, D49). Auto-synthesized `Hashable` для нового
поля `measurer: (any ContentMeasurer)?` не компилируется: `any ContentMeasurer`
не `Hashable`, а протокол-тип с closure-подобной семантикой (реализация может
захватывать состояние) не годится под структурное равенство — двух узлов с
измерителями, дающими одинаковый результат, не обязаны быть тем же
Swift-значением. D49 требует другого контракта: **равные `(identity,
revision)` обязаны означать одинаковый результат измерения**, поэтому
`Hashable`/`Equatable` пишутся вручную по `(intrinsic, firstBaseline,
measurer?.identity, measurer?.revision)` — то же решение, что кэш-ключи `H02`/
`A03` уже используют для сравнения по стабильной идентичности вместо
структурного сравнения closure.

Это не отменяет пригодность `LayoutContentMetrics` для узлов без содержимого:
`measurer == nil` — обычный случай, `hash`/`==` для него не читают ничего
нового, поведение существующих тестов C12/C31 не меняется.

## Почему это не source-breaking

Новый параметр `measurer` имеет default `nil` — существующие вызовы
`LayoutContentMetrics(intrinsic:firstBaseline:)` продолжают компилироваться.
Ручные `==`/`hash` заменяют auto-synthesized с идентичным поведением там, где
`measurer == nil` с обеих сторон (единственный случай, который встречается в
текущем коде до T03). Mangled name инициализатора меняется — тот же класс
изменения, что ADR 0002/0011.

`DirtyReasons.display` — новый case в уже открытом для расширения `OptionSet`
(не `enum`) — добавление не ломает exhaustive `switch`, потому что
`DirtyReasons` нигде не переключают через `switch` по отдельным битам, только
`.contains`/`.isEmpty` (проверено в `Invalidation.swift` и вызывающих местах).

## Почему `.display` — отдельный бит, а не переиспользование `.appearance`

`.appearance` уже означает «слой нуждается в `applyAppearance`» (фон, рамка,
opacity — синхронно, без фонового прохода). `.display` по D52 означает «нужен
асинхронный display pass» (текстовый растр через `DisplayScheduler`, T06) —
разная работа, разный исполнитель (`LayerRenderer.applyAppearance` vs.
`DisplayTransaction`), разное время (синхронно в commit vs. после commit,
`onPostCommit`). Слияние в один бит заставило бы `onPostCommit` каждый раз
проверять, было ли изменение на самом деле paint-only-текстовым, читая
состояние, которое сам бит обязан был нести.

## Решение

Обновить baseline через `check_api.py --update --review-note
docs/adr/0014-content-measurer-and-display-dirty-reason.md` при реализации T03
(добавление `ContentMeasurer`/`measurer`) и снова при T04
(`DirtyReasons.display` уже добавлен здесь, но `TextNode` — первый
потребитель).

## Дополнение T03 — `FlexMeasureResult.firstBaseline`

Реализация D49 в T03 (`docs/validation/t03-content-measurement.md`) потребовала того
же класса изменения ещё в одном месте: `FlexMeasureResult` получает новое поле
`firstBaseline: Double?` с default `nil`, тем же путём (новый параметр init со
значением по умолчанию → старый mangled name «удалён», новый «добавлен» в
`check_api.py`). Причина: `alignItems: .baseline` в `FlexboxPlacement.swift` до
T03 читал `child.content.firstBaseline` — статическое значение снимка. Узел с
измерителем меряется заново на каждом реальном constraint (§3.1 implementation-
plan-4.md), поэтому его актуальный baseline существует только в *результате* этого
измерения (`FlexMeasureResult`), не в снимке. Baseline-выравнивание без этого поля
продолжало бы читать значение до T03 — корректное для узлов без измерителя (не
меняется), но замороженное для узлов с измерителем. Обратная совместимость та же:
`firstBaseline: Double? = nil` не ломает существующие вызовы `FlexMeasureResult(...)`.
