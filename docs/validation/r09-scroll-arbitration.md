# R09 — scroll arbitration

Статус: закрыта, 2026-09-23. Вложенная native-иерархия из R07 остаётся основой: `LayerRenderer`
создаёт child backing внутри content/document surface ближайшего parent
([ADR 0027](../adr/0027-native-scroll-nesting.md)). Публичные delegate-объекты
UIKit/AppKit не заменяются; `didScroll` остаётся каналом публикации offset, а не выбора
владельца.

Политика зафиксирована в [ADR 0029](../adr/0029-scroll-gesture-arbitration.md) и реализована
в `ScrollGestureArbiter`: candidates идут от ближайшего scroll-предка к дальнему,
неподдерживаемая ось/граница/disabled пропускаются до захвата; dominant axis фиксируется
на первом delta. `Decision` возвращает одного owner, offered/consumed/unconsumed delta.
После захвата владелец не меняется, delta не делится между двумя ScrollNode, а momentum
не может выбрать нового владельца. Проверки: ближайший eligible, смена доминирующей оси
после lock, delta у границы, disabled candidate, momentum без владельца и без handoff.

Native transition controllers передают начальную точку и delta в новый координатный overload
`NodeHostBridge.beginTransitionGesture(at:initialDelta:)`. Для presented close разрешён только
вертикальный жест вниз. Bridge проверяет route от hit-ноды к scroll-предкам до arm; если
любой eligible ancestor может потребить content delta, transition остаётся `.presented` и
жест принадлежит native scroll. Если scroll на leading boundary, transition получает жест.
Уже активный native drag/deceleration по-прежнему отвергает обычный
`beginTransitionGesture()`.

Consumer S34 (`Playground/Shared/Scenarios/S34_NestedScrollArticle.swift`) добавляет длинную
статью с горизонтальной галереей четырёх текстовых карточек; она включена в iOS/macOS/tvOS
Playground targets. Новые tests проверяют arbiter и coordinate-aware transition через реальный
`NodeHostBridge` с fake native backing. `swift test --filter r09_` прошёл (5/5), iOS Playground
собрался под iOS Simulator SDK, API baseline TrellisRender обновлён и проверен, policy —
0 diagnostics, `swift-format --strict` и `git diff --check` прошли.

Граница evidence: native nested recognizers в S34 физически в этой сессии не прогонялись.
Этот сценарий доступен как ручная проверка на iPad/macOS/touch hardware; Simulator build не
выдаётся за измерение или проверку на устройстве.

| Платформа | Ввод для S34 | Ожидание ручной проверки | Evidence этой сессии |
|---|---|---|---|
| iPhone/iPad | свайп по галерее, по статье; pull-down у верхней границы с presented transition | ось и nearest eligible scroll сохраняются; движение закрывает переход только у leading boundary | iOS Simulator SDK build; native gesture не запускался |
| macOS/iPad trackpad | горизонтальный rail, вертикальная статья, trackpad momentum | направление остаётся locked; momentum не переходит к другому scroll owner | AppKit package build; физический scroll не запускался |
| tvOS | remote focus/Select по карточкам галереи и статье | native focus reveal остаётся отдельным программным scroll path | S34 target зарегистрирован; tvOS build/input не запускался |
