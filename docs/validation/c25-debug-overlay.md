# C25 — DebugOverlay и удобная диагностика

Дата: 2026-09-11.

## Что сделано

`DebugOverlayRenderer` в `TrellisRender` — платформенно-нейтральный CALayer-overlay,
по одной рамке (`CALayer.borderWidth`) и подписи (`CATextLayer`: `NodeID` и размер
`w×h`) на каждую ноду с committed frame. Weave-вариант (`NSView`/`UIView` с `draw(_:)`
и `DebugOverlayEntry`) не переносился: он требовал отдельной view на платформу и
своего списка entries, тогда как Trellis уже имеет один нейтральный `LayerRenderer`,
и overlay сделан в том же ключе.

- **Отдельные owned layers, не влияющие на layout.** Overlay — один контейнерный
  sublayer хоста (`trellis.debug-overlay`) с плоским списком рамок, размещённых по
  root-absolute `calculatedFrame`. Он не зеркалит дерево нод и не касается ни
  `LayerRegistry`, ни snapshot, ни scheduler: включение читает уже committed frames и
  не запрашивает ни layout, ни commit (`committedCount` не меняется).
- **Границы и связь с nodeID.** Подпись `#id w×h`. Ноды под управлением Arrangement
  (`arrangementEffectiveStyle != nil` — `Leaf`'ы владельца, implicit wrapper'ы и сам
  владелец с root-контейнером) обведены оранжевым, остальные — синим: решения
  резолвера видны рядом с ручными.
- **Включение независимо от render.** `NodeHostBridge.isDebugOverlayEnabled` и
  `TrellisHostView.isDebugOverlayEnabled` (AppKit/UIKit) — настройка уровня view,
  переживает `attach`/`detach`; слои снимаются на `detach()` и при выключении, после
  каждого commit overlay перерисовывается, устаревшие рамки удаляются.
- **Порядок отрисовки.** Контейнер держится последним в `sublayers` хоста и с
  `zPosition = 1_000_000`: `CALayer.render(in:)` (экспорт скриншотов) игнорирует
  `zPosition` и рисует по порядку массива.

## Тесты (`Tests/TrellisRenderTests/DebugOverlayTests.swift`)

| Тест | Что подтверждает |
|---|---|
| `outlinesEveryCommittedFrameWithoutChangingLayout` | frames нод и их слоёв до/после включения идентичны; `committedCount` не растёт; по одной рамке на ноду по её frame; `contentsScale` = scale хоста; контейнер — sibling корневого слоя, не внутри него |
| `followsCommitsAndRemovesStaleOutlines` | удалённая нода теряет рамку после следующего commit; изменение ширины отражается в рамке |
| `toggleAndDetachLeaveNoLayersBehind` | выкл → на хосте ни одного overlay-слоя, число sublayers как до включения; двойное вкл → ровно один контейнер; `detach` снимает overlay, настройка сохраняется, повторный `attach` восстанавливает |
| `distinguishesArrangementManagedNodes` | цвет рамки различает ручную ноду и Arrangement-managed (owner и его `Leaf`) |

## Playground

- macOS: чекбокс «🐞 Overlay» в toolbar; iOS: кнопка «🐞» в нижней панели; tvOS:
  стрелки вверх/вниз на пульте. Флаг живёт на `TrellisHostView`, поэтому переключение
  сцен его не сбрасывает.
- `--export-all` теперь пишет каждую сцену дважды: `<name>.png` и `<name>_overlay.png`.
  Overlay-варианты — референсные для `Scripts/check_screenshots.py` наравне с обычными:
  38 файлов. Фиксированная задержка 120 ms перед захватом заменена ожиданием первого
  committed frame корня (+60 ms): на холодном первом запуске после сборки 120 ms не
  хватило, и S15 экспортировался пустым.
- **Известная стоимость:** подписи содержат `NodeID`, а идентификаторы выдаются
  глобально по порядку создания сцен, поэтому добавление одной ноды в S03 меняет `#id`
  во всех последующих overlay-референсах — они перегенерируются одним `--update`, но
  дают шумный бинарный diff. Если станет мешать — публичный сброс аллокатора для
  Playground, отдельным решением.

## Скриншот

`docs/validation/screenshots/S19_MediaPlayer_overlay.png`: корень `#151` синий (ручной),
всё под карточкой `#182` оранжевое; плитки `100×118` с их `.grow(1)`, Overlay-обёртка
аватара `#155 200×200`, подписи размеров совпадают с тем, что промерялось по пикселям в
ходе C24 (см. [analysis-arrangement-effective-style.md](../analysis-arrangement-effective-style.md)).

## Проверки

`swift test` — 275 тестов; `check_all.py` (policy/format/build/tests/consumer/API
baseline `--tvos`/screenshots/log env) — PASS. API baseline обновлён этой запиской:
`added` — `DebugOverlayRenderer`, `NodeHostBridge.isDebugOverlayEnabled`,
`TrellisHostView.isDebugOverlayEnabled` (AppKit и UIKit).

## Дополнение 2026-09-11 — дефекты #11 и #12

По [разбору открытых дефектов](../analysis-open-defects.md):

- **#11 — подписи экспорта не зависят от `NodeID`.** `DebugOverlayLabelStyle`:
  `.runtimeID` (по умолчанию, `#42` — как в логе) и `.treeOrder` (`n7` — позиция ноды в
  preorder-обходе смонтированного дерева, только представление: логи, snapshot, кэш и
  registry слоёв по-прежнему работают с настоящим `NodeID`). Настройка протянута
  `DebugOverlayRenderer.labelStyle` → `NodeHostBridge.debugOverlayLabelStyle` →
  `TrellisHostView.debugOverlayLabelStyle` (AppKit/UIKit); `--export-all` ставит
  `.treeOrder` на время экспорта. Сброс аллокатора `NodeID` отвергнут: он ломает
  контракт уникальности между живыми деревьями (D02). Граница, как и предсказано:
  добавление ноды в *начало* сцены перенумерует остаток этой же сцены; другие сцены не
  меняются. Тест `treeOrderLabelsDoNotDependOnNodeIDs`: одинаковое дерево после посторонних
  аллокаций даёт одинаковые `.treeOrder`-подписи и разные `.runtimeID`.
- **#12 — показанные подписи не пересекаются и не выходят за canvas.**
  `DebugOverlayLabelLayout` — чистая функция над прямоугольниками (без CALayer): порядок
  — глубокие ноды первыми, затем preorder; кандидаты — строки вниз от верхнего левого
  угла рамки, пока помещаются внутри неё, строка над рамкой, остальные углы; сначала
  полный текст, затем одна метка; нет места — текст скрыт, рамка остаётся. Проверка
  пересечений линейная по принятым подписям (O(N²) в худшем случае; overlay —
  диагностика, при необходимости добавить сетку). Тесты
  ([DebugOverlayLabelTests](../../Tests/TrellisRenderTests/DebugOverlayLabelTests.swift)):
  восемь соседних 12-pt нод одной глубины при 1×/2× — все 9 подписей показаны, без
  пересечений, внутри canvas; 20 нод в 90×30 — часть текста скрыта, 21 рамка на месте;
  совпадающие рамки родителя и ребёнка — ребёнок сверху, родитель строкой ниже;
  повторный apply после paint-only коммита даёт те же позиции; длинная метка у края
  canvas — короткий текст. Прежние четыре теста C25 сохранены.
- Overlay-референсы (20 файлов) перегенерированы этой запиской: подписи `n…` вместо
  `#…`, позиции по новому алгоритму; обычные скриншоты не изменились. API baseline:
  добавлены `DebugOverlayLabelStyle`, `DebugOverlayRenderer.labelStyle`,
  `NodeHostBridge.debugOverlayLabelStyle`, `TrellisHostView.debugOverlayLabelStyle`.

## Открыто

- Hover/подсветка выбранной ноды — отдельная функциональность ввода (tap/focus на
  iOS/tvOS), не в этой карточке.
- C30 (layout-only wrapper'ы без CALayer) обязан сохранить возможность показать
  логический контейнер в overlay — сейчас overlay читает `calculatedFrame` ноды, а не
  слой, так что это уже не зависит от наличия CALayer.
