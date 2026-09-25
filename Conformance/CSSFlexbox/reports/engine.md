# v22 FlexboxEngine против CSS

Эталон: chromium 141.0.7390.37, chromium 152.0.7977.130. Допуск: 0.05 pt.
Сгенерировано `CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance` в `v22/`.

| Итог | Кейсов |
|---|---|
| pass | 991 из 993 |
| fail | 2 |
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
| justify-content | 24 | 0 | 0 |
| margin-auto | 4 | 0 | 0 |
| min-max | 8 | 0 | 0 |
| nested | 8 | 0 | 0 |
| order | 2 | 0 | 0 |
| padding-margin | 6 | 0 | 0 |
| percent | 4 | 0 | 0 |
| random | 399 | 1 | 0 |
| random-baseline | 150 | 0 | 0 |
| random-text | 199 | 1 | 0 |
| reduced | 81 | 0 | 0 |
| rtl | 5 | 0 | 0 |
| shrink | 8 | 0 | 0 |
| text | 12 | 0 | 0 |
| wrap | 18 | 0 | 0 |

## Расхождения

- `random/0328` — fail: n4: chromium (177.50, 60.00, 17.50×85.00), engine (230.00, 60.00, 15.00×85.00); n5: chromium (137.50, 65.00, 0.00×80.00), engine (135.00, 65.00, 0.00×80.00); n6: chromium (147.50, 60.00, 30.00×85.00), engine (145.00, 60.00, 85.00×85.00)
- `random-text/0066` — fail: n6: chromium (276.00, 24.00, 80.00×23.00), engine (276.00, 24.00, 80.00×80.00); n7: chromium (316.00, 10.50, 40.00×50.00), engine (316.00, 39.00, 40.00×50.00); n8: chromium (276.00, 24.00, 80.00×23.00), engine (276.00, 39.00, 80.00×50.00); n9: chromium (268.00, 24.00, 8.00×23.00), engine (268.00, 24.00, 8.00×80.00)
