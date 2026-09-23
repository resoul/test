# ADR 0006 — Flex-линия занимает весь cross-размер определённого frame

Дата: 2026-09-11.

## Контекст

`FlexboxEngine.layoutContainer` (C12, перенос из Weave) растягивал flex-линии до
внутреннего cross-размера контейнера только при явном `style.width`/`height`
(`hasExplicitCrossSize`). Для контейнера с `.auto` по cross-оси cross-размер
единственной линии равнялся `max(cross детей)`, и `alignItems`/`alignSelf:
.center/.end` внутри него не имели пространства для выравнивания, а
`alignItems: .stretch` растягивал детей лишь до самого широкого соседа.

Сценарии S16–S19 (C24) показали, что это ломает практически каждую сцену на
Arrangement: implicit wrapper'ы (`Row`/`Column`/`Overlay`) и корень хоста в
`nativeBounds` всегда `.auto` по cross-оси, а их frame при этом уже определён —
родителем через stretch/grow или самим хостом. Карточка с `alignSelf: .center`
стояла у левого края, stat-колонки с `align: .center` прижимали контент влево,
`Column`-обёртки не растягивались на ширину родителя.

Ни один существующий тест не различал две семантики: все проверки
`alignItems`/`alignContent` задавали явный размер, а единственный тест «без
explicit cross size» использовал frame, равный natural размеру (free = 0).

## Решение

В top-down проходе `frame` всегда определён, поэтому условие
`hasExplicitCrossSize` снято: линии контейнера владеют всем его внутренним
cross-размером, как в CSS Flexbox. Единственная линия занимает его целиком;
`alignContent: .stretch` делит остаток между строками. Если frame равен natural
размеру, свободного места нет и поведение не меняется.

Условие явного размера остаётся в проходе измерения (`measureContainer`), где
оно и определяет natural размер auto-контейнера.

## Последствия

- Семантическое изменение движка, не API: сигнатуры не тронуты.
- Референсные скриншоты S10, S16–S19 перегенерированы; S01–S09, S11–S15 совпали
  побайтно. S10: `Column`-уровни теперь растянуты на ширину родителя (как и
  положено колонке с `alignItems: .stretch`); imperative-двойник S10 в
  Playground и в `ArrangementEquivalenceTests` получил `flexDirection = .column`
  — раньше он был `.row` и совпадал с `Column`-формой только потому, что
  ничего не растягивалось.
- Новые тесты: `test_alignContent_stretch_sharesFrameCrossSpaceWithoutExplicitCrossSize`,
  `test_alignItems_center_usesWholeFrameCrossSizeWithoutExplicitCrossSize`,
  `test_alignSelf_center_inAutoWidthColumnCentersHorizontally`.
