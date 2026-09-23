# ADR 0009 — Basis `auto` — max-content, доступное детям пространство — из собственного размера

Дата: 2026-09-11. Закрывает дефекты #24, #25, #26, #27, #28. Принято по замерам из
[analysis-open-defects.md](../analysis-open-defects.md) §#24 (порядок работы 1–5).

## Контекст

`FlexboxEngine.measure` измерял детей для basis под `.atMost(availableMain)` родителя
(fit-content, наследие Weave), затем — если item вырос или сжался — под `.exact(main)`.
Basis зависел от предложенного числа, поэтому каждый уровень, который затем flex'ился,
порождал для ребёнка второе, другое число: natural под `.atMost(a − pad)` и exact под
`m(a)`. Оба поддерева считались полностью, число различных состояний `(нода, constraint)`
удваивалось на уровень (fixture `overflow-chain`, до правки: `max/node` = 2^depth + 1,
глубина 16 — 509–590 k состояний, 500 ms Release; глубина 300 не завершалась — #24).

Тот же basis давал неверную геометрию. Natural вложенного контейнера с `grow`-детьми под
`.atMost` равен всему предложенному пространству, линия родителя переполняется на размер
соседей, и соседи с явным размером сжимаются: в S19 пилюли `.size(width: 28)` были
22.3 pt, трек 255 pt вместо 244 (#25). Кроме того, доступное детям пространство бралось
только из constraint'а, а не из явного `width`/`height` самой ноды (#26: `Column(height:
50) { Leaf.grow(1) }` под родителем 200 давал лист 200 pt — до ADR 0008 маскировалось
перемером placement под `.exact`), а fraction по cross-оси (и fraction min/max)
резолвился против собственного content-размера ноды (#28: `width: 50%` в column давал
25 %).

CSS Flexbox [§7.2.3](https://www.w3.org/TR/css-flexbox-1/#flex-basis-property) и
[§9.2](https://www.w3.org/TR/css-flexbox-1/#algo-main-item): `flex-basis: auto` при auto
main-размере — `content`, и item измеряется как max-content; grow/shrink распределяют
разницу между суммой basis и доступным main. Процент против неопределённого размера
ведёт себя как `auto`.

## Решение

1. **Basis — max-content.** Дети измеряются под constraint'ом с main-осью `.unspecified`;
   cross-ось — `.atMost(availableCross)` контейнера, как прежде. Ключ natural-измерения
   больше не содержит доступного main, поэтому один и тот же natural результат
   разделяется всеми ветвями; `.exact(main)` после распределения — одна цепочка на
   уровень. Для перпендикулярного ребёнка (row в column) его main-ось — cross-ось
   родителя и остаётся `.atMost`: wrap внутри column по-прежнему переносит по ширине
   column.
2. **Собственный определённый размер — пространство детей.** `availableSpace(input:
   constraint:)`: exact-constraint, иначе явный `width`/`height` (fraction — только при
   известном родителе), прижатый min/max и `.atMost`, в том же порядке, что
   `LayoutStyle.measured`; иначе — известное значение constraint'а. Используется и в
   `measure`, и в placement для `ParentMeasure` (ADR 0008).
3. **Переиспользование natural только без fraction в поддереве.**
   `FlexMeasureResult.dependsOnAvailableSize` — `true`, если нода или кто-то ниже несёт
   `.fraction` в width/height/min/max/flexBasis (собирается снизу вверх бесплатно).
   Max-content измерение такого поддерева резолвило проценты против «ничего»; при
   совпадении natural main с итоговым main (`main == naturalMain`, ADR 0008/#14) оно
   не подменяет `.exact`-проход ни в `resolveLines`, ни в placement — для остальных
   поддеревьев подмена доказуемо эквивалентна (delta = 0, нет wrap, нет grow/shrink).
4. **Fractions против родителя.** `style.measured(parentSize:)` в `measure` получает
   известный размер родителя по каждой оси и только для неизвестной оси — content-размер
   (который затем и остаётся для fraction по неизвестной оси, как раньше).
5. **Вытеснение пакетом.** `FlexMeasureCache` сверх `capacity` снимает старейшую четверть
   за раз вместо `removeFirst()` на каждую запись (#27).

## Последствия

- Число состояний линейно: `overflow-chain` после правки — `max/node` = 3 для shrink и
  grow на всех глубинах; глубина 300 (1502 ноды) — 4.7 ms Release, 4.5 k состояний;
  чередование row/column — 11.5 ms, 11.6 k состояний (`max/node` 14: смена оси даёт новые
  cross-ключи ниже, как и предсказывал разбор; рост медленный, не экспоненциальный).
  Файлы: `measurements/2026-09-11-macos-arm64-defect24-{before,after}-release.*`.
- Семантика basis для auto-детей — max-content вместо fit-content: пропорции shrink при
  переполнении считаются от полного content-размера; вложенный `grow` не сжимает
  соседей; wrapping-ребёнок в row получает basis одной строки и переносится после
  распределения. Все 313 тестов (в т.ч. перенесённые из Weave, equivalence C24 и
  ADR 0006–0008) проходят без изменения ожиданий; новые —
  `FlexboxBasisTests` (#24–#28 и контрпримеры разбора: один ребёнок при `grow = 0`
  остаётся своего размера — покрыто `test_flexboxEngine_growZero_doesNotExpand`).
- Гейт скриншотов: 36 из 40 референсов совпали побайтно; изменились `S19_MediaPlayer`
  (+`_overlay`) — прогресс-бар: пилюли 28 pt, трек 244 pt (было 22.3/255, #25) — и
  `S09_Sizes` (+`_overlay`) — нода `fraction` `width: 50%` в column-корне шириной 688 pt
  теперь 344 pt (было 172 pt: #28, референс C19 принят с ошибкой «на глаз», хотя
  `expected` сцены говорит «fraction resolves from parent»). Референсы обновлены этой
  запиской.
- API (`check_api.py --update --review-note` этой запиской): добавлены
  `FlexMeasureResult.dependsOnAvailableSize`, `FlexMeasureCache.Statistics`,
  `FlexMeasureCache.statistics`; `FlexMeasureResult.init` получил параметр
  `dependsOnAvailableSize` со значением по умолчанию — прежний трёхпараметрный символ
  снят, исходники совместимы.
- Границы: линейность показана для цепочек одной оси и чередующихся; wrap +
  cross-выравнивание + measure из placement могут добавлять состояния (разбор §#24),
  но ни одно из них не зависит от предложенного main. Живого измерения текста нет
  (`LayoutContentMetrics.intrinsic` фиксирован) — контракт max-content для текста
  появится вместе с ним.
