# C06 — Геометрия, NodeID и структура snapshot/result

Дата: 2026-09-10. C06 реализована в объёме, который не требует ещё не
существующего `LayoutStyle` (C07) или дерева (C08): геометрия/constraints/
rounding — чистые типы без зависимостей на style/Node.

## Что добавлено

Новая директория `Sources/TrellisCore/Layout/` — ровно тот путь, под который
`check_policy.py` уже ограничивал правило `LINEAR_IDENTITY_LOOKUP`
(`docs/weave-analysis.md` §Н2), хотя каталог ещё не существовал. Файлы:

- `Geometry.swift` — `LayoutDirection`, `LayoutPoint`, `MeasuredSize`, `LayoutFrame`.
- `SizeValue.swift` — `.points`/`.fraction`/`.auto`; `.fraction` без известного
  `parent` возвращает `nil`, а не `0` — неопределённый размер родителя не ошибка.
- `SizeConstraint.swift` — `SizeConstraintAxis` (`.unspecified`/`.atMost`/`.exact`)
  и `SizeConstraint`, независимая нормализация по оси.
- `EdgeInsets.swift` — `DirectionalEdgeInsets`/`PhysicalEdgeInsets` и
  `DirectionalEdgeOffsets`/`PhysicalEdgeOffsets`; `resolved(for:)` — единственное
  место, где leading/trailing превращается в left/right.
- `PixelRoundingPolicy.swift` — `scale`, `snapped(_:)`, `LayoutFrame.rounded(to:)`.
  Разный `scale` двух хостов даёт разное округление одного и того же логического
  фрейма — это не дефект солвера (F01).
- `LayoutContext.swift` — Sendable-контекст исполнения солвера (D10):
  `LayoutContext.noCancellation` для синхронных математических тестов,
  `LayoutContext(cancellationCheck:)` для инъекции предиката,
  `LayoutContext.currentTask()` — фабрика, которой C13 воспользуется для
  реального планировщика. `checkCancellation()` бросает
  `LayoutCancellationError.cancelled` (D09); пустой/частичный результат
  никогда не кодирует отмену.
- `LayoutResult.swift` — `LayoutPlacement` (`identity: NodeID`, `frame`) и
  `LayoutResult` (`placements`, `treeIdentity`). `frame` — абсолютные
  координаты в пространстве layout root; преобразование в parent-local
  выполняет рендерер (C16) ровно один раз. Результат не содержит `Node` и
  платформенных объектов.

## Осознанно не сделано в этой карточке

- `LayoutResult.placement(for:)` — не добавлен. Наивный линейный поиск
  (`.first { $0.identity == ... }`) — ровно тот паттерн, на который нацелено
  правило `LINEAR_IDENTITY_LOOKUP` в этом каталоге; писать его сейчас и чинить
  regex-обходом в C11 нечестно. Массив `placements` остаётся публичным,
  индексированный lookup — предмет C11, без изменения имён полей.
- `environmentRevision`/`contentRevision` на `LayoutResult` — оставлены за
  скобками: эти счётчики принадлежат ещё не существующим C09 (dirty-причины)
  и C14 (revision guards). Добавление поля позже — обычное расширение API,
  не ломающее существующий baseline.
- `LayoutInputSnapshot`, `LayoutStyle`, flex-перечисления (`FlexDirection` и
  т.д.) — не перенесены: они требуют `LayoutStyle` (C07) и содержания
  измерения (`LayoutContentMetrics`, C10), которых у C06 нет в зависимостях.
- Пункт «NodeID сделать типом, отличным от revision/generation; генератор
  живых нод принадлежит MainActor» — уже выполнен в C02 (`NodeID`/
  `NodeIDAllocator`); в C06 подтверждён без изменений.

## Проверки

`Tests/TrellisCoreTests/Layout/`: `GeometryTests`, `SizeValueTests`,
`SizeConstraintTests`, `EdgeInsetsTests`, `PixelRoundingPolicyTests`,
`LayoutContextTests`, `LayoutResultTests` — finite/negative/non-finite/scale
для каждого типа, LTR/RTL резолюция insets/offsets, `LayoutContext`
без отмены/с предикатом/с реальным `Task` (отмена через `task.cancel()`,
проверено внутри того же `Task`).

| Проверка | Результат |
|---|---|
| `swift test` (65 тестов, включая 42 новых) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics — включая `LINEAR_IDENTITY_LOOKUP` на новом `Layout/` |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c06-geometry-layoutcontext.md` | UPDATED — новый публичный API, только добавления |
| `python3 Scripts/check_all.py` | PASS |

## Не засчитывается этим отчётом

Рабочий flex-путь (измерение/размещение) — C12, ему потребуется
`LayoutInputSnapshot` и `LayoutStyle` (C07), которых здесь нет.
Индексированный lookup `LayoutResult` — C11. Ревизии на `LayoutResult` —
появятся вместе с их источником в C09/C14.
