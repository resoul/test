# CSS Flexbox conformance

Проверка того, что раскладка совпадает с CSS Flexbox «точь-в-точь» (цель P7 v22,
[06-flexbox-conformance.md](../../v22/docs/06-flexbox-conformance.md)). Эталон —
настоящий Chromium, не чьё-то прочтение спецификации.

## Как устроено

```
generate.cjs            кейсы (JS DSL) → HTML → Chromium → эталонные frame
fixtures/flexbox.json   ручные кейсы + эталон; коммитится, Swift-сторона только читает
fixtures/random.json    400 случайных деревьев (seed 2026) из того же набора свойств
fixtures/text.json      ручные кейсы с «текстом» и выравниванием по базовой линии
fixtures/random-text.json  200 случайных деревьев с текстовыми листьями (seed 7)
fixtures/random-baseline.json  150 случайных деревьев с текстом и `align-items: baseline` (seed 11)
cases/reduced.json      уменьшенные деревья из разбора падений (дефект #118): исходник группы `reduced`
fixtures/reduced.json   они же с эталоном
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

Тест сравнивает итоги с `expectations/engine-legacy.json` и падает при **любом** изменении:
и при регрессии, и когда кейс начал проходить (тогда baseline надо обновить осознанно).

## Команды

Перегенерировать эталон (нужен Node.js и Playwright с Chromium):

```sh
NODE_PATH="$(npm root -g)" node Conformance/CSSFlexbox/generate.cjs
```

Записать baseline и отчёт для текущего движка:

```sh
CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance
```

Обычная проверка (входит в `swift test`):

```sh
swift test --filter cssFlexboxConformance
```

Движок v22 (отдельный пакет, baseline `expectations/engine.json`, отчёт `reports/engine.md`):

```sh
cd v22
swift test --filter cssFlexboxConformance
CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance
```

Прогнать движок v22 на любом файле в формате фикстуры (например, уменьшенных деревьях с
эталоном из браузера) — итог каждого кейса пишется рядом, в `<файл>.engine.json`:

```sh
cd v22
CSS_CONFORMANCE_LAB=/путь/к/кейсам.json swift test --filter cssFlexboxLab
```

## Версии Chromium

Весь набор снят одним Chromium — 153 (2026-09-25, `generate.cjs`). До этого эталоны были
сняты Chromium 141, а `reduced` — Chromium 152 из встроенного браузера приложения. Между 141 и
153 деревья не изменились, а кадры разошлись только в `random/0328` и `random-text/0066` —
новый Chromium раскладывает их иначе; движок v22 совпадает с новым. Смена версии Chromium
может так же сдвинуть отдельные кейсы: такой сдвиг — повод проверить, чей это дефект, а не
ошибка движка по умолчанию.

## Общие правила кейсов

Одинаковы для HTML-стороны и для движка; причина каждого — в скобках.

- Каждая нода — `display: flex` (каждая нода Trellis — flex-контейнер).
- `box-sizing: border-box` (в движке `width`/`height` включают padding, как в Yoga).
- Каждая нода — `position: relative`, чтобы absolute-ребёнок позиционировался от родителя.
- Шрифтов нет. Лист с содержимым (`content: [w, h]`) в HTML получает жёсткий внутренний
  блок `w×h`. Лист с «текстом» (`text: [высота строки, слово, слово, …]`) — обычный блок со
  словами-`inline-block` заданной ширины: Chromium переносит их как текст, а тестовый
  измеритель — так же жадно. Проверяется раскладка, а не шрифтовые движки. Старый движок
  Trellis читает только `flexbox.json`.
- Лист — содержимое, а не контейнер: свойства flex-контейнера (`flex-direction`,
  `justify-content`, `align-items`, `gap`, …) в HTML ему не выставляются — они сдвигали бы
  содержимое внутри листа и с ним базовую линию. Базовая линия слова — его низ.
- Длины — CSS px = pt; проценты — строки `"50%"`.
- `padding`/`margin`/`top`/`left`/… — физические, как в CSS; для `direction: rtl`
  переводятся в leading/trailing на стороне теста.
- CSS `row-gap`/`column-gap` — физические; на стороне теста становятся `gap` (главная ось)
  и `crossGap` (поперечная) по `flex-direction`.

## Группы

`justify-content`, `align-items`, `align-self`, `wrap`, `grow`, `shrink`, `basis`,
`min-max`, `auto-min-size`, `gap`, `padding-margin`, `margin-auto`, `absolute`,
`aspect-ratio`, `percent`, `nested`, `rtl`, `order`. Всего 142 кейса.

Не покрыто и должно быть добавлено следующими наборами: проценты от неопределённого
размера, `flex-basis: content`, `display: none`. Текст и базовая линия — в `text.json`,
`random-text.json`, `random-baseline.json`.

`reduced` — 81 дерево из 2–5 нод: каждое — наименьшее дерево, которое ещё расходилось с
Chromium, найденное уменьшением падающего случайного кейса (убирались ноды и свойства, пока
расхождение оставалось). Имя — `reduced/<исходный кейс>`; дефекты #143–#152.
