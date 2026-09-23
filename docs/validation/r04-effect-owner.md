# R04 — Эффекты и действия

Дата: 2026-09-14. Карточка [implementation-plan-6.md](../implementation-plan-6.md)
§5, R04. Зависимость: R03.

## Спецификация P6.7 на fake API

`Sources/TrellisFlux/EffectOwner.swift` — полное обоснование каждого решения в
[ADR 0023](../adr/0023-effect-owner.md). Коротко: `EffectOwner<Key>` — keyed
эффект-владение (replace/cancel/restart policy), не привязанное ни к какому
контейнеру или сети; `onLoad`/`onRefresh`/`onLoadMore`/`onRetry` (реальные hooks
`ListNode`/`TableNode`, R10) будут реализованы поверх него, не заново.

```swift
@discardableResult
public func run<Result: Sendable>(
    _ key: Key,
    onConflict: Conflict = .restart,
    operation: @escaping @Sendable () async -> Result,
    apply: @escaping @MainActor (Result) -> Void
) -> Bool
```

`apply` вызывается **только** если этот конкретный запуск не был отменён/заменён к
моменту завершения `operation` — гарантия внутри `run`, а не соглашение, которое
каждый hook обязан был бы повторять.

## Владение keyed effect, restart policy, loading/error/retry

- `.restart` — заменяет текущий запуск для ключа (refresh, retry).
- `.ignoreIfRunning` — отказывает в дубликате, наблюдаемо через возвращаемое
  `Bool` (initial: не дублировать; loadMore: один page request на cursor).
- Ошибка — просто одно из значений `Result`, которое возвращает `operation`;
  `EffectOwner` не занимает позицию по её поводу. После завершения (успех или
  ошибка) слот освобождается — ключ немедленно доступен для повторного `run`
  (retry никогда не отказывается как "уже выполняется").

## State отделён от событий, переполнение действий наблюдаемо

`EffectOwner` не хранит и не публикует состояние загрузки само по себе — это
работа модели/`StateSubject` (R03). Переполнение действий (повторный запуск при
занятом ключе с `.ignoreIfRunning`) видно через возвращаемое `run(...) -> Bool`,
не проглатывается молча.

## Запрос A завершается после B; применяется B, A освобождается

Тест `test_effectOwner_restartAppliesOnlyTheNewerEvenWhenTheOlderCompletesLater`
проверяет буквально формулировку приёмки R04: A стартует, B заменяет A (`.restart`),
B завершается первым и применяется, A (уже отменённый) завершается позже —
generation-проверка внутри `run` отбрасывает результат A независимо от порядка
фактического завершения задач.

## Найденное при написании тестов (не гипотеза)

`AsyncStream.Iterator.next()` реагирует на отмену **потребляющей** задачи и может
вернуть `nil` немедленно — даже если производитель никогда не звал `finish()`.
Тестовый двойник (`ControllableRequests`) сначала завершался принудительным
разворачиванием (`!`) до того, как тест успевал явно разрешить запрос — падение
было в тестовом коде (наивное предположение "resolve — единственный путь
завершения"), не в `EffectOwner`. Исправлено явным "прерванным" значением-заглушкой,
которое `EffectOwner` в любом случае отбрасывает по generation-проверке.

Отдельно: тесты, зависящие от результата, сначала использовали фиксированное
число `Task.yield()` (300, как в `StateBindingTests.swift`) и падали **только** в
составе полного `swift test` (13 issues), но проходили по одному. Причина — не
дефект `EffectOwner`, а недостаточно щедрое, слепое ожидание под конкуренцией
полного набора (тот же класс проблемы, что и R03's burst-тест до его переписывания).
Исправлено переходом на `waitUntil(condition:)` — опрос условия до 100 000 витков,
как уже делает `NodeHostBridgeTests.swift`'s `waitForBridgeCommits`, вместо слепого
счётчика.

## Владение: model lifetime vs mounted UI lifetime — различены явно

`test_effectOwner_viewOwnedAndModelOwnedScopesAreIndependent`: два отдельных
`EffectOwner` — `viewScope` (аналог владения смонтированной сессией экрана) и
`modelScope` (аналог владения самой моделью). `viewScope.cancelAll()` (экран ушёл)
не трогает `modelScope`, который продолжает получать результат независимо —
буквально требование P6.7 ("model-owned запрос может продолжаться при уходе
страницы").

## Тесты (`Tests/TrellisFluxTests/EffectOwnerTests.swift`, 9 тестов)

| Тест | Что проверяет |
|---|---|
| `appliesTheResultOnceTheOperationCompletes` | Базовый путь: run → apply, `isRunning` корректен до/после |
| `ignoreIfRunningRefusesADuplicateAndObservesIt` | `.ignoreIfRunning` отказывает дубликату, возврат `false` наблюдаем |
| `restartAppliesOnlyTheNewerEvenWhenTheOlderCompletesLater` | R04's акцептанс буквально: A/B, B применяется, A — нет, независимо от порядка завершения |
| `differentKeysDoNotContend` | Два разных ключа не мешают друг другу |
| `loadMoreDeduplicatesRepeatedDemandForTheSameCursor` | Повторный demand возле границы не создаёт вторую in-flight страницу |
| `refreshCancelsPaginationAsAModelPolicy` | Модельная политика: refresh отменяет pagination явно; ключ pagination немедленно доступен снова |
| `errorDoesNotPermanentlyStickAKeyRetryRecovers` | Ошибка не блокирует ключ навсегда; retry проходит нормально |
| `viewOwnedAndModelOwnedScopesAreIndependent` | Раздельные зоны владения; `cancelAll()` одной не трогает другую |
| `releasesEverythingAfterCancelAllNoOrphanedTasks` | Явная отмена + отсутствие висящих задач (слабая ссылка) |

## Проверки

| Проверка | Результат |
|---|---|
| `swift build` | чисто, `-warnings-as-errors` |
| `swift test` (весь пакет, дважды подряд) | 725/725 тестов зелёные оба раза |
| `python3 Scripts/check_policy.py` | 0 diagnostics — `EffectOwner`/`Conflict` документированы |
| `Scripts/check_api.py` (все 5 модулей + `--tvos`) | PASS; `TrellisFlux` — 15 символов через [ADR 0023](../adr/0023-effect-owner.md) |

## Открытые пункты

- Реальные hooks `onLoad`/`onRefresh`/`onLoadMore`/`onRetry` на настоящем
  `ListNode`/`TableNode`, полный `LoadState` (initial/loading/loaded/empty/error +
  refreshing/loadingMore/pageError) и `DataSource`/`ItemProvider` (P6.9–P6.11) —
  R10, не эта карточка.
- `EffectOwner` не связывает автоматически "refresh отменяет pagination" — это
  продемонстрированная, но модель-специфичная политика (вызывающая сторона сама
  вызывает `cancel(.pagination)`), не встроенное поведение.
