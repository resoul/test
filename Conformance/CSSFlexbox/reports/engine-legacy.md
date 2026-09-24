# FlexboxEngine против CSS

Эталон: chromium 141.0.7390.37. Допуск: 0.05 pt.
Сгенерировано `CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance`.

| Итог | Кейсов |
|---|---|
| pass | 107 из 142 |
| fail | 29 |
| unsupported | 6 |

## По группам

| Группа | pass | fail | unsupported |
|---|---|---|---|
| absolute | 4 | 3 | 0 |
| align-items | 8 | 0 | 0 |
| align-self | 6 | 0 | 0 |
| aspect-ratio | 2 | 2 | 0 |
| auto-min-size | 2 | 5 | 0 |
| basis | 7 | 0 | 0 |
| gap | 6 | 0 | 0 |
| grow | 6 | 4 | 0 |
| justify-content | 24 | 0 | 0 |
| margin-auto | 0 | 0 | 4 |
| min-max | 6 | 2 | 0 |
| nested | 8 | 0 | 0 |
| order | 0 | 0 | 2 |
| padding-margin | 2 | 4 | 0 |
| percent | 3 | 1 | 0 |
| rtl | 4 | 1 | 0 |
| shrink | 8 | 0 | 0 |
| wrap | 11 | 7 | 0 |

## Расхождения

- `wrap/wrap-reverse-align-content-flex-start` — fail: n1: chromium (0.00, 280.00, 80.00×20.00), engine (0.00, 60.00, 80.00×20.00); n2: chromium (80.00, 270.00, 80.00×30.00), engine (80.00, 60.00, 80.00×30.00); n3: chromium (0.00, 250.00, 80.00×20.00), engine (0.00, 20.00, 80.00×20.00); n4: chromium (80.00, 230.00, 80.00×40.00), engine (80.00, 20.00, 80.00×40.00); n5: chromium (0.00, 210.00, 80.00×20.00), engine (0.00, 0.00, 80.00×20.00)
- `wrap/wrap-reverse-align-content-flex-end` — fail: n1: chromium (0.00, 70.00, 80.00×20.00), engine (0.00, 270.00, 80.00×20.00); n2: chromium (80.00, 60.00, 80.00×30.00), engine (80.00, 270.00, 80.00×30.00); n3: chromium (0.00, 40.00, 80.00×20.00), engine (0.00, 230.00, 80.00×20.00); n4: chromium (80.00, 20.00, 80.00×40.00), engine (80.00, 230.00, 80.00×40.00); n5: chromium (0.00, 0.00, 80.00×20.00), engine (0.00, 210.00, 80.00×20.00)
- `wrap/wrap-reverse-align-content-center` — fail: n1: chromium (0.00, 175.00, 80.00×20.00), engine (0.00, 165.00, 80.00×20.00); n3: chromium (0.00, 145.00, 80.00×20.00), engine (0.00, 125.00, 80.00×20.00)
- `wrap/wrap-reverse-align-content-stretch` — fail: n1: chromium (0.00, 280.00, 80.00×20.00), engine (0.00, 200.00, 80.00×20.00); n2: chromium (80.00, 270.00, 80.00×30.00), engine (80.00, 200.00, 80.00×30.00); n3: chromium (0.00, 180.00, 80.00×20.00), engine (0.00, 90.00, 80.00×20.00); n4: chromium (80.00, 160.00, 80.00×40.00), engine (80.00, 90.00, 80.00×40.00); n5: chromium (0.00, 70.00, 80.00×20.00), engine (0.00, 0.00, 80.00×20.00)
- `wrap/wrap-reverse-align-content-space-between` — fail: n1: chromium (0.00, 280.00, 80.00×20.00), engine (0.00, 270.00, 80.00×20.00); n3: chromium (0.00, 145.00, 80.00×20.00), engine (0.00, 125.00, 80.00×20.00)
- `wrap/wrap-reverse-align-content-space-around` — fail: n1: chromium (0.00, 245.00, 80.00×20.00), engine (0.00, 235.00, 80.00×20.00); n3: chromium (0.00, 145.00, 80.00×20.00), engine (0.00, 125.00, 80.00×20.00)
- `wrap/wrap-reverse-align-content-space-evenly` — fail: n1: chromium (0.00, 227.50, 80.00×20.00), engine (0.00, 217.50, 80.00×20.00); n3: chromium (0.00, 145.00, 80.00×20.00), engine (0.00, 125.00, 80.00×20.00)
- `grow/clamped-by-max-width` — fail: n2: chromium (50.00, 0.00, 250.00×50.00), engine (50.00, 0.00, 150.00×50.00)
- `grow/clamped-by-max-width-redistributes` — fail: n2: chromium (50.00, 0.00, 125.00×50.00), engine (50.00, 0.00, 100.00×50.00); n3: chromium (175.00, 0.00, 125.00×50.00), engine (150.00, 0.00, 100.00×50.00)
- `grow/fractional` — fail: n1: chromium (0.00, 0.00, 75.00×50.00), engine (0.00, 0.00, 150.00×50.00); n2: chromium (75.00, 0.00, 75.00×50.00), engine (150.00, 0.00, 150.00×50.00)
- `grow/with-margin` — fail: n2: chromium (165.00, 0.00, 135.00×50.00), engine (135.00, 0.00, 135.00×50.00)
- `min-max/min-over-max` — fail: n1: chromium (0.00, 0.00, 100.00×20.00), engine (0.00, 0.00, 60.00×20.00)
- `min-max/stretch-clamped-by-max-height` — fail: n1: chromium (0.00, 0.00, 40.00×60.00), engine (0.00, 0.00, 40.00×100.00)
- `auto-min-size/content-does-not-shrink` — fail: n1: chromium (0.00, 0.00, 80.00×50.00), engine (0.00, 0.00, 50.00×50.00); n2: chromium (80.00, 0.00, 80.00×50.00), engine (50.00, 0.00, 50.00×50.00)
- `auto-min-size/explicit-width-caps-auto-min` — fail: n1: chromium (0.00, 0.00, 50.00×50.00), engine (0.00, 0.00, 38.47×50.00); n2: chromium (50.00, 0.00, 80.00×50.00), engine (38.47, 0.00, 61.53×50.00)
- `auto-min-size/column-content-does-not-shrink` — fail: n1: chromium (0.00, 0.00, 50.00×80.00), engine (0.00, 0.00, 50.00×50.00); n2: chromium (0.00, 80.00, 50.00×80.00), engine (0.00, 50.00, 50.00×50.00)
- `auto-min-size/nested-container-min-content` — fail: n1: chromium (0.00, 0.00, 70.00×50.00), engine (0.00, 0.00, 50.00×50.00); n2: chromium (0.00, 0.00, 70.00×50.00), engine (0.00, 0.00, 50.00×50.00); n3: chromium (70.00, 0.00, 70.00×50.00), engine (50.00, 0.00, 50.00×50.00)
- `auto-min-size/basis-zero-grow-with-content` — fail: n1: chromium (0.00, 0.00, 200.00×50.00), engine (0.00, 0.00, 150.00×50.00); n2: chromium (200.00, 0.00, 100.00×50.00), engine (150.00, 0.00, 150.00×50.00)
- `padding-margin/item-margins-row` — fail: n2: chromium (80.00, 0.00, 50.00×20.00), engine (50.00, 0.00, 50.00×20.00)
- `padding-margin/item-margins-column` — fail: n2: chromium (0.00, 40.00, 50.00×20.00), engine (0.00, 20.00, 50.00×20.00)
- `padding-margin/stretch-with-margin` — fail: n1: chromium (0.00, 10.00, 50.00×70.00), engine (0.00, 10.00, 50.00×100.00)
- `padding-margin/center-with-margin` — fail: n1: chromium (145.00, 40.00, 50.00×20.00), engine (165.00, 40.00, 50.00×20.00)
- `margin-auto/push-right` — unsupported: margin: auto
- `margin-auto/center-both-axes` — unsupported: margin: auto
- `margin-auto/split-space` — unsupported: margin: auto
- `margin-auto/column-push-bottom` — unsupported: margin: auto
- `absolute/left-right-stretch` — fail: n1: chromium (10.00, 0.00, 260.00×30.00), engine (10.00, 0.00, 0.00×30.00)
- `absolute/with-container-padding` — fail: n1: chromium (0.00, 0.00, 40.00×30.00), engine (20.00, 20.00, 40.00×30.00)
- `absolute/static-position-centered` — fail: n1: chromium (130.00, 85.00, 40.00×30.00), engine (0.00, 0.00, 40.00×30.00)
- `aspect-ratio/stretched-cross` — fail: n1: chromium (0.00, 0.00, 100.00×100.00), engine (0.00, 0.00, 0.00×100.00)
- `aspect-ratio/column-width-from-stretch` — fail: n1: chromium (0.00, 0.00, 120.00×60.00), engine (0.00, 0.00, 120.00×0.00)
- `percent/percent-with-padding-parent` — fail: n1: chromium (50.00, 50.00, 100.00×20.00), engine (50.00, 50.00, 100.00×0.00)
- `rtl/padding-margin` — fail: n1: chromium (245.00, 0.00, 40.00×20.00), engine (265.00, 0.00, 40.00×20.00); n2: chromium (170.00, 0.00, 60.00×20.00), engine (190.00, 0.00, 60.00×20.00)
- `order/reorder` — unsupported: order: 2.0
- `order/negative` — unsupported: order: -1.0
