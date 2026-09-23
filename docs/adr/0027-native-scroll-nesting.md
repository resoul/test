# ADR 0027 — native nesting for ScrollNode

Дата: 2026-09-17. Карточка: R09, план 6.

## Контекст

R07 materialized every `UIScrollView`/`NSScrollView` as a direct child of the host. That made
one scroll work, but a logical nested `ScrollNode` had no native parent from which a coordinator
could obtain the nearest-to-farthest candidate chain before a gesture moved an offset. Removing a
backing's `CALayer` also did not remove the UIKit/AppKit view from its superview.

## Решение

`NativeScrollBacking` gains three explicit ownership operations:

1. `makeChildBacking(nodeID:)` creates a child in the receiver's native content surface;
2. `setFrame(_:relativeTo:)` receives the parent's root-space content origin, so committed
   Trellis geometry stays root-absolute while the native child frame is content-relative;
3. `dispose()` removes the native view. `LayerRenderer` calls it on stale removal and unmount
   after `removeContentLayer()`.

`LayerRenderer` carries the nearest backing through its tree walk. A nested `ScrollNode` asks
that backing for a child before falling back to the host factory. UIKit now owns a real content
`UIView` below each `UIScrollView`; AppKit uses its existing document view. Ordinary Trellis
layers and nested native view layers share that content surface, so there is still one renderer
and one `NodeID` → layer registry.

## Ограничение R09

This decision supplies the physical parent chain; it does **not** claim that UIKit's built-in
`UIScrollView` pan can be arbitrated before its first offset write. Replacing the recognizer's
delegate is not a safe contract: UIKit may use an internal delegate. `scrollViewDidScroll` is
too late for selecting a gesture owner. R09 therefore leaves native scroll recognition with
UIKit/AppKit and defines scroll-versus-transition ownership from the initial hit route and delta
before arming the transition driver; see [ADR 0029](0029-scroll-gesture-arbitration.md). The
pure arbiter tests define the nested-owner policy. Physical nested-recognizer behavior remains
listed separately in R09's platform evidence matrix.

## Проверка

`test_nestedScrollNodeUsesItsNearestNativeContentSurface` verifies that the renderer asks the
outer backing to materialize the inner one, preserves the inner node's registered layer, and
converts the nested frame from the outer content origin. Existing R07 geometry/hit-test tests
exercise the same root-absolute coordinate path.
