# FlexboxEngine против CSS

Эталон: chromium 153.0.8010.12. Допуск: 0.05 pt.
Сгенерировано `CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance` в корне пакета.

| Итог | Кейсов |
|---|---|
| pass | 1021 из 1022 |
| fail | 1 |
| unsupported | 0 |

## По группам

| Группа | pass | fail | unsupported |
|---|---|---|---|
| absolute | 7 | 0 | 0 |
| align-items | 8 | 0 | 0 |
| align-self | 6 | 0 | 0 |
| aspect-ratio | 4 | 0 | 0 |
| auto-min-size | 7 | 0 | 0 |
| baseline | 8 | 0 | 0 |
| basis | 7 | 0 | 0 |
| gap | 6 | 0 | 0 |
| grow | 10 | 0 | 0 |
| image | 28 | 1 | 0 |
| justify-content | 24 | 0 | 0 |
| margin-auto | 4 | 0 | 0 |
| min-max | 8 | 0 | 0 |
| nested | 8 | 0 | 0 |
| order | 2 | 0 | 0 |
| padding-margin | 6 | 0 | 0 |
| percent | 4 | 0 | 0 |
| random | 400 | 0 | 0 |
| random-baseline | 150 | 0 | 0 |
| random-text | 200 | 0 | 0 |
| reduced | 81 | 0 | 0 |
| rtl | 5 | 0 | 0 |
| shrink | 8 | 0 | 0 |
| text | 12 | 0 | 0 |
| wrap | 18 | 0 | 0 |

## Расхождения

- `image/padding` — fail: n1: chromium (0.00, 0.00, 120.00×70.00), engine (0.00, 0.00, 120.00×60.00)
