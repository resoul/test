# C16 — единый CALayer renderer

Дата: 2026-09-10.

`LayerRenderer` — единственная платформо-нейтральная реализация native layer
пути. Он получает только живое MainActor-дерево с уже применёнными frames,
`CALayer` хоста и `HostRenderRequest`; UIKit/AppKit не импортируются.

## Поддержанный срез

- Стабильное соответствие `NodeID → CALayer`, parent-local `bounds`/`position`,
  reparent и порядок owned sibling layers.
- Отключённые implicit actions для обычного geometry и paint-only commit.
- `background`, `border`, `cornerRadius`, `shadow`, `opacity`, `overflow`,
  `zIndex`, `transform` и `contentsScale`. `.scroll` клипует, но не добавляет
  scroll behavior; raster/display/content branches отсутствуют.
- `ThemeKey` и `Theme.defaultValue` разрешают `Fill.theme` без palette/store.
- Cleanup касается только слоёв из `LayerRegistry`; чужой sublayer хоста
  сохраняется.

## Автоматическая приёмка

`LayerRendererTests` на macOS использует голый `CALayer` и проверяет:

1. дерево из четырёх уровней с ненулевым root origin;
2. parent-local geometry, стабильность identity и reparent/reorder;
3. background/border/corner/shadow/presentation, paint-only update и scale 2→3;
4. удаление stale Trellis layer без удаления внешнего host sublayer.

## Проверки

| Команда | Результат |
|---|---|
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `swift test --filter LayerRendererTests` | PASS, 2 tests |
| `python3 Scripts/check_api.py --module TrellisCore --update --review-note docs/validation/c16-layer-renderer.md` | UPDATED, 4 additive symbols (`ThemeKey`, default theme, environment property) |
| `python3 Scripts/check_api.py --module TrellisRender --update --review-note docs/validation/c16-layer-renderer.md` | UPDATED, 8 additive symbols (`LayerRenderer`, paint functions) |
| `python3 Scripts/check_all.py` | PASS |
