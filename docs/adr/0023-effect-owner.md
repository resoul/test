# ADR 0023 — `EffectOwner`

Дата: 2026-09-14. Карточка R04 (`docs/implementation-plan-6.md`, P6.7). Зависимость: R03.

## Изменение

`Sources/TrellisFlux/EffectOwner.swift` — новый public type, ничего существующего
не меняет:

```swift
@MainActor
public final class EffectOwner<Key: Hashable & Sendable> {
    public enum Conflict: Sendable { case restart, ignoreIfRunning }

    public init()

    @discardableResult
    public func run<Result: Sendable>(
        _ key: Key,
        onConflict: Conflict = .restart,
        operation: @escaping @Sendable () async -> Result,
        apply: @escaping @MainActor (Result) -> Void
    ) -> Bool

    public func isRunning(_ key: Key) -> Bool
    public func cancel(_ key: Key)
    public func cancelAll()
}
```

## Почему это, а не hooks/LoadState на `ListNode` уже сейчас

R04's формулировка — "специфицировать hooks и ownership P6.7 **на fake API**." Ни
`ListNode`, ни `TableNode` не существуют (R10+), и P6.7 сама оговаривает: "точные
сигнатуры фиксируются в R04/**R10** на внешнем consumer" — сигнатуры контейнерных
hooks (`onLoad`/`onRefresh`/`onLoadMore`/`onRetry`) равно как полный `LoadState`
(initial/loading/loaded/empty/error + refreshing/loadingMore/pageError, P6.7 пятый
пункт) требуют реального контейнера для примерки, иначе рискуют зафиксировать
поспешную форму. R04 вместо этого строит и тестирует **владение эффектом** — общий
примитив, на котором такие hooks будут реализованы, независимо от контейнера:
keyed replace/cancel/restart policy, гарантированное отбрасывание результата
превзойдённого запроса, наблюдаемый отказ дублирующего запуска. Это именно то, что
акцептанс карточки перечисляет буквально: "владение keyed effect, replace/cancel,
restart policy... state отделён от событий, переполнение действий наблюдаемо...
запрос A завершается после B; применяется B, A освобождается."

## Почему гарантия "A освобождается" реализована внутри `run`, а не оставлена вызывающему

Первый набросок передавал вызывающему только `Task.isCancelled` внутри его же
`operation` — а он мог не проверить это перед тем, как применить результат.
Итоговая форма `run` берёт результат `operation` **и решение, применять ли его**,
в одно место: результат передаётся в `apply` только если слот для `key` всё ещё
принадлежит **этому** запуску (по generation, не по совпадению значений) — ни отменённый
явно (`cancel`/`cancelAll`), ни превзойдённый более новым `run(key:)` результат
никогда не долетает до `apply`, структурно, а не по соглашению, которое каждый
hook должен был бы повторять сам. Это тот же самый монитор, что уже потребовался
Flux'у в R01/R02 для `flatMapLatest` (дефект #59) — здесь применён напрямую к
`Task`, без обращения к внутренностям Flux (`_LatestSubscription` — `internal`,
недоступен извне), тем же по сути способом.

## Почему `onConflict` — два варианта, не общий "debounce"/очередь

P6.7 явно разводит два разных требования: "Для lifetime одной модели допускается
**один** initial request in-flight" (не дублировать) и "Refresh заменяет актуальный
запрос" (всегда заменять). `.ignoreIfRunning` и `.restart` — прямое отражение этих
двух явно различных правил, а не общий "гибкий" enum с нерасшифрованными
параметрами. `loadMore`'s "один page request на cursor" — тот же
`.ignoreIfRunning`, тестами показано в `test_effectOwner_
loadMoreDeduplicatesRepeatedDemandForTheSameCursor`.

## Почему две зоны владения, не одна встроенная "view scope"

P6.7: "View-owned запрос отменяется при завершении его session. Model-owned запрос
может продолжаться при уходе страницы." `EffectOwner` не привязывается к
`NodeHostBridge` автоматически — он остаётся таким же простым объектом, как
`StateSubject`, которым владеет создатель. View-owned зона — обычный
`EffectOwner`, который держит и отменяет (`cancelAll()`) сессия экрана; model-owned
зона — обычный `EffectOwner`, которым владеет сама модель, независимо от того, есть
ли сейчас смонтированный экран. Это то же самое разделение владения, что уже
устоялось для `FluxStateBinding`/`bindState` (D14, ADR 0022) — явное владение
вызывающей стороной, без скрытой привязки к мосту.

## Тестовый двойник, не реальная сеть

`Tests/TrellisFluxTests/EffectOwnerTests.swift`'s `ControllableRequests` даёт
детерминированное завершение запроса по явному вызову теста (`resolve(id:with:)`),
без `sleep`/`Task.sleep`/реальной сети — тот же принцип, что уже применял R01's
аудит для гонок Flux. Найдено при написании тестов (не гипотеза): `AsyncStream.
Iterator.next()` реагирует на отмену **потребляющей** задачи и может вернуть `nil`
немедленно, даже если производитель не звал `finish()` — отменённый запрос в
`test_effectOwner_restart...`/`test_effectOwner_releasesEverything...` завершался
раньше, чем тест успевал вызвать `resolve`, разворачивая принудительный `!`
force-unwrap в падение. Исправлено введением явного "прерванного" значения-заглушки
(`interruptedValue`), которое `EffectOwner` в любом случае отбрасывает по
generation-проверке — падение было в тестовом двойнике, не в самом `EffectOwner`.

Полные найденные и разобранные сценарии, а также причина, по которой тесты сначала
падали под полным набором (`swift test`, не в изоляции) — блокирующий poll вместо
условного ожидания — см. [r04-effect-owner.md](../validation/r04-effect-owner.md).

## Решение

Baseline обновлён через `check_api.py --module TrellisFlux --update --review-note
docs/adr/0023-effect-owner.md`.
