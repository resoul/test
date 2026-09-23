# C09 — Единая инвалидация и пакетные мутации

Дата: 2026-09-10. Реализована на `Node` (C08) без хоста/scheduler (C13/C14):
эта карточка строит и проверяет коалесцирующий пинг и причины dirty-состояния,
не реальный snapshot/solve — тех типов ещё нет.

## Что добавлено

- `Sources/TrellisCore/Invalidation.swift`: `DirtyReasons` (`OptionSet`) —
  `.structure`/`.arrangement`/`.geometry`/`.appearance`. `.arrangement`
  зарезервирован для будущего resolver (C21) — так же, как `LogArea`
  перечисляет весь будущий конвейер заранее (C05). `InvalidationTransaction`
  (internal, не public — по духу D10 про `LayoutContext`) — глубина
  вложенности, подавление пинга во время `perform`, один отложенный flush per
  root на выходе из внешней транзакции, включая выход по throw (`defer`).
- `Node` (C09-часть): `structureRevision`/`geometryRevision`/
  `appearanceRevision`, `onInvalidate: (@MainActor (Node, DirtyReasons) -> Void)?`,
  `consumePendingInvalidation()` — дренаж накопленного pending-состояния для
  будущего host/scheduler (C13/C14, другой модуль — поэтому `public`).
- `style`/`appearance` получили `didSet`: равное нормализованное значение —
  no-op (ни revision, ни пинг); разное — печатает `Log.on(.style, "changed"/"no-op", …)`
  и помечает geometry/appearance dirty соответственно.
- `node.style { … }` / `node.appearance { … }` — единственная запись значения
  на ноду (проверено тестом на несколько полей за один вызов): имя метода
  совпадает с именем property (это разрешено Swift — вызов `node.style { }`
  однозначно резолвится в метод, `node.style.x` — в property).
- Дерево: `addSubnode`/`insertSubnode`/`moveSubnode`/`removeFromSupernode`
  помечают `[.structure, .geometry]` на затронутом родителе; geometry
  climbing поднимает `geometryRevision` у всех предков вплоть до текущего
  корня (F01/§3.11 — размер потомка может менять измеренный размер предка).
  `appearance` **не** поднимается по предкам — paint-only изменение не влияет
  на их layout, но пинг всё равно доходит до корня (только там есть host).
- `dispose()` оборачивает каскад в `InvalidationTransaction.perform` — снос
  целого поддерева с несколькими детьми даёт ровно один пинг корню, а не по
  одному на каждый `removeFromSupernode()` внутри каскада.
- `Log.on(.invalidate, "requested"/"dropped", …)` — «requested» при реальной
  доставке пинга хосту, «dropped» когда `onInvalidate == nil` (несмонтированное
  дерево — частая причина «ничего не происходит», по формулировке
  `weave-analysis.md` §6.4).

## Модель коалесации

Каждый узел хранит `pendingReasons`/`pendingOrigin`/`pendingDepth`, но они
осмысленны только на текущем корне — пинг всегда всплывает туда. Переход
"чисто → грязно" на корне даёт ровно один вызов `onInvalidate`; дальнейшие
изменения до `consumePendingInvalidation()` только пополняют `pendingReasons`
(не теряя состояние), не вызывая `onInvalidate` повторно. `origin` — первая
нода, вызвавшая переход; последующие в том же окне не перезаписывают его.

## Осознанно не сделано в этой карточке

- Реального flush/snapshot/solver ещё нет (C12–C14) — `onInvalidate` в тестах
  проверяется через инъекцию closure, а не через настоящий scheduler.
- `.arrangement` причина не используется ни одним call site — резерв под C21.
- `calculatedFrame`/`apply(LayoutResult)` по-прежнему не появились (C11/C14).

## Проверки

`Tests/TrellisCoreTests/InvalidationTests.swift` — 21 тест: одиночная запись,
batch (`style { }`/`appearance { }`), no-op на равном нормализованном
значении, appearance не поднимает geometryRevision предков, structure+geometry
на родителе при add/insert/move/remove, climbing по всем предкам, пинг только
у корня с сохранённым origin, 100 синхронных записей → один пинг,
`consumePendingInvalidation` дренирует и позволяет новый пинг, отсутствие
хоста не роняет процесс, `InvalidationTransaction` — подавление, вложенность,
восстановление после throw, один пинг на каскадный `dispose()`, репарентинг
между двумя деревьями пингует оба корня по разу.

| Проверка | Результат |
|---|---|
| `swift test` (124 теста, включая 21 новый) | PASS |
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `xcrun swift-format lint --strict` | PASS |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/adr/0001-node-style-appearance-didset.md` | UPDATED — `style`/`appearance` помечены `changed` (косметика symbolgraph: `{ get set }` после появления `didSet`), см. ADR 0001 |
| `python3 Scripts/check_all.py` | PASS |

`check_api.py` доработан: ADR ищется по полному пути `--review-note`, а не
только по basename — `docs/adr/…` уже сигнализирует «это ADR», без
переименования файла ради подстроки в имени.

## Не засчитывается этим отчётом

Реальная транзакция резолвера (C21/C23) не написана — только примитив,
который она будет использовать. Инвалидация environment/safe area (C10) и
snapshot (C12) не подключены.
