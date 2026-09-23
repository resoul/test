# R11 — транзакции и сохранение позиции

Дата: 2026-09-23. Карточка [implementation-plan-6.md](../implementation-plan-6.md) §5, R11.
Зависимость: R10 (закрыта). Решения: [ADR 0031](../adr/0031-collection-transactions.md)
поверх [ADR 0030](../adr/0030-collection-data-contract.md). Статус: **закрыта 2026-09-23**
в пределах TrellisCore. Установка native offset во время реальной прокрутки UIKit/AppKit
относится к контейнеру (R12a) и там требует проверки на Simulator/устройстве.

## Что реализовано

| Файл | Содержание |
|---|---|
| `Collections/CollectionTransactions.swift` | `CollectionDelta`/`CollectionChange` (ID-based, строго по base revision), `CollectionDiff`, `CollectionPreparationInput`, `PreparedCollection.prepare` (воркер, отмена каждые 512 элементов), `CollectionAdjustment`, `CollectionAnchorOutcome`, `CollectionCommitRejection` |
| `Collections/MaterializationWindow.swift` | `preparationInput(for:)`, атомарный `commit(_:)` с проверкой generation/метрик, захват и восстановление якоря для commit/измерений/resize/estimate, `followsBottom`, `bottomTolerance`, `onOffsetAdjustment`, `offset`; `apply` = подготовка + commit синхронно |
| `Collections/CollectionUpdateQueue.swift` | Один воркер, одна ожидающая позиция (новый snapshot заменяет), повтор при rejection, `detach()`/`attach()` |

Логи: `commit dataset-applied` (+ inserted/removed/updated/moved/measureHit),
`commit dataset-rejected reason=stale-base|stale-metrics`, `commit anchor-restored`,
`schedule collection-prepare`, `collection-prepare-retry`, `collection-prepare-cancelled`.

## Тесты

`Tests/TrellisCoreTests/Collections/CollectionTransactionTests.swift` — 20 тестов:

- Дельты: ID-based insert/delete/move/update, дубль при insert отбрасывается, отсутствующий ID
  пропускается; `staleBase` и чужой data key отклоняются. Diff: 1 вставка, 1 удаление,
  1 обновление, 1 перемещение (longest increasing run).
- Якорь: prepend держит читаемую строку (offset 1000 → 1100); prepend при offset 0 не
  «прыгает» на новые строки; удаление выше сдвигает offset назад; удалённый якорь → ближайший
  сосед сохраняет позицию (−10 pt); reorder — якорь следует за элементом; измеренные высоты
  выше viewport (реальный `FlexboxEngine`) не двигают строку; follow-bottom только opt-in и
  только у конца; сжатие контента → clamp; смена оценки и ширины сохраняют строку; новый data
  key → offset 0; callback вызывается только при реальном сдвиге.
- Очередь (реальный воркер `Task.detached`): три snapshot подряд → коммиты [2, 4], один
  вытеснен; устаревшая база (commit между подготовкой и применением) → повторная подготовка;
  resize между подготовкой и применением → повтор; detach → snapshot сохранён до attach;
  viewport сдвинут во время подготовки (drag) → якорь берётся на момент commit.
- Property-тест, 5 seed × 120 шагов (prepend/append/delete/move/смена высоты + измерение
  реальной раскладкой): порядок и identity равны эталонной модели; живые ноды — ровно окно
  commit, в порядке, с моделями commit (нет частичного commit); якорь держит позицию с
  допуском 0.5 pt везде, где не было clamp; не менее 80 проверок якоря на seed. Мутационная
  проверка: без восстановления якоря — 210 нарушений.

## Замер (разовый, не бенчмарк)

10 000 элементов, prepend 20, viewport 800 pt, Mac (Apple silicon), `swift test -c release`,
`TRELLIS_LOG=off`, один прогон: `prepare` на воркере 5.2 ms, `commit` на MainActor 0.066 ms,
живых нод 64. Debug: 10.4 ms / 0.27 ms. Построение `CollectionSnapshot` (O(N), дедупликация)
выполняет producer и сюда не входит. Числовые бюджеты R06 и device trace — R12/R15.

## Прогоны

`swift test`, `check_policy.py` (0), `swift format lint`, strict build тестов
(`-warnings-as-errors`), API baseline TrellisCore обновлён с
`--review-note docs/adr/0031-collection-transactions.md`. Полный `check_all.py` по-прежнему
упирается в screenshot gate (дефект #83, вне R11).

## Не закрыто этой карточкой

- Применение `CollectionAdjustment` к native scroll view во время drag/deceleration — R12a,
  с проверкой на Simulator/устройстве.
- `CollectionDelta.apply` ищет ID линейно на каждое изменение — помощник модели, не hot path.
