# ADR 0005 — C18 host views переходят на NodeHostBridge

Дата: 2026-09-10.

## Контекст

C02 временно опубликовала `TrellisHostView.layerRegistry`. После C16/C17 этот
registry больше не является источником истины: `LayerRenderer` bridge владеет
своим private `LayerRegistry`, чтобы удалять только собственные `CALayer`.
Публичный registry на view не получал renderer layers и создавал неверное
впечатление, что пользователь может управлять их жизненным циклом.

## Решение

Удалить `layerRegistry` из UIKit/AppKit `TrellisHostView`. Добавить
`attach(root:)` и `detach()`: view создаёт и владеет `NodeHostBridge`, передаёт
initial bounds/scale/safe area/direction и обновляет его по своему окну/scene.

## Последствия

Это намеренное breaking API-изменение относительно bootstrap surface C02.
Пользователь не должен хранить или удалять native Trellis layers напрямую;
единственная публичная операция host lifecycle — attach/detach root. API
baseline обновлён только после этой ADR.
