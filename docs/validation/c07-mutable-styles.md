# C07 — Mutable LayoutStyle и VisualStyle без Draft

Дата: 2026-09-10. Карточка реализует всю value-type поверхность стилей до
появления `Node` в C08. Методы `Node.style { ... }` и
`Node.appearance { ... }` в C08 будут мутировать копию самого значения и
присваивать её один раз; отдельный `Draft` или `StyleBuildable` не вводится.

## Контракт

- `LayoutStyle` содержит все 23 поля исходного flex-контракта как `public var`
  с дефолтами и явным `public init()`.
- `flexGrow`, `flexShrink`, `gap`, `crossGap` нормализуются в конечное
  неотрицательное значение при каждой записи. Отрицательные, NaN и infinity
  становятся нулём. `aspectRatio` принимает только конечное значение больше
  нуля, иначе становится `nil`.
- `SizeValue` принимает integer/float literals как `.points`; доля остаётся
  явной `.fraction`. Некорректные payload у `.points`/`.fraction` остаются
  представимыми, но `resolved(parent:)` возвращает `nil` — это существующий
  контракт C06.
- `VisualStyle` mutable на верхнем уровне. `cornerRadius` нормализуется и в
  initializer, и при прямой записи. `Border`, `Shadow`, `ThemeColor` остаются
  immutable нормализованными значениями. Перенесены минимальные `ThemeColors`
  и `Theme`, нужные для будущего разрешения `Fill.theme`.
- D04 принят: `Node.style`/`appearance` — пользовательская база. Arrangement
  создаёт отдельную effective-копию только для snapshot и не записывает её
  обратно. Реализация resolver остаётся C21/C23.

## Проверки

Тесты покрывают все дефолты, прямую мутацию, повторную нормализацию,
NaN/infinity, литералы, измерение размеров, transform и visual/theme values.
Внешний consumer создаёт `LayoutStyle()`/`VisualStyle()`, меняет публичные
поля и проверяет нормализацию без `@testable`.

| Проверка | Результат |
|---|---|
| `swift test --disable-sandbox` | PASS, 78 тестов |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c07-mutable-styles.md` | UPDATED, только добавления |
| `python3 Scripts/check_all.py` | PASS |

Инвалидация style/appearance намеренно не проверяется: по приёмке C07 она
начинается после появления `Node` в C08/C09.
