# A03 — Metadata и согласованный committed snapshot

Дата: 2026-09-11. Карточка [implementation-plan-3.md](../implementation-plan-3.md) §5,
решения D36, D37 (частично — eligibility без scope), D41, D46
([decisions.md](../decisions.md)). Контракт — [a01-focus-accessibility-contract.md](a01-focus-accessibility-contract.md) §1.

## Что сделано

| Пункт | Где | Как |
|---|---|---|
| Metadata на `Node` | `Sources/TrellisCore/Semantics/FocusProperties.swift`, `AccessibilityProperties.swift`, `Node.swift` | `Node.focus: FocusProperties`, `Node.accessibility: AccessibilityProperties` — value-типы, `didSet` с equality guard (равное значение — ни ревизии, ни ping); `semanticsRevision` растёт только у самой ноды (как `appearanceRevision`); `markSemanticsDirty()` — третий канал инвалидации, `DirtyReasons.semantics` (`1 << 4`). Внутренние хуки `isEnabledForSemantics`/`isActivatable` для снимка. `LogArea` получил `semantics` и `focus`. |
| `ControlNode.isEnabled` (D41) | `Controls/ControlNode.swift` | Единственный источник enabled: `didSet` сбрасывает `isPressed`/tracked pointer при `false`, помечает semantics и appearance; `pointerDown` на disabled не начинает press, `tapEnded` не активирует. `init` включает `focus.isFocusable = true` (D37: control opt-in по умолчанию). |
| Видимая область (D46) | `HitTesting/HitTest.swift` — `HitTestSnapshot.visibleBounds(of:)`, `intersection(_:_:)`; `boundingBox(of:transformedBy:in:)` стал internal | Та же transform-математика, что и hit-test (ADR 0010): AABB собственного frame через собственный transform, затем по цепочке предков — клип `overflow != .visible` в локальном пространстве предка **до** его transform, затем AABB через transform предка; в конце пересечение с host bounds. `nil` для zero-size, `opacity == 0` на любом уровне цепочки, пустого клипа, не-committed ID. |
| `SemanticSnapshot` (D36) | `Semantics/SemanticSnapshot.swift` | Value-тип без `Node`: `root`, `mountEpoch`, `geometryGeneration` (generation коммита), `revision` (счётчик publish хоста), `bounds`, `order` (committed pre-order), `Record` на каждый committed ID — parent/children/`traversalIndex`/frame/`visibleBounds`/focus/accessibility/`isEnabled`/`isActivatable`/`isArrangementWrapper`, `isFocusCandidate`. `focusCandidates(scope:)` — pre-order кандидаты внутри scope; `isDescendantOrSelf`. Строится итеративно (без рекурсии по глубине) из `HitTestSnapshot` + live metadata; ID, отсутствующий live, берёт metadata из `previous` того же mount — экран его ещё показывает; ID без committed frame не публикуется никогда. `hasSameContent(as:)` — no-op guard для metadata-only. |
| Publish в bridge | `TrellisRender/NodeHostBridge.swift` | `semanticSnapshot` строится в `onCommitGeometry` сразу после `hitTestSnapshot`, в том же синхронном участке — до `onPostCommit` и любого пользовательского callback. `onSemanticsOnly` координатора → metadata-only rebuild по тому же `hitTestSnapshot`; равный контент не публикуется и не уведомляет. `onSemanticsPublished` для адаптеров (A09/A10). Счётчики `semanticPublishCount`, `metadataOnlyPublishCount`; внутренний `layoutSnapshotCount`. `skipsLayoutOnlyWrappers == true` — не публикуется (D32). `detach()` очищает. |
| Semantic-only fast path (D41) | `TrellisRender/RenderCoordinator.swift` | `flush()` перед `resolveDirtyArrangements()` и `makeLayoutInputSnapshot` проверяет `root.pendingInvalidationReasons ⊆ {appearance, semantics}` и равенство всех входов engine последнему commit (content/environment revisions, direction, bounds, scale) — тогда окно drain'ится и вызываются `onPaintOnly`/`onSemanticsOnly` **без** layout snapshot. Прежний same-work путь после snapshot сохранён для остальных случаев. Ping с reasons ⊆ {appearance, semantics} во время активного solve **не** отменяет worker — commit читает live appearance/metadata сам. `onSemanticsOnly` — новый callback. |

## Тесты

`swift test --filter a03_` — 16 тестов, все зелёные; полный набор — 423.

Core (`Tests/TrellisCoreTests/Semantics/SemanticSnapshotTests.swift`):

| Тест | Приёмка |
|---|---|
| `a03_focusAndAccessibilityAreNoOpOnEqualValueAndPingSemanticsOnly` | same value — ноль работ (ни ревизии, ни ping); изменение — один ping `.semantics`, burst коалесцируется, geometry/appearance ревизии не двигаются |
| `a03_sortPriorityNormalizesNonFinite` | non-finite priority → 0 в init и в setter |
| `a03_controlIsEnabledIsTheSingleSourceAndClearsPress` | `isEnabled` — источник `isEnabledForSemantics`; no-op на равном; `[.semantics, .appearance]` на изменении |
| `a03_visibleBoundsFollowsRotationClipOpacityAndZeroSize` | rotation π/2 (h01 §1 #20 → AABB (135, 95, 50, 100)), clip (#17 → (50, 50, 50, 50)), child вне клипующего родителя (#16 → nil), zero size → nil, `opacity 0` предка → nil для поддерева, host bounds режут выступающий узел |
| `a03_visibleBoundsComposesNestedTransformThenClip` | translation родителя двигает ребёнка (#23); клип ромба применяется в локальном пространстве до поворота (#25) — AABB стороны 100√2 |
| `a03_snapshotPublishesCommittedIdentitiesInPreorderWithMetadata` | pre-order/`traversalIndex`, metadata на записях, disabled control и wrapper не кандидаты, `focusCandidates(scope:)`, `isDescendantOrSelf` |
| `a03_snapshotNeverPublishesUncommittedNodesAndKeepsRemovedOnesFromPrevious` | новый child без frame не публикуется; удалённый live, но committed узел сохраняет metadata из `previous`; без `previous` — defaults |

Render (`Tests/TrellisRenderTests/SemanticPublishTests.swift`):

| Тест | Приёмка |
|---|---|
| `a03_commitPublishesSnapshotBeforeExternalCallbacks` | первый commit → снимок с `mountEpoch`, `geometryGeneration == committed`, `onSemanticsPublished` один раз |
| `a03_labelBurstIsOneMetadataOnlyPublishWithNoLayoutWork` | **label burst ×100 — один semantic publish, ноль новых layout snapshots и solve** (`requested` и `layoutSnapshotCount` не растут, `committed == 1`) |
| `a03_sameValueIsZeroWork` | равные label/focus/isEnabled — статистика и счётчики publish не меняются |
| `a03_semanticUpdateDuringSolveIsNotLostAndDoesNotCancelTheSolver` | label меняется между `requested == 2` и commit: `cancelled == 0`, `stale == 0`, commit публикует новый label с новой шириной; повторный metadata-only publish не создаётся (контент равен) |
| `a03_mutationBetweenCommitsNeverPublishesAnUncommittedChild` | новый child с label до commit отсутствует в снимке; после commit — с актуальным frame |
| `a03_paintOnlyDoesNotPublishSemanticsAndGeometryOnlyDoes` | paint-only — coalesced, без publish; geometry-only — новый снимок с новыми frames; оба reason в одном окне — по одному вызову каждого пути, без solve |
| `a03_suspendHoldsMetadataUntilResumeAndResizeRepublishesFrames` | suspend держит metadata; resume — один metadata-only publish; resize — geometry publish без второго metadata-only |
| `a03_rotationAndNestedClipReachThePublishedVisibleBounds` | absolute child, обрезанный клипующим control (20×20), затем rotation π/2 control, обрезанный host bounds — в реальном pipeline |
| `a03_detachClearsAndWrapperlessModePublishesNothing` | `detach()` → `nil`; `skipsLayoutOnlyWrappers` → снимок не публикуется |

## Побочное изменение поведения C29

Paint-only ping (`.appearance`) во время активного solve раньше отменял worker и
перезапускал flush; теперь не отменяет — commit применяет live appearance при
`applyCommitted` независимо. Ни один существующий тест этого не проверял в обратную сторону
(`LoadAndTeardownTests` ожидает `cancelled >= 1` от layout-мутаций и проходит). Зафиксировано
здесь как осознанное следствие D41, а не скрытое.

## API baseline

Добавления (`added`): `FocusDirection`, `FocusProperties`, `AccessibilityRole`,
`AccessibilityChildrenPolicy`, `AccessibilityCustomAction`, `AccessibilityAction`,
`AccessibilityProperties`, `SemanticSnapshot` (+ `Record`), `HitTestSnapshot.visibleBounds(of:)`,
`Node.focus`/`accessibility`/`semanticsRevision`, `ControlNode.isEnabled`,
`DirtyReasons.semantics`, `LogArea.semantics`/`.focus`, `RenderCoordinator.onSemanticsOnly`,
`NodeHostBridge.semanticSnapshot`/`onSemanticsPublished`/`semanticPublishCount`/
`metadataOnlyPublishCount`. Ничего не удалено и не изменено; этот отчёт — review note
обновления baseline.

## Не входит

`FocusEngine`, scope и переходы (A04–A05); `AccessibilityTree` с policies (A06);
события/activation (A07); native proxies (A08–A10).
