# CSS Flexbox conformance

Проверка того, что раскладка совпадает с CSS Flexbox «точь-в-точь» (цель P7 v22,
[06-flexbox-conformance.md](../../v22/docs/06-flexbox-conformance.md)). Эталон —
настоящий Chromium, не чьё-то прочтение спецификации.

## Как устроено

```
generate.cjs            кейсы (JS DSL) → HTML → Chromium → эталонные frame
fixtures/flexbox.json   сгенерированные кейсы + эталон; коммитится, Swift-сторона только читает
expectations/*.json     известный итог каждого кейса для конкретного движка (baseline)
reports/*.md            отчёт последней записи baseline: сводка и все расхождения
```

Swift-прогон: `Tests/TrellisCoreTests/Layout/CSSConformanceTests.swift`. Он строит из
кейса `LayoutInputSnapshot`, раскладывает его через `FlexboxEngine` с frame корня из
Chromium (как хост даёт bounds корню) и сравнивает frame каждой ноды с допуском 0.05 pt.

Итог кейса:

| Итог | Значение |
|---|---|
| `pass` | все frame совпали |
| `fail` | хотя бы один frame отличается — ошибка математики |
| `unsupported` | кейс использует CSS, который движок не может выразить (`margin: auto`, `order`, проценты в отступах) — пробел в словаре стилей, а не ошибка математики |

Тест сравнивает итоги с `expectations/trellis.json` и падает при **любом** изменении:
и при регрессии, и когда кейс начал проходить (тогда baseline надо обновить осознанно).

## Команды

Перегенерировать эталон (нужен Node.js и Playwright с Chromium):

```sh
NODE_PATH="$(npm root -g)" node Conformance/CSSFlexbox/generate.cjs
```

Записать baseline и отчёт для текущего движка:

```sh
TRELLIS_CSS_RECORD=1 swift test --filter cssFlexboxConformance
```

Обычная проверка (входит в `swift test`):

```sh
swift test --filter cssFlexboxConformance
```

## Общие правила кейсов

Одинаковы для HTML-стороны и для движка; причина каждого — в скобках.

- Каждая нода — `display: flex` (каждая нода Trellis — flex-контейнер).
- `box-sizing: border-box` (в движке `width`/`height` включают padding, как в Yoga).
- Каждая нода — `position: relative`, чтобы absolute-ребёнок позиционировался от родителя.
- Текста нет. Лист с содержимым (`content: [w, h]`) в HTML получает жёсткий внутренний
  блок `w×h`, в движке — `LayoutContentMetrics(intrinsic:)`. Проверяется flex, а не
  шрифтовые движки.
- Длины — CSS px = pt; проценты — строки `"50%"`.
- `padding`/`margin`/`top`/`left`/… — физические, как в CSS; для `direction: rtl`
  переводятся в leading/trailing на стороне теста.
- CSS `row-gap`/`column-gap` — физические; на стороне теста становятся `gap` (главная ось)
  и `crossGap` (поперечная) по `flex-direction`.

## Группы

`justify-content`, `align-items`, `align-self`, `wrap`, `grow`, `shrink`, `basis`,
`min-max`, `auto-min-size`, `gap`, `padding-margin`, `margin-auto`, `absolute`,
`aspect-ratio`, `percent`, `nested`, `rtl`, `order`. Всего 142 кейса.

Не покрыто и должно быть добавлено следующими наборами: `align-items: baseline` (нужна
базовая линия от измерителя), intrinsic-размеры с разными min-content/max-content (нужен
детерминированный тестовый измеритель), проценты от неопределённого размера,
`flex-basis: content`, `display: none`.
