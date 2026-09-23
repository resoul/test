# H10 — Нагрузка pointer-сессий и lifecycle

Дата: 2026-09-11. Карточка D-группы
[implementation-plan-2.md](../implementation-plan-2.md) §5. Зависимость H09
закрыта. Приёмка выполнена автоматическими тестами без временных порогов — по
тому же принципу, что `LoadAndTeardownTests` C26.

## Что проверяется

| Тест | Нагрузка и проверяемый контракт |
|---|---|
| `test_pointerLoad_manyControlsAndSequentialPointerIDsLeaveNoSessionsOrArenas` | 128 `ControlNode` в одном committed-дереве, 8 быстрых раундов, 1024 монотонно растущих pointer ID. Каждый down/up активирует ровно один control; после всего прогона и после detach session/per-session arena равны нулю, layer registry пуст. |
| `test_pointerLifecycle_repeatedActiveAttachDetachReleasesBridgeRootsAndControls` | 24 свежих дерева по 32 controls последовательно монтируются на один bridge. В каждом раунде Tap переводится в активный Pan, затем чередуются detach, suspend/resume со stale-up и resize с сохранением сессии до detach. Cancellation Pan приходит ровно один раз, activation не приходит, поздние move/up не вызывают callback. После выхода из scope weak bridge, host layer, все roots и выбранные controls равны `nil`. |
| `test_pointerLifecycle_disposeFromEveryPointerPhaseCancelsWithoutLaterCallbacks` | Control вызывает `dispose()` непосредственно из `pointerDown`, `pointerMove`, `pointerUp` и `pointerCancel`. Во всех четырёх случаях маршрут обрывается безопасно, activation отсутствует, session/per-session arena пусты, последующие события не доставляются. |

## Наблюдаемость arena

Отдельного arena-registry в Trellis нет: `GestureArena` принадлежит записи
`PointerSessions.Session` и живёт ровно одну сессию (D29). Для H10 добавлен
только package/internal test hook `activeArenaCount`, а bridge пробрасывает его
в `activeGestureArenaCount` для `@testable`-проверки. Публичный API не изменён.
Тест одновременно требует `activePointerSessionCount == 0` и
`activeGestureArenaCount == 0`, поэтому не допускает ни оставшейся записи
session, ни незакрытой arena.

## Результат

Команда:

```bash
TRELLIS_LOG=off swift test --filter PointerLoadAndLifecycleTests
```

Результат: 3 теста пройдены на macOS arm64, Swift Testing. Нагрузочный тест не
задаёт случайных бюджетов времени: проверяются числа доставок/активаций,
состояние registries, отсутствие поздних callback и освобождение объектов.
Новых дефектов runtime-реализации H02–H09 тесты не обнаружили.

Полный `TRELLIS_LOG=off python3 Scripts/check_all.py` также зелёный: policy,
формат, build с warnings-as-errors, полный Swift test suite, внешний consumer,
API baseline iOS/tvOS, 42 macOS screenshots и реальный `TRELLIS_LOG` subprocess.
Первый полный прогон обнаружил и зафиксировал
[дефект #32](../defects.md): после удаления устаревших корневых копий screenshot
gate всё ещё искал reference там, а S21 не был перенесён в `macOS/`. Путь
исправлен; два S21 восстановлены только после SHA-256-сверки с прежними tracked
blob (оба совпали с текущим рендером), поэтому новый visual baseline не
принимался.

## Приёмка карточки — итог

| Критерий | Статус |
|---|---|
| Много controls, быстрые повторные сессии, последовательные pointer ID | done — 128 / 1024 |
| Detach/attach, suspend/resume и resize во время активной сессии | done — 24 mount epoch |
| Dispose на down/move/up/cancel | done |
| Session и arena registries пусты после teardown | done |
| Weak release bridge/root/control | done; дополнительно host layer |
| Нет callback/activation после cancellation | done |
