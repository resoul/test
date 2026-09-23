# C10 — Environment, safe area и честный snapshot constraint

Дата: 2026-09-10. Реализована на `Node`/`LayoutStyle` (C07–C09) без
solver/coordinator (C12–C14): `makeLayoutInputSnapshot` строит правильную
входную структуру, но ничего ещё не потребляет её.

## Что добавлено

- `Sources/TrellisCore/Environment.swift`: `EnvironmentKey` (generic
  associated-value протокол), `EnvironmentValues` (sparse `[ObjectIdentifier:
  any Sendable]`, subscript по типу ключа), `EnvironmentSnapshot` (values +
  revision), `EnvironmentScope` (`@MainActor final class`, слабый parent,
  `snapshot` пересчитывается рекурсивно на каждое чтение — кэшировать
  нечего, инвалидировать нечего). `LayoutDirectionKey`/`SafeAreaInsetsKey`
  остаются `private` этому файлу; публичный доступ — через `Node.setLayoutDirection`/
  `setSafeAreaInsets` и через `EnvironmentValues.layoutDirection`/`safeAreaInsets`.
- **Упрощение относительно Weave**: `layoutDirection` — обычное settable
  значение по умолчанию `.leftToRight`, не вычисляется из `Locale` +
  `LayoutDirectionResolver` (список RTL-языков). Полноценная локализация вне
  зависимостей C10 — добавится, когда появится реальная потребность.
- **Переиспользование вместо дублирования**: safe-area insets хранятся как
  уже существующий `DirectionalEdgeInsets` (C06), а не как отдельный
  Weave-подобный `SafeAreaInsets` — те же четыре нормализованных поля.
  `SafeAreaEdges` (`top`/`leading`/`bottom`/`trailing`/`none`/`all`) — новый
  `OptionSet`, аналогичного паттерна с `DirtyReasons` (C09).
- `Node` (C10-часть): `environment`/`environmentSnapshot`/`environmentScope`
  (read), `safeAreaBoundary`/`safeAreaIgnoredEdges` (mutable, `didSet`
  сравнивает с `oldValue` — равное значение не помечает geometry dirty),
  `setEnvironment<Key>`/`setLayoutDirection`/`setSafeAreaInsets`
  (помечают geometry dirty — направление и safe area влияют на layout
  каждого потомка, который их читает), `inheritEnvironment(from:)` и
  `init(environment:)` — присоединение к чужому scope без структурного
  родителя в дереве `Node`.
- `addSubnode`/`insertSubnode`/`removeFromSupernode` теперь дополнительно
  переподключают `node.scope`/`scope` (`reparent(to:)`) — «Reparent
  обновляет scope» из чек-листа получился побочным эффектом уже
  существующих операций дерева, без отдельного механизма.
- `Sources/TrellisCore/Layout/LayoutSnapshot.swift`: `LayoutContentMetrics`
  (`intrinsic`, `firstBaseline?`, фиксированные значения — реального
  контент-измерения нет, N01) и `LayoutInputSnapshot` (`identity`, `style`,
  `content`, `children`, `direction`, `environmentRevision`,
  `contentRevision`) — Sendable/Hashable, без живых `Node`/платформенных
  объектов.
- `Node.makeLayoutInputSnapshot(constraint:)` — публичная точка входа;
  приватная рекурсия чинит баг Weave §3.3/F03: каждый уровень сужает
  constraint из **своего** резолвленного width/height и передаёт **это**
  вниз детям, а не пересылает исходный constraint без изменений через все
  уровни. Тест `test_makeLayoutInputSnapshot_narrowsConstraintFromEachAncestorsOwnResolvedSize`
  ловит именно это: внук получает ширину среднего узла (100), не корня (300).
- Safe area складывается в **копию** style только внутри снимка
  (`snapshotStyle.padding = …`), никогда не пишется в хранимый `node.style.padding`
  — поэтому повторные вызовы `makeLayoutInputSnapshot()` не накапливают
  insets (проверено тестом на двух последовательных вызовах).
- `SizeConstraintAxis.knownValue` — новый helper (`Layout/SizeConstraint.swift`,
  C06-файл): извлекает известную границу `.atMost`/`.exact`, `nil` для
  `.unspecified`. Явно задокументирован как «известное ограничение», не
  финальный размер (F03).

## Осознанно не сделано / открыто

- **Тема как environment-ключ не подключена.** `ThemeColor`/`ThemeColors`/`Theme`
  существуют с C07, но `EnvironmentValues` не получила `ThemeKey`: у типа
  `Theme` нет естественного дефолта — нужно было бы выдумать конкретные
  RGB-значения «дефолтной темы» без реального потребителя (`Fill.theme(_:)`
  ничем не резолвится до C16). Это решение осознанно отложено до появления
  рендерера, а не забыто; чек-лист C10 просил «минимальные цвета темы» —
  здесь остаётся открытым пунктом, а не тихо пропущенным.
- `layoutContentMetrics`/`layoutContentMetrics(for:)` возвращают
  фиксированные значения (`LayoutContentMetrics()`, 0×0, без baseline) —
  ограниченный контракт первого этапа. Зависимая от ширины Text-мера — N01.
- `environmentRevision`/`contentRevision` на `LayoutInputSnapshot` остаются
  двумя параллельными `UInt64` (как и было решено отложить в C06/decisions.md) —
  не вводились отдельные типы ревизий, чтобы не проектировать их раньше
  реального потребителя (C12/C14).
- RTL не резолвится на этапе snapshot: `direction` в снимке — логическое
  значение окружения; физическое leading/trailing → left/right остаётся
  задачей `resolved(for:)`, вызываемой солвером (C12).

## Проверки

`Tests/TrellisCoreTests/EnvironmentTests.swift` (9 тестов: unset key defaults,
override, inheritance, own-overrides-inherited, reparent adopts new parent's
values + advances revision, ancestor change advances descendant revision,
detach-to-nil falls back to defaults) — используют собственный `TestDirectionKey`,
поскольку встроенные ключи `private`.

`Tests/TrellisCoreTests/Layout/LayoutSnapshotTests.swift` (5 тестов):
`LayoutContentMetrics` нормализация baseline, `LayoutInputSnapshot` хранит
конструкторские аргументы.

`Tests/TrellisCoreTests/NodeSnapshotTests.swift` (17 тестов): constraint
narrowing (bug fix), unspecified axis, explicit-size fraction resolution,
safe area на корне/nested boundary/non-boundary/ignored edges/без накопления
при повторном вызове, direction override и наследование потомком, reparent
между двумя деревьями меняет direction на следующем snapshot, detach
возвращает к дефолту, `setSafeAreaInsets`/`setLayoutDirection`/
`safeAreaBoundary` помечают geometry dirty ровно один раз (и не помечают на
равном значении), `inheritEnvironment(from:)`/`init(environment:)` через
`Node.environmentScope`.

| Проверка | Результат |
|---|---|
| `swift test` (155 тестов, включая 31 новый) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/adr/0002-node-init-environment-parameter.md` | UPDATED — новый публичный API; `Node.init` без `environment:` помечен `removed` из-за смены mangled-имени (см. [ADR 0002](../adr/0002-node-init-environment-parameter.md)), существующие вызовы не ломаются (дефолт `nil`) |
| `python3 Scripts/check_all.py` | PASS |

## Не засчитывается этим отчётом

Реальное потребление `LayoutInputSnapshot` солвером — C12. Coordinator,
передающий `constraint` из реальных host bounds, — C14. RTL-резолюция
физических edges — C12 (`resolved(for:)` уже существует с C06, просто не
вызывается на этом этапе).
