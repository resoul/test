# C23 — Resolver: identity, style reset и атомарная перестройка

Дата: 2026-09-11. Реализует резолвер, который читает `arrangeSubnodes()`
(C22) и применяет его к живому дереву по контракту C21.

## Что добавлено

- `Sources/TrellisCore/Arrangement/ArrangementResolver.swift`:
  `ArrangementWrapperKey` (`package`, `(structuralPath, containerKind)`,
  D06) и `public func Node.resolveArrangement() -> Bool` — единственная
  публичная точка входа. На момент C23 ничего не вызывало её автоматически —
  автоматический wiring оставался вне карточки; с C32
  ([c32-automatic-arrangement.md](c32-automatic-arrangement.md)) хост резолвит
  сам перед snapshot, а прямой вызов остаётся синхронным путём.
- `Sources/TrellisCore/Node.swift`: `childrenAreArrangementManaged`,
  `arrangementWrapperCache`, `arrangementEffectiveStyle` (с
  `setArrangementEffectiveStyle`, единственный писатель — резолвер) и
  `static Node.isResolving`. `addSubnode`/`insertSubnode`/`moveSubnode`/
  `removeFromSupernode` отклоняют вызов на managed-владельце вне резолвера
  (`reason=arrangement-managed`, D05). `makeLayoutInputSnapshot` берёт
  `arrangementEffectiveStyle ?? style` вместо голого `style` — включая
  ограничение по ширине/высоте для сужения constraint у детей, не только
  padding safe area.

## Порядок resolve (один вызов `resolveArrangement()`)

1. `arrangeSubnodes()` → `nil`: `demanageArrangement()` — если узел уже был
   managed, каждый managed-потомок обходится `teardownManagedSubtree`:
   wrapper disposed (только после того, как **все** его дети уже
   отсоединены), пользовательский Leaf — только `removeFromSupernode`,
   никогда `dispose`. Иначе no-op.
2. Иначе — `lower()` (C22) и валидация **всего** proposal целиком
   (`ArrangementPlan.buildContainer`/`validateLeaf`) до единой мутации:
   duplicate leaf, `Leaf(self)`, cycle (leaf называет предка owner),
   foreign-mounted leaf (текущий `supernode` — не owner и не кэшированный
   wrapper owner'а) — всё по таблице из
   [c21-arrangement-contract.md](c21-arrangement-contract.md). Нарушение
   любого пункта — `nil` план, `Log.on(.arrange, "rejected", …)`, дерево не
   тронуто.
3. Валидный план применяется в одной `InvalidationTransaction`:
   `Node.isResolving = true` на всё время (иначе `insertSubnode`/
   `removeFromSupernode` внутри самого резолвера были бы отклонены тем же
   guard'ом, что блокирует ручную мутацию) → `applyChildren(of:)`
   рекурсивно реконсилирует managed-детей owner'а и каждого wrapper'а →
   `Node.isResolving = false` → `setArrangementContainerStyle(plan.containerStyle)`
   на owner (только теперь, отдельно от рекурсии — см. ниже; с 2026-09-11 effective
   style — производная от placement родителя и собственного container style, см.
   [analysis-arrangement-effective-style.md](../analysis-arrangement-effective-style.md)) →
   `childrenAreArrangementManaged = true`.

## Находка при тестировании: два реальных бага, не только контракт

Первая реализация (`apply(plan:)`, единая рекурсивная функция) падала на
двух собственных тестах:

1. **Grow на wrapper терялся.** `apply(plan:)` одной и той же функцией и
   применяла effective style владельца, и рекурсивно спускалась в детей —
   так что `wrapper.apply(plan: childPlan)` в конце **перезаписывал**
   уже корректно выставленный `wrapper.setArrangementEffectiveStyle(style)`
   (со слитым `.grow(1)` снаружи) стилем `childPlan.ownStyle` (без grow,
   он же не знает про модификатор своего собственного item). Разделено на
   `applyChildren(of:)` — только реконсиляция детей, не трогает **свой**
   стиль — и явную установку стиля вызывающей стороной (родителем — для
   wrapper, `resolveArrangement()` — для owner).
2. **`Node.isResolving` снимался слишком рано.** Он выключался сразу после
   реконсиляции детей текущего уровня, но снос устаревших wrapper'ов
   (`teardownManagedSubtree`, который сам вызывает `removeFromSupernode()`
   на потомках) шёл уже с `isResolving == false` — снятие ребёнка со
   старого wrapper'а отклонялось guard'ом, ребёнок оставался приаттачен, и
   последующий `wrapper.dispose()` каскадно disposed его — ровно то, что
   D05 запрещает. Исправлено: `isResolving` держится на весь путь
   `applyChildren` + снос устаревших wrapper'ов одним блоком в
   `resolveArrangement()`, а не разбросан по отдельным вызовам.

Оба бага всплыли только в тестах C21-сценария (grow на вложенном Column;
смена типа слота с диспоузом старого wrapper'а) — принято как подтверждение,
что эти сценарии стоило тестировать явно, а не только компилировать.

## Overlay

`positionType = .absolute` выставляется на effective style каждого item,
чей родительский контейнер — `.overlay` (без хождения через offset
модификатор — оверлей делает absolute каждого ребёнка безусловно, по
контракту C21). `.offset(...)` модификатор просто копируется в
`style.offsets`; вне Overlay он ни на что не влияет (уже существующий
`FlexboxPlacement` читает `offsets` только при `positionType == .absolute`).

## Проверки

`Tests/TrellisCoreTests/ArrangementResolverTests.swift` — 16 тестов:
корневой контейнер (effective style owner + детей, база не тронута),
вложенный wrapper (свой style + грow снаружи), повторный resolve
неизменного дерева (тот же wrapper, `structureRevision` не растёт),
удаление слота (Leaf отсоединён, не disposed), смена типа на одном пути
(старый wrapper disposed, вложенный Leaf жив и переиспользуется в новом
wrapper), reorder сохраняет `NodeID`, `nil` возвращает в ручной режим без
dispose Leaf (включая повторное использование `addSubnode` после), `nil` на
никогда не managed узле — no-op, duplicate/self/ancestor/foreign-mounted
leaf — отказ без мутации, ручная мутация managed-списка отклоняется для
всех четырёх методов, Overlay дети получают `positionType = .absolute` и
`offsets`, применение — один `onInvalidate` ping, снимок использует
effective style, а не базовый.

| Команда | Результат |
|---|---|
| `swift build` (чистый `.build`) | PASS |
| `swift test` (252 теста, включая 16 новых) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_all.py --skip-api` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c23-arrangement-resolver.md` | UPDATED — `added`: `Node.resolveArrangement()` (только публичный симол; `childrenAreArrangementManaged`/`arrangementWrapperCache`/`arrangementEffectiveStyle`/`Node.isResolving`/`ArrangementWrapperKey` — `package`, не видны в публичном API baseline) |

## Не входит в эту карточку

Автоматический вызов `resolveArrangement()` из scheduler/host (когда именно
структурная/стилевая мутация должна повторно резолвить owner) — не
реализован; вызывающая сторона решает сама, когда резолвить. Полная
эквивалентность geometry между imperative и subclass-путём на реальных
устройствах, а также identity CALayer между проходами — C24.
