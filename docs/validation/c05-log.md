# C05 — Log и корреляция запросов

Дата: 2026-09-10. C05 реализована на минимальном содержимом пакета
(до `Node`/дерева/солвера — они появляются в M2/M3). `Log` и его формат строки
готовы принять их события без изменения контракта.

## Что добавлено

- `Sources/TrellisCore/Log.swift`: `LogArea` (11 областей полного конвейера
  из `docs/weave-analysis.md` §6.4), `Log.enabled` (`static let`, once per
  process, `TRELLIS_LOG` через `parseLogAreas`), `Log.on(...)`, `Log.milliseconds(_:)`,
  `CacheOutcome`.
- Формат строки фиксирован для всех областей одинаково:
  `[trellis.<area>] <event> host=<h|none> gen=<g|none> #<node|none> parent=#<parent|none> <details>`.
  `gen=none`/`host=none` до первого host-запроса — не ошибка, а ожидаемое
  состояние tree-события.
- `host`/`generation` — явные параметры `Log.on`, не глобальная изменяемая
  «текущая генерация»: у двух хостов generation может совпасть, различает
  их только пара (host, gen), переданная вызывающим кодом.
- Три internal чистые функции, тестируемые без обращения к `Log.enabled`:
  `parseLogAreas(_:fallback:)`, `formatLogLine(...)`, `logIfEnabled(_:in:line:output:)`.
  Последняя выделена специально, чтобы проверить «сообщение не вычисляется
  при выключенной области» без попытки мутировать once-инициализированный
  `static let` между тестами — ровно то ограничение, которое называет карточка.
- `ZERO-SIZE`/`OVERFLOW` — соглашение по тексту `event`/`details` для будущей
  области `place` (C12), не отдельный API: геометрии пока не существует,
  вводить под неё типы преждевременно.

## Проверки

- `Tests/TrellisCoreTests/LogTests.swift`: `parseLogAreas` — unset/all/off/
  список/неизвестные имена/пустая строка; `formatLogLine` — все поля,
  `none`-значения, различимость параллельных host/generation; `logIfEnabled` —
  выключенная область не вызывает `line()`, включённая передаёт результат в
  `output`, чужая область не срабатывает; `Log.milliseconds`.
- `Scripts/check_log_env.py`: реальный процесс, реальный `stdout`, без
  внедрённого sink. Собирает временный consumer-пакет с исполняемым
  `LogSmoke`, вызывающим `tree`/`schedule`/`host`, и запускает его четыре
  раза: без `TRELLIS_LOG` (ожидание — все области, поскольку debug-сборка
  задаёт `DEBUG`), `all`, `off`, `schedule,commit`. Проверяет фактическое
  присутствие/отсутствие строк `[trellis.<area>]`.
- `Scripts/check_all.py` подключает `check_log_env.py` каждый обычный прогон.

## Выполненные проверки

| Проверка | Результат |
|---|---|
| `swift test` (23 теста, включая 12 новых Log-тестов) | PASS |
| `python3 Scripts/check_log_env.py` | PASS: unset/all/off/list дают ожидаемый реальный stdout |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c05-log.md` | UPDATED — новый публичный API `Log`/`LogArea`/`CacheOutcome`, ADR не требовался (только добавления) |
| `python3 Scripts/check_all.py` | PASS |

## Не засчитывается этим отчётом

Реальные события конвейера (`tree.created`, `schedule.request`, `measure`,
`place` и т.д.) — они появляются вместе с Node/solver/coordinator в
следующих карточках M2–M4; `Log` здесь проверен на синтетических вызовах.
Длительность solve и cache hit/miss — формат и `Log.milliseconds`/`CacheOutcome`
готовы, но без солвера нет реального значения для передачи.
