# Разбор: effective style корневого контейнера в `ArrangementResolver`

**Дата:** 2026-09-11  
**Компонент:** `TrellisCore/Arrangement/ArrangementResolver.swift`  
**Контекст:** сценарии S16–S18 (C24) — первые узлы-владельцы Arrangement с собственным
базовым `style` (`width`, `alignSelf`, `padding`), заданным в `init` подкласса.

---

## 1. Где на самом деле был баг

Контракт C21 ([c21-arrangement-contract.md](validation/c21-arrangement-contract.md), таблица
«Корневые формы Arrangement») и D04 однозначны: корневой `Row`/`Column`/`Overlay` описывает
**self**, и его effective style = **база `self.style` + конфигурация контейнера**. Для
вложенного контейнера база — пустой `LayoutStyle()` свежего wrapper'а `Node()`.

Реализация C23 этого не делала. `ArrangementPlan.buildContainer` собирала `ownStyle`
**всегда** из `LayoutStyle()` — она не знала, описывает ли контейнер self или wrapper:

```swift
var ownStyle = LayoutStyle()          // ← база владельца потеряна
ownStyle.flexDirection = …
ownStyle.gap = container.spacing
…
```

а `resolveArrangement()` ставила результат напрямую: `setArrangementEffectiveStyle(plan.ownStyle)`.
Для wrapper'ов это верно, для владельца — нет: `width: 360`, `alignSelf: .center`,
`margin` из `init` подкласса затирались дефолтами (`.auto`, `.auto`, `0`), и карточка
растягивалась на всю ширину хоста.

Тесты C23 бага не ловили: ни один owner в них не задавал базовый `style`.

Второй, той же природы: `descriptor.modifiers` корневого описания игнорировались и для
корневого контейнера (`Column {…}.grow(1)` → `grow` не попадал на self), и для корневого
`Leaf` (`Leaf(x).size(…)` → `size` не попадал на `x`), тогда как внутри контейнера
`makeContainerItem`/`.leaf` их применяли.

## 2. Почему правка в коммите `1bc726c` — костыль

Она лечила симптом на выходе, а не причину на входе: после того как план уже построен
с неправильной базой, `resolveArrangement()` вручную переносила пять полей из
`plan.ownStyle` поверх `self.style`, а `padding` — только если он «не ноль».

- Два разных пути композиции для root и wrapper (wrapper — в `buildContainer`+
  `makeContainerItem`, root — inline в `resolveArrangement()`); любое новое поле контейнера
  пришлось бы помнить в двух местах.
- Эвристика `own.padding != DirectionalEdgeInsets()` смешивала «не задан» и «ноль» и делала
  корневой контейнер несовместимым с вложенным: `Row(padding: .zero)` у wrapper'а давал 0, у
  root — базовый padding владельца.
- `applyModifiers` пришлось открыть (`fileprivate`) ради второго вызова снаружи плана.

## 3. Что сделано

`buildContainer` получает базу и модификаторы и один раз собирает **полный** effective
style описываемой ноды: `base ⊕ поля контейнера ⊕ modifiers`.

- root: `base = owner.style`, `modifiers = descriptor.modifiers`;
- nested: `base = LayoutStyle()`, `modifiers = itemDescriptor.modifiers`.

`resolveArrangement()` снова просто ставит `plan.ownStyle`; `makeContainerItem` больше не
мерджит модификаторы, только помечает `positionType = .absolute` под Overlay. Корневой
`Leaf` использует тот же `leafStyle(node, modifiers)`, что и вложенные.

Правило владения полями (одно для root и wrapper, без «optional»-эвристик):

| Поля | Источник |
|---|---|
| `flexDirection`, `gap`, `justifyContent`, `alignItems`, `padding` | всегда контейнер DSL |
| всё остальное (`width`, `height`, `min/max`, `margin`, `alignSelf`, `flexGrow`, `positionType`, `offsets`, …) | база ноды, поверх — модификаторы |

Следствие для S16–S18: `padding` карточки переехал из `style.padding` в `init` в
`Column(spacing:padding:)` корня — там, где ему и место по контракту. Скриншоты
S10/S15/S16/S17/S18 после исправления совпадают с зафиксированными побайтно.

Альтернатива, которая **не** выбрана: сделать `padding` в `Row`/`Column`/`Overlay`
`Optional` и наследовать базовый padding владельца, когда он не указан. Тогда по той же
логике пришлось бы делать optional `spacing`/`justify`/`align`, что меняет публичный API
C22 и вводит два источника для одного поля. Если такая семантика понадобится — это
отдельное решение в `decisions.md`, а не патч резолвера.

## 4. Второй баг, найденный сценарием S19: два владельца одной ноды

S19_MediaPlayer — первый сценарий, где владелец Arrangement (`TrackTileNode` с собственным
`Column`) сам является `Leaf` внутри `Arrangement` родителя (`Leaf(tile).grow(1)`). Это
обычная композиция компонентов, и она ломалась: у ноды был **один** слот
`arrangementEffectiveStyle`, в который писали два резолвера. Кто резолвится последним, тот
затирает другого: после `tile.resolveArrangement()` пропадал родительский `.grow(1)` (на
скриншоте плитки 96pt вместо 100pt — ширина по контенту), а повторный resolve родителя
затирал бы `flexDirection: .column`/`gap`/`padding` самой плитки. Root-`Leaf` или `nil`
у плитки обнуляли effective целиком, включая родительский placement.

Исправление — хранить на `Node` не вычисленный стиль, а **исходные данные двух владельцев**:

- `arrangementPlacement: ArrangementPlacement?` — что решил родитель про эту ноду как item
  (модификаторы + `.absolute` для Overlay); пишет только родительский resolve, снимается,
  когда нода покидает его managed-поддерево;
- `arrangementContainerStyle: ArrangementContainerStyle?` — что решил собственный корневой
  контейнер (поля контейнера + модификаторы корня); пишет только свой resolve, `nil` для
  root-`Leaf`/`nil`.

`arrangementEffectiveStyle` теперь всегда **производная**:
`LayoutStyle.arrangementEffective(base: style, container:, placement:)` в фиксированном
порядке `base ⊕ container ⊕ rootModifiers ⊕ placement.modifiers ⊕ absolute` — родитель
накладывается последним, как и над базовым `style`. Побочные эффекты того же изменения:

- правка `node.style` под управлением Arrangement сразу отражается в effective (D04:
  «производная от базы», раньше — только при следующем resolve);
- `Leaf`, снятый со слота, больше не уносит с собой устаревший effective (раньше он
  оставался и попал бы в snapshot при ручном `addSubnode` в другое место);
- `ArrangementPlan` больше не считает стили вообще, только собирает данные — `applyModifiers`
  и инлайновые мержи исчезли.

## 5. Что S16–S19 показали про сам движок раскладки (исправлено — [ADR 0006](adr/0006-flex-line-cross-size-fills-definite-frame.md))

На всех четырёх скриншотах карточка с `alignSelf: .center` (S16–S18 — база, S19 — root
`.align(.center)`) стоит у левого края корня, а в S16 содержимое stat-колонок с
`align: .center` прижато влево. Это не resolver: effective style верный (тесты). Причина в
`FlexboxPlacement.layoutContainer`: cross-размер единственной flex-линии берётся как
`max(cross детей)` и растягивается до внутреннего cross-размера контейнера только при
`style.width/height != .auto` (`hasExplicitCrossSize`). Для корня в `nativeBounds` (ширина
от хоста), для любого wrapper'а с `.grow()`/stretch от родителя и вообще для любого
auto-контейнера, чей frame уже определён сверху, линия остаётся узкой — и `alignItems`/
`alignSelf: .center/.end` внутри неё не на что опираться. В CSS single-line контейнер с
определённым cross-размером даёт линии весь cross-размер; `frame` в top-down проходе всегда
определён, так что условие `hasExplicitCrossSize` там лишнее. Условие снято (ADR 0006); из референсных
скриншотов изменились S10 и S16–S19 (S12 не изменился — его frame по cross-оси совпадает с
natural размером), imperative-двойник S10 исправлен на настоящие колонки.

## 6. Тесты

`ArrangementResolverTests.swift`:

- `test_resolve_rootContainer_composesOverOwnerBaseStyleAndAppliesRootModifiers` — падает
  на C23-резолвере (`width`/`alignSelf`/`margin` → `.auto`/`0`, `flexGrow` → `0`).
- `test_resolve_rootContainer_paddingIsOwnedByContainerNotBase` — падает на костыле из
  `1bc726c` (базовый padding просачивался в effective).
- `test_resolve_rootLeaf_appliesModifiersToTheLeafNotSelf` — падает на обоих.
- `test_resolve_nestedOwner_keepsParentPlacementAndOwnContainerInEitherOrder`,
  `test_resolve_nestedOwner_rootLeafOrNilArrangementKeepsParentPlacement`,
  `test_resolve_leafLeavingAnArrangement_dropsItsPlacement`,
  `test_resolve_baseStyleChangeWhileManaged_isReflectedInEffectiveStyle` — §4; первые два и
  последний падают на резолвере с одним слотом effective style.

`check_all.py` (включая `--tvos` API baseline) проходит; публичный API не изменился.
