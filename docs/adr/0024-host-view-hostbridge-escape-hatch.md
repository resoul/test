# ADR 0024 — `TrellisHostView.hostBridge`

Дата: 2026-09-14. Карточка R05 (`docs/implementation-plan-6.md`, внешний consumer).
Зависимость: R04.

## Изменение

`Sources/TrellisAppKit/TrellisHostView.swift` и
`Sources/TrellisUIKit/TrellisHostView.swift` — один новый public property на
каждой платформе, ничего существующего не меняет:

```swift
public var hostBridge: NodeHostBridge? { ensureBridge() }
```

(UIKit's `ensureBridge()` никогда не возвращает `nil`; тип всё равно `Optional`,
чтобы кросс-платформенный код мог написать `host.hostBridge?.bindFlux(...)` один
раз, как уже делает `ScenarioInstance.onAttach: (TrellisHostView, ...)`.)

## Почему это нужно именно сейчас

R05 требует внешнего consumer'а, реально использующего Flux-интеграцию
(`NodeHostBridge.bindFlux`, R03) — не только операторы в unit-тестах. Единственный
существующий способ достать `NodeHostBridge` из смонтированного экрана —
`TrellisHostView.bindState(_:update:)`, который **форвардит** ровно один метод
моста. `bindFlux` — расширение `NodeHostBridge`, объявленное в `TrellisFlux`;
`TrellisAppKit`/`TrellisUIKit` не могут зависеть от `TrellisFlux` (R02's dependency
policy, `Scripts/verify_bootstrap.py`'s `manifest_issues` явно проверяет, что
`TrellisCore`/`TrellisRender`/`TrellisUIKit`/`TrellisAppKit` остаются без Flux) —
то есть у этих модулей нет и не может быть собственного метода-форварда для
`bindFlux` конкретно.

`hostBridge` — единственная точка расширения без cross-module trick: она отдаёт
сам мост, ничего не зная о Flux. Любой будущий модуль (не только `TrellisFlux`),
добавляющий public API поверх `NodeHostBridge`, использует тот же путь — не нужен
отдельный форвардинг-метод в `TrellisAppKit`/`TrellisUIKit` под каждое такое
расширение.

## Почему не форвардинг-метод `bindFlux` прямо в `TrellisHostView`

Потребовал бы `import TrellisFlux` в `TrellisAppKit`/`TrellisUIKit` — прямое
нарушение R02's границы module graph (ADR 0021: "`TrellisCore`/`TrellisRender`/
`TrellisUIKit`/`TrellisAppKit` не меняются и не получают зависимость от Flux").
`hostBridge` не знает про `Flux` вообще — это просто геттер уже существующего
внутреннего типа.

## Владение

Не меняется: `hostBridge` не передаёт владение мостом вызывающему — тот же мост,
которым `TrellisHostView` уже владеет (создаёт лениво через `ensureBridge()`,
разделяемый `bindState`). Вызывающий не должен удерживать возвращённый мост дольше
времени жизни этого view — задокументировано explicitly в doc comment обоих
свойств.

## Решение

Baseline обновлён через `check_api.py --module TrellisAppKit --update --review-note
docs/adr/0024-host-view-hostbridge-escape-hatch.md` и то же для `TrellisUIKit`
(и его `--tvos` проба, если поверхность отличается).
