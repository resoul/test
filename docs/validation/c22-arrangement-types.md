# C22 — Arrangement-типы, builder и внешний subclass API

Дата: 2026-09-10. Реализует типы контракта, зафиксированного в
[c21-arrangement-contract.md](c21-arrangement-contract.md). Резолвер (C23) и
триггер, помечающий owner `.arrangement`-грязным, по-прежнему не существуют —
эти типы описывают дерево, но ничего пока его не читает.

## Что добавлено

- `Sources/TrellisCore/Arrangement/Arrangement.swift`: `public protocol
  Arrangement {}` — маркерный протокол без требований. `lower(_:)` (`package`,
  `@MainActor`) — единственное место, которое различает конкретные типы через
  `switch ... case let ... as ...`; `ArrangementDescriptor`/
  `ArrangementContainer`/`ArrangementModifiers` — `package`-scoped замкнутый
  набор форм, который будущий resolver (C23) будет обходить.
- `Sources/TrellisCore/Arrangement/ArrangementTypes.swift`: `Leaf`/`Row`/
  `Column`/`Overlay` — публичные структуры, каждая хранит `package let
  container`/`node` (видимо внутри SPM-пакета, не снаружи) и строится через
  `@ArrangementBuilder` замыкание.
- `Sources/TrellisCore/Arrangement/ArrangementModifiers.swift`:
  `ModifiedArrangement` плюс `extension Arrangement` с `.grow`/`.size`/
  `.align`/`.margin`/`.offset` — каждый оборачивает текущее значение,
  накапливая `ArrangementModifiers` через `merge(overriding:)` (последний
  вызов на одно и то же поле побеждает).
- `Sources/TrellisCore/Arrangement/ArrangementBuilder.swift`:
  `@resultBuilder public enum ArrangementBuilder` — `buildBlock`/
  `buildExpression`/`buildOptional`/`buildEither`/`buildArray` покрывают
  последовательность, `if`/`else`, optional `if` и `for`.
- `Sources/TrellisCore/Node.swift`: `open func arrangeSubnodes() -> (any
  Arrangement)? { nil }` — объявлено в теле класса (не в extension), ничего
  его пока не вызывает.

## Закрытый набор без публичного requirement-based lowering

Черновик C21 предполагал протокол с требованием, возвращающим internal-тип —
это не компилируется: Swift не позволяет public-протоколу иметь requirement,
чья реализация имела бы меньшую видимость (compiler error: "property cannot
be declared public because its type uses an internal/package type" — witness
обязан быть настолько же публичным, насколько сам requirement). Решение
здесь: `Arrangement` — пустой маркер (никаких requirements вообще), а
`lower(_:)` — свободная `package`-функция, которая по каждому конкретному
типу (`Leaf`/`Row`/`Column`/`Overlay`/`ModifiedArrangement`) вручную строит
`ArrangementDescriptor`. Сторонний тип может формально объявить conformance
(`struct Foo: Arrangement {}`) — протокол пуст, это всегда легально — но
`lower(_:)` не узнает его и вернёт `default:` ветку: пустой `.row` без детей
плюс `Log.on(.arrange, "unrecognized", ...)`. Никакого `fatalError`
(запрещён `FORCE_OPERATION`) — builder-сцена, тихо не внёсшая ничего, безопаснее
рантайм-трапа для декларативного UI. Это и есть выбор "документированного
lowering" из чеклиста C22, только не через requirement, а через закрытый
`switch` плюс `package`-видимость данных, которые сторонний conformance не
может даже прочитать.

`ArrangementDescriptor`/`ArrangementContainer`/`ArrangementModifiers` —
`package`, не `internal`: наружу (внешний SPM-consumer из
`verify_bootstrap.py`) они не видны вообще, а будущему resolver — в любом
таргете того же пакета `Trellis` — открыты без `@testable`.

## Overlay

`Overlay.init` не принимает `spacing`/`justify`/`align` — только `padding`.
Внутри `ArrangementContainer` эти поля всё равно существуют (нужны той же
структуре, что и `Row`/`Column`) и получают инертные дефолты
(`spacing: 0, justify: .start, align: .stretch`), не как публичная
конфигурация, а как заполнитель общей структуры (см. c21-документ:
`spacing`/`justify`/`align` инертны для Overlay).

## Проверки

`Tests/TrellisCoreTests/ArrangementTests.swift` — 15 тестов: лоуеринг
`Leaf`/`Row`/`Column`/`Overlay` (конфигурация и порядок items), пустой
контейнер, накопление модификаторов на разных полях, «последний вызов
побеждает» на одном поле, `.size` не стирает уже заданное измерение, четыре
формы builder'а (последовательность, `if` без `else`, `if`/`else`, `for`),
нераспознанная сторонняя conformance лоуерится в пустой контейнер вместо
краша, полный пример `ProfileCard` (зеркало C21) — вложенный `Column` с
`.grow(1)`, реальные `NodeID` в списке items, — и дефолт `arrangeSubnodes()
== nil`.

`Scripts/verify_bootstrap.py`: внешний consumer (`Smoke.swift`, без
`@testable`) получил `ProfileCard: Node` с тем же `arrangeSubnodes()`
override, что и в тестах, и проверяет `profileCard.arrangeSubnodes() is Row`
— доказывает, что публичный API (`Node.arrangeSubnodes`, `Arrangement`,
`Leaf`/`Row`/`Column`, `ArrangementBuilder`'s sequence/nesting forms,
`.size`/`.grow`) компилируется и переопределяется снаружи `TrellisCore` без
доступа к `package`-scoped `lower(_:)`/`ArrangementDescriptor`.

| Команда | Результат |
|---|---|
| `swift build` (чистый `.build`, без warnings-as-errors ошибок) | PASS |
| `swift test` (236 тестов, включая 15 новых; проверено 6× подряд после чистой пересборки) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_all.py --skip-api` | PASS (policy, verify_bootstrap incl. `ProfileCard` consumer, TRELLIS_LOG env) |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c22-arrangement-types.md` | UPDATED — только `added` (никаких `changed`/`removed`): `Arrangement`, `lower`-обвязка недоступна снаружи (не в diff, `package`), `Leaf`/`Row`/`Column`/`Overlay`/`ModifiedArrangement`/`ArrangementBuilder`, `Node.arrangeSubnodes()` |

Первая попытка `swift test` для полного пакета (оба таргета) после
изменения `Node.swift` без чистой пересборки давала детерминированный
крэш (`signal code 10`) внутри `swiftpm-testing-helper` — воспроизводилось и
с тривиальным несвязанным `open`-методом на `Node`, без Arrangement вообще, и
исчезало после `rm -rf .build` + пересборки. Это устаревший инкрементальный
кэш SwiftPM/testing-helper, рассинхронизировавшийся при изменении публичной
поверхности `Node` между двумя таргетами теста, а не баг в коде этой
карточки — на чистой сборке (6 прогонов подряд) `swift test` стабилен.

## Не входит в эту карточку

Резолвер (кто читает `arrangeSubnodes()` и мутирует живое дерево), триггер
`.arrangement`-грязного состояния и его wiring в `InvalidationTransaction` —
всё C23. `structuralPath`/identity-ключ wrapper'ов (D06) не вычисляется
здесь: `ArrangementContainer.items` — просто упорядоченный список, путь
берётся из его индекса только когда появится resolver.
