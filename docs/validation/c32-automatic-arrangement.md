# C32 — Автоматический resolve Arrangement (D13)

Дата: 2026-09-11.

## Что сделано

- **`Node.needsArrangementResolve`** (package) — `true` от создания и после
  `markArrangementDirty()`; снимается любым resolve, включая отклонённый proposal
  (диагностика уже в логе; автор правит описание и помечает снова).
- **`Node.markArrangementDirty()`** (public) — единственный способ сказать «моё
  `arrangeSubnodes()` теперь вернёт другое». Синхронно ничего не резолвит: ставит флаг и
  пингует корень с причиной `.arrangement` — `DirtyReasons.arrangement` получила своего
  первого producer'а (C09). Ни структурные правки под владельцем, ни environment (safe
  area, direction — D03) resolve не запускают.
- **`Node.resolveDirtyArrangements()`** (package) — pre-order обход: владелец, затем
  размещённые им ноды; implicit wrapper'ы пропускаются.
- **`RenderCoordinator.flush()`** зовёт его перед `makeLayoutInputSnapshot` — и до сброса
  `flushScheduled`, чтобы пинги от собственных мутаций резолвера поглощались этим же
  flush, а не планировали второй. Первый flush после attach проходит все ноды дерева
  один раз — так владельцы обнаруживаются без единого ручного вызова; повторный flush
  неизменного дерева не вызывает ни одного `arrangeSubnodes()`.
- **`Node.isArrangementWrapper`** (package) — ставится резолвером на implicit wrapper.
  `resolveArrangement()` на wrapper'е отклоняется (`reason=implicit-wrapper`): его дети
  управляются resolve владельца, а не его собственным, и `nil` из базового
  `arrangeSubnodes()` иначе читался бы как «вернуть детей в ручной режим» — снос
  поддерева владельца. До C32 это была латентная опасность, теперь закрыта и для ручного
  вызова.
- Публичный синхронный `resolveArrangement()` сохранён (тесты эквивалентности, consumer в
  `verify_bootstrap.py`).

## Тесты (`Tests/TrellisRenderTests/AutomaticArrangementTests.swift`)

| Тест | Что подтверждает |
|---|---|
| `firstFlushResolvesEveryOwnerInPreOrderWithoutManualCalls` | до attach ничего не резолвится; после первого commit владелец и вложенный владелец (`Leaf(tile).grow(1)` + свой `Column`) резолвлены по одному разу, плитка несёт placement родителя и свой контейнер (D12); ровно один commit, не пара resolve→commit |
| `unchangedTreeAndEnvironmentChangesNeverReResolve` | правка `style`, safe area и direction дают commit'ы, но ни одного нового `arrangeSubnodes()`; wrapper тот же |
| `markArrangementDirtyReResolvesOnlyThatOwnerOnNextFlush` | синхронно дерево не тронуто; следующий flush перерезолвил только помеченного владельца, снятый `Leaf` потерял placement; один commit |
| `rejectedProposalIsDiagnosedOnceNotEveryFlush` | duplicate `Leaf` → отклонено один раз, дальнейшие flush не повторяют; после исправления + `markArrangementDirty()` — резолв |
| `wrappersAreNeverResolvedAndNodesAddedLaterAreDiscovered` | `wrapper.resolveArrangement()` → `false`, дети на месте; владелец, добавленный в ручную часть дерева позже, подхвачен следующим flush |

## Playground

Ни одна сцена больше не зовёт `resolveArrangement()`: S16–S19 просто добавляют владельца
в дерево (S19 — без ручного порядка для плиток), S15 в сессии зовёт
`markArrangementDirty()`. Скриншоты S15–S19 и их overlay-варианты **побайтно совпали** с
референсами до изменения — автоматический путь даёт ту же геометрию, что ручной.

**S10 переделан** (закрывает открытый пункт из C24): вместо трёх implicit `Column`-обёрток,
которые сцена красила руками через `subnodes[0]` (что требовало ручного resolve и лезло во
внутренности резолвера), — три `S10PaddedLevel: Node`, каждый со своим
`Column(padding: 12) { Leaf(content) }`, вложенные через `Leaf`. Это реальный паттерн
(владелец внутри владельца), которому C32 и нужен; геометрия та же — `S10_Nesting.png`
совпал побайтно, изменился только `S10_Nesting_overlay.png` (порядок создания нод →
другие `#id`, все три уровня теперь оранжевые). Форма с implicit wrapper'ами остаётся
покрытой `ArrangementEquivalenceTests`.

Экспорт: `waitForFirstCommit()` при ожидании периодически возвращает окну key-статус — хост
suspend'ит координатор, пока окно не key, и если другое приложение перехватывало фокус
посреди экспорта, сцена не коммитилась и захватывалась пустой (один такой прогон был
пойман гейтом на S13). Сцена, так и не получившая frame, теперь печатает WARNING.

## Проверки

`swift test` — 280; `check_all.py` — PASS (screenshots: 38 совпали после `--update` только
`S10_Nesting_overlay.png` по этой записке). API baseline: `added` —
`Node.markArrangementDirty()`.

## Открыто

- Нет триггера «structural change под владельцем» — по D13 сознательно; если появится
  keyed API для детей (`Arrangement` без ключей — D06), пересмотреть.
- Resolve сидит в `flush()` координатора, то есть в TrellisRender, а не в bridge, как
  сформулировано в D13: это та же точка «перед snapshot на MainActor», просто на уровень
  ниже (bridge не делает snapshot сам). D13 уточнён.
