# ADR 0004 — C14 coordinator API

Дата: 2026-09-10. Статус: принято.

`LayoutScheduler` стал публичным владельцем одного worker на host, но его математический
`LayoutEngine` остаётся internal: внешний registry и выбор engine не появляются. Scheduler
передаёт completion worker-slot, чтобы `RenderCoordinator` сохранял latest host state, а не
очередь immutable snapshots.

`RenderCoordinator` и `HostRenderRequest` живут в TrellisRender. `Node.applyLayoutResult(_:)`
— публичная атомарная граница geometry: она отвергает malformed/incomplete/foreign result до
изменения любого frame. Это аддитивные API; animation, display/raster и layer renderer не
включены и остаются следующими карточками.
