# R03 — State bindings и анимационное намерение

Дата: 2026-09-14. Карточка [implementation-plan-6.md](../implementation-plan-6.md)
§5, R03. Зависимость: R02.

## Публичная запись P6.2 (уточнена на внешнем consumer)

`Sources/TrellisFlux/FluxStateBinding.swift`:

```swift
extension NodeHostBridge {
    @discardableResult
    public func bindFlux<Value: Sendable & Equatable>(
        _ flux: Flux<Value>,
        initial: Value,
        animation: @escaping @Sendable (Value, Value) -> Animation = { _, _ in .smooth },
        update: @escaping @MainActor (Value, Animation) -> Void
    ) -> FluxStateBinding<Value>
}
```

Полное обоснование каждого решения — [ADR 0022](../adr/0022-flux-state-binding.md).
Коротко: поверх уже существующего `StateSubject`/`bindState` (D14), не отдельный
delivery path; `initial` — синхронная замена отсутствующего у Flux current;
`animation(previous, next)` вычисляется относительно последнего **доставленного**
значения и применяется вызывающей стороной вокруг своих мутаций
(`someNode.animate(intent) { ... }`) — сам binding узлов не касается.

## Session ownership, bounded delivery, epoch, явный cancel

Не реализовано заново — унаследовано от `NodeHostBridge.bindState`/
`StateBindingRecordOf` (D14), уже покрытого `StateBindingTests.swift`. Новое здесь —
только: (1) явный `initial` вместо синхронного current, (2) async pump с проверкой
`Task.isCancelled` непосредственно перед действием над вытянутым из потока
значением, (3) собственное владение через self-удерживающее замыкание (см. ниже).

## Найденный дефект: binding без сохранённой ссылки переставал доставлять

Первая версия `FluxStateBinding` не была ничем удержана после возврата из `bindFlux`
и в `deinit` активно отменяла pump-задачу. Любой вызывающий, не сохранивший
возвращаемое значение (совершенно обычный паттерн — `bindState` явно документирует,
что отбрасывание его `StateBinding` **не** останавливает доставку), терял доставку
после первого значения молча, без ошибки.

**Как найдено:** при написании тестов этой карточки — тесты, полагавшиеся на
доставку *второго* значения, падали; тесты, проверявшие только *начальное* значение
или *отсутствие* доставки, проходили (ложно, по совпадению формы, а не потому что
поведение было верным). Изолированный пробник (`Tests/TrellisFluxTests/
ReproTest.swift`, удалён после диагностики) подтвердил: `let binding = ...` живущий
до конца функции — работает; тот же вызов без сохранения — нет.

**Исправлено**: замыкание, которое `bindState` и так удерживает пока жива
регистрация (задача моста), теперь дополнительно захватывает `self`
(`FluxStateBinding`) — тот же паттерн владения, что уже есть у самого
`StateBindingRecordOf.update`. Мост теперь транзитивно удерживает
`FluxStateBinding` (и через него — pump), пока не вызван `cancel()`, который и
разрывает получившийся цикл `self` ↔ `record` — намеренно, тем же способом, что уже
документирует `StateObservation` ("держатель должен явно отменить").

## Burst coalescing проверено эмпирически, не предположено

Итоговый контракт (см. ADR 0022 полностью): **coalescing быстрого продюсера — работа
самого продюсера**, не этого binding'а. Это не сокращение объёма работы, а
проверенный факт:

- Прямой пробник (`repro_burstDelivery`/`repro_exactBurstTestShape`, оба удалены
  после диагностики) показал: `for await value in flux.stream` — настоящая
  приостановка на каждой итерации, включая уже буферизованные значения; scheduled
  delivery task для значения *N* достоверно выполняется раньше, чем pump переходит
  к значению *N+1* — тот же порядок FIFO, что и ожидался, но означающий отсутствие
  естественного объединения на уровне pump'а.
- Добавление ещё одного слоя "latest + scheduled" внутри pump'а не решает это: race
  имеет форму "задача A планирует задачу B, затем A снова ждёт" — B, будучи
  запланированной раньше, гарантированно выполнится раньше повторного ожидания A,
  независимо от того, кто именно это планирует.
- Существующие Flux-операторы `throttle`/`debounce` — уже готовый, задокументированный
  инструмент для этого именно случая; тест
  `test_fluxBinding_throttledUpstreamIsHowACallerCoalescesAFastProducer` подтверждает
  композицию `pipe.flux.throttle(...)` перед `bindFlux` работает.

Тест `test_fluxBinding_rapidSuccessionConvergesToTheLastValueWithoutCorruption`
проверяет то, что действительно гарантируется под таким чередованием: ни одно
значение не теряется, финальное состояние — последнее отправленное, и каждый
доставленный intent соответствует именно (предыдущее **доставленное**, это
доставленное) — не какому-то промежуточному значению, мимо которого проехала
доставка.

## Тесты (`Tests/TrellisFluxTests/FluxStateBindingTests.swift`, 12 тестов)

| Тест | Что проверяет |
|---|---|
| `initialLandsInFirstCommitWithoutAnimation` | `initial` доставляется с `Animation.none` |
| `rapidSuccessionConvergesToTheLastValueWithoutCorruption` | Корректность под быстрой последовательностью без гарантии числа доставок (см. выше) |
| `throttledUpstreamIsHowACallerCoalescesAFastProducer` | `.throttle` перед `bindFlux` реально сокращает число доставок |
| `equalValueIsANoOp` | Дедупликация через `StateSubject`, унаследованная от D14 |
| `cancelAfterEnqueuePreventsLateDelivery` | Значение, отправленное непосредственно перед `cancel()`, не доставляется |
| `detachStopsDeliveryAndReattachRestoresLatest` | detach останавливает доставку; reattach отдаёт последнее значение |
| `suspendHoldsLatestAndResumeDeliversIt` | suspend удерживает последнее; resume доставляет его |
| `twoHostsEachGetIndependentDelivery` | Два независимых `NodeHostBridge` на одном `Flux` источнике не влияют друг на друга; cancel одного не трогает другой |
| `reentrantSendFromInsideUpdateDoesNotDeadlockOrLoseValues` | `update` может сам отправить новое значение в тот же Flux источник без deadlock/потери |
| `replaceRootStopsDeliveryToTheOldTreeWhenCancelled` | Отмена перед заменой root не даёт старому дереву увидеть более позднее значение |
| `bridgeReleasesNothingItShouldNot` | Явный `cancel()` + `detach()` освобождают узел (слабая проверка) без утечки |
| `stateDrivesARealAnimatedGeometryChangeAndReplayIsInstant` | `update` реально вызывает `node.animate(intent) { style.width = ... }`; `calculatedFrame` подтверждает и мгновенный replay (`initial`/`.none`), и настоящее анимированное геометрическое изменение по более позднему значению |

## Проверки

| Проверка | Результат |
|---|---|
| `swift build` | чисто, `-warnings-as-errors` |
| `swift test` (весь пакет) | 716 тестов зелёные (704 из R02 + 12 новых); один ретрай снял известный флейк `m12_...` (defects.md #60) |
| `python3 Scripts/check_policy.py` | 0 diagnostics — `bindFlux`/`FluxStateBinding` документированы (Ownership/Isolation/Errors/Cancellation) |
| `Scripts/check_api.py` (все 5 модулей + `--tvos`) | PASS; `TrellisFlux` — 5 символов (`FluxStateBinding` + `TrellisFlux` enum из R02) через [ADR 0022](../adr/0022-flux-state-binding.md) |

## Известный пробел API extraction (не блокирует карточку)

`Scripts/check_api.py` не видит `NodeHostBridge.bindFlux` ни в одном baseline —
`swift-symbolgraph-extract` не отражает публичный API, добавленный расширением типа
из ДРУГОГО модуля, ни с `-emit-extension-block-symbols`, ни без него (проверено
напрямую на этом тулчейне). Задокументировано в `check_api.py`'s комментарии к
`MODULES["TrellisFlux"]` и в [ADR 0022](../adr/0022-flux-state-binding.md) — не
переоткрывать вслепую в следующей карточке, добавляющей cross-module extension.
`check_policy.py`'s `PUBLIC_DOCUMENTATION` правило (по исходникам, не по symbol
graph) остаётся фактическим enforcement для таких деклараций.

## Открытые пункты

- Эффекты/действия (P6.7, hooks `onLoad`/`onRefresh`/...) — не в этой карточке, R04.
- iOS/tvOS device/simulator matrix для этого изменения — часть штатного
  `verify_bootstrap.py --matrix`; отдельно в этой карточке не прогонялась заново
  (код platform-neutral, не касается UIKit/AppKit; см. R02's evidence для матрицы).
