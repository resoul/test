# A06 — Semantic tree и reading order

Дата: 2026-09-12. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D40 (semantic boundary), D42, D47 ([decisions.md](../decisions.md)); уточнение
`.contain`+`isElement`+дети — [a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §3.2.
Дефект источника #35 (combine как contain, ignoreSelf с собственным endpoint) закрыт — [defects.md](../defects.md).

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Value-типы | `Sources/TrellisCore/Semantics/AccessibilityTree.swift` | `AccessibilityElement` — id, `frame` (visible AABB, для группы без собственной области — union детей), `isElement` (leaf/group), label/value/hint/identifier, resolved `role` (авторский, иначе `.button` для control, иначе `nil`), `isEnabled`/`isSelected`, `actions` (авторские + implicit `.activate` у control, независимо от enabled), `customActions`, `children`. `AccessibilityTree` — root, scope, mountEpoch, revision, `elements` (верхний уровень), `readingOrder` (только leaves, DFS), `element(for:)`, `count`. Независим от focus и hit-test: строится только из `SemanticSnapshot`. |
| Builder | `AccessibilityTree.build(from:scope:)` | Итеративно по committed pre-order **в обратном порядке** (дети раньше родителей): каждая нода отдаёт родителю список `Contribution(element, priority, order)`; списки детей не копируются повторно, рекурсии по глубине нет (A12). Scope — множество ID поддерева scope, остальное не рассматривается; неизвестный scope — пустое дерево. |
| Политики (D42, §3.2) | `contribute` | `.contain`: есть element-потомки — группа (labelled, если `isElement`/`label`/`role == .group`; иначе прозрачна), нет — leaf при `isElement`, иначе ничего. `.combine`: один leaf без детей; label — свой непустой, иначе непустые labels leaf-потомков через `", "` в reading order; value/hint/role/customActions — свои; actions потомков не сливаются. `.ignoreSelf`: unlabelled группа потомков, сам не endpoint при любом `isElement`. `.hide`: поддерево исключено; focus не затрагивает (D37). Arrangement wrapper и нода без видимой области прозрачны — их видимые потомки остаются (zero-size контейнер не прячет детей). |
| Reading order (D42) | `ordered` | `sortPriority` убыв. среди siblings, tie — committed traversal index; стабильно при reorder, `NodeID` сохраняется. |
| Bridge (D47) | `TrellisRender/NodeHostBridge.swift` | `accessibilityTree` строится после каждого publish (после `engine.apply`, чтобы scope engine был актуален) и при `setFocusScope`; равный контент (elements/scope/epoch) не переопубликовывается и не уведомляет; `onAccessibilityTreeChanged` для адаптеров A09/A10; `detach()` очищает. Общая semantic boundary с focus — тот же `scopeID` engine (A05). |

## Тесты

`swift test --filter a06_` — 11 тестов, все зелёные.

Core (`Tests/TrellisCoreTests/Semantics/AccessibilityTreeTests.swift`, фикстура
`R > card > [title(header), subtitle(text), button(control)]`):

| Тест | Приёмка |
|---|---|
| `a06_containOnANonElementCardIsTransparent` | нефокусируемый text читается; control без роли — `.button`, `[.activate]`; прозрачные root/card |
| `a06_containOnAnElementCardWithChildrenIsALabelledGroup` | §3.2 — группа с label, не второй leaf; без element-потомков — leaf |
| `a06_combineIsOneLeafWithJoinedLabelsAndNoChildActions` | `"Title, Subtitle, Buy"`, детей нет, `.activate` кнопки **не** создан как скрытое действие; явный label/hint/role/customActions родителя |
| `a06_ignoreSelfKeepsTheContainerWithoutAnEndpoint` | группа без label, self не в readingOrder при `isElement == true` |
| `a06_hideRemovesTheSubtreeButNotKeyboardFocus` | пустое дерево; скрытый focusable control остаётся кандидатом focus |
| `a06_fourPoliciesOnOneFixtureGiveFourDifferentTrees` | contain/combine/ignoreSelf/hide на одном fixture — четыре разных дерева, leaves 3/1/3/0 |
| `a06_disabledControlIsReadAndPlainTextIsReadWithoutFocus` | disabled button читается (`isEnabled == false`), text без actions и без focus |
| `a06_sortPriorityOrdersSiblingsAndTiesKeepCommittedOrder` | tie → committed порядок; `moveSubnode` меняет порядок, ID сохраняются |
| `a06_modalScopeConfinesTheTreeAndArrangementWrappersAreTransparent` | modal subtree; wrapper с label прозрачен; неизвестный scope — пусто |
| `a06_nestedPoliciesAndZeroSizedParentsDoNotHideVisibleDescendants` | zero-size родитель не прячет детей; вложенные contain(group) → combine → hide; полностью clipped поддерево исключено без преждевременного отказа по AABB родителя |

Render (`Tests/TrellisRenderTests/SemanticPublishTests.swift`):
`a06_bridgePublishesTheTreeOnCommitScopeChangeAndMetadataOnlyButNotOnEqualContent` —
publish на commit, на metadata-only (value), на смену scope; paint-only/тот же scope —
без публикации; `detach()` → `nil`.

## API baseline

Добавлены `AccessibilityElement`, `AccessibilityTree`, `NodeHostBridge.accessibilityTree`/
`onAccessibilityTreeChanged`; этот отчёт — review note.

## Не входит

Native элементы и уведомления ОС (A09/A10); выполнение действий (A07).
