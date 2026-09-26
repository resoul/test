# Flexbox как в CSS

**Статус: согласовано как цель** (P7). План проверки — **предложено**.

## Цель

Раскладка `FlexContainer` совпадает с CSS Flexible Box Layout Module Level 1 (алгоритм §9)
«точь-в-точь». Цель достижима: алгоритм полностью описан спецификацией. Даже Yoga её не
выполняет (`flex-shrink` по умолчанию 0 вместо 1, расхождения с `min-width: auto`), так что
«как в Yoga» — не эталон. Эталон — браузер.

Значения по умолчанию — как в CSS: `flex-shrink: 1`, `flex-basis: auto`,
`align-items: stretch`, `min-width/min-height: auto`.

## Трудные места

| Что | Почему трудно |
|---|---|
| `min-width: auto` (автоматический минимальный размер = min-content) | Самая частая причина «в браузере не так»; без неё длинный текст сжимается иначе |
| Intrinsic-размеры | Измеритель текста должен отдавать min-content (самое длинное слово) и max-content (строка без переноса). В Trellis есть `ContentMeasurer`, ADR 0009 — про max-content; полнота не проверялась |
| `align-items: baseline` | Нужна базовая линия текста от измерителя; column и `wrap-reverse` ведут себя не как row |
| `margin: auto` | Отдельный шаг распределения свободного места |
| `flex-wrap` + `align-content` | Многострочность, растяжение линий |
| `order`, `*-reverse` | Порядок раскладки ≠ порядок в дереве; влияет и на focus/accessibility |
| `aspect-ratio` | Взаимодействие с min/max и stretch |
| Проценты от неопределённого размера | Правила разрешения по спецификации |
| Округление к пикселям | Соседние элементы не должны расходиться на полпикселя |
| `position: absolute` внутри flex | Статическая позиция и insets |

## Как доказывать совпадение

Совпадение — не утверждение, а измерение. Метод Yoga (gentest):

1. Тест-кейс записывается как HTML+CSS с блоками **фиксированного размера** (текст
   исключён: проверяется flex, а не шрифтовые движки).
2. Кейс рендерит настоящий Chromium (в CI-окружении он установлен и доступен через
   Playwright); frame каждого блока снимается через `getBoundingClientRect`.
3. Эталонные frame сохраняются как фикстуры.
4. Тот же кейс, переведённый в дерево `LayoutNode`, прогоняется через движок; frame
   сравниваются с допуском округления.

Набор из сотен таких кейсов и есть определение «как в CSS». Каждое расхождение — либо
исправление движка, либо явно записанное и обоснованное отклонение.

Для intrinsic-размеров текста — отдельный набор с детерминированным тестовым измерителем
(фиксированные min/max-content), чтобы проверять алгоритм, а не CoreText.

## Первый шаг

**Статус: выполнен.** Baseline старого движка:
[expectations/engine-legacy.json](https://github.com/resoul/test/blob/trellis-final/Conformance/CSSFlexbox/expectations/engine-legacy.json),
отчёт — [reports/engine-legacy.md](https://github.com/resoul/test/blob/trellis-final/Conformance/CSSFlexbox/reports/engine-legacy.md):
**107 pass, 29 fail, 6 unsupported из 142.** Все 29 падений покрыты дефектами #95–#106
(шесть не сверенных вручную — остальные варианты `wrap-reverse`, #102).

Сделано: [Conformance/CSSFlexbox](../Conformance/CSSFlexbox/README.md) — 142 кейса в 18
группах, эталонные frame сняты в Chromium 141 (с 2026-09-25 — в Chromium 153), Swift-прогон
`Tests/TrellisCoreTests/Layout/CSSConformanceTests.swift`. Swift-прогон собрался и
отработал на Mac в режиме записи.

Сначала расхождения были сверены по логу для 23 кейсов, затем подтверждены отчётом. Это
расхождения, записанные в [реестр дефектов Trellis](https://github.com/resoul/test/blob/trellis-final/docs/defects.md) как #95–#106: margin в
размещении, stretch без margin и min/max, перераспределение grow после clamp, сумма grow
< 1, `min > max`, автоматический минимальный размер (`min-width: auto`), `wrap-reverse`,
absolute (растяжение `left`+`right`, padding box, статическая позиция), `aspect-ratio`
при stretch, обрезка явного размера. Пробелы словаря (`unsupported`): `margin: auto`,
`order`. Совпадают с Chromium: `justify-content`, `align-items`/`align-self`,
обычный `wrap` с `align-content`, grow/shrink/basis без clamp, gap, проценты, вложенность,
RTL без отступов — и `nested/profile-card` из примеров Espalier.

Итог: по результату решено писать новый движок на основе старого, старый не чинить —
[10-layout-engine.md](10-layout-engine.md).

## Адаптивность в движке

`Breakpoint` и значения `from:` вычисляются движком при расчёте
([04-conditionals-and-responsive.md](04-conditionals-and-responsive.md)). Для движка это
выбор ветки/значения по определённой ширине контейнера перед раскладкой его содержимого;
при неопределённой ширине — ветка `otherwise` и запись в диагностике прохода (см. 04). Это
расширение поверх CSS (аналог container queries), и оно тестируется отдельно от
conformance-набора.
