# C13 — LayoutScheduler: validation

Дата: 2026-09-10.

## Автоматическая проверка

`LayoutSchedulerTests` использует actor-based worker gate, а не sleep. Первый worker A
останавливается до запуска math; пока он удерживает slot, запросы B и C поступают в
scheduler. B заменяется C в единственном `pending`-слоте. После детерминированного
освобождения A наблюдается старт только C, а единственный callback получает revision 3.

Отдельные тесты подтверждают, что `cancel()` и `dispose()` подавляют поздний result, а
неожиданная ошибка engine увеличивает diagnostics counter и не вызывает callback.

Команда проверки:

```text
swift test --filter LayoutSchedulerTests
```

Результат: 3 tests passed. В trace видны `supersede`, `cancelled`, `failure` и единственный
`commit result` для C (generation 3).

## Граница C31

Этот scheduler ограничивает work одним worker на host. Глобальный лимит нескольких hosts,
включая измерение задержки cooperative cancellation на широких flex-lines, остаётся задачей
C31; C13 не создаёт worker на node и не добавляет межхостовый registry преждевременно.
