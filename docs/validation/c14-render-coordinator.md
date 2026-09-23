# C14 — RenderCoordinator: validation

Дата: 2026-09-10.

`RenderCoordinatorTests` покрывает mounted root → snapshot → scheduler → full geometry
commit, replacement root и reentrant
`onPostCommit` invalidation. Во всех случаях `Node.applyLayoutResult(_:)` сначала сверяет
identity set целого subtree и только затем записывает frame; partial commit невозможен.

Команда: `swift test --filter RenderCoordinatorTests`.

Результат: 3 tests passed. Stale root/content/environment guards проверяются непосредственно
в coordinator до `Node.applyLayoutResult(_:)`; их управляемая completion-матрица расширяется
в C15 вместе с retry/recovery. `onCommitGeometry` оставлен единственной границей подключения
CALayer; сам renderer и его lifecycle относятся к C16.
