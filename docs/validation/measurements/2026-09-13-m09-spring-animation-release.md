Дата 2026-09-13T17:54:11Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| deep-local-edit | depth=30, nodes=272, siblings=8 | attach-to-first-commit | 6.791 | 6.791 | 6.791 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-apply-frames | 0.112 | 0.145 | 0.147 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-snapshot | 0.697 | 0.881 | 0.897 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-solve | 0.527 | 0.661 | 0.718 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | single-leaf-edit-to-commit | 5.052 | 6.252 | 6.515 |
| wide-100 | nodes=101 | attach-to-first-commit | 0.941 | 0.941 | 0.941 |
| wide-100 | nodes=101 | geometry-all-nodes-to-commit | 1.048 | 1.099 | 1.112 |
| wide-100 | nodes=101 | paint-only-all-nodes | 0.495 | 0.512 | 0.605 |
| wide-100 | nodes=101 | resize-burst-60-to-commit | 1 | 1 | 1 |
| wide-100 | nodes=101 | resize-to-commit | 0.998 | 1.07 | 1.132 |
| wide-1000 | nodes=1001 | attach-to-first-commit | 15.566 | 15.566 | 15.566 |
| wide-1000 | nodes=1001 | geometry-all-nodes-to-commit | 39.842 | 40.005 | 40.182 |
| wide-1000 | nodes=1001 | paint-only-all-nodes | 26.151 | 26.477 | 26.512 |
| wide-1000 | nodes=1001 | resize-burst-60-to-commit | 39.497 | 39.497 | 39.497 |
| wide-1000 | nodes=1001 | resize-to-commit | 39.15 | 39.458 | 39.699 |
| attach-detach | cycles=20, nodes=1001 | attach-commit-detach | 15.867 | 16.013 | 16.037 |
| state-burst | nodes=1001, sends=1000 | burst-to-commit | 40.045 | 40.309 | 40.339 |
| two-hosts | nodes-per-host=501 | both-hosts-update-to-commit | 19.683 | 19.813 | 19.842 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-cancel-to-worker-exit | 2.564 | 3.199 | 3.199 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-solve-uncancelled | 15.613 | 16.693 | 16.693 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-cancel-to-worker-exit | 1.622 | 1.73 | 1.73 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-solve-uncancelled | 242.38 | 242.644 | 242.644 |
| overflow-chain | siblings=4 | fits-d12-solve | 0.084 | 0.084 | 0.084 |
| overflow-chain | siblings=4 | fits-d16-solve | 0.101 | 0.101 | 0.101 |
| overflow-chain | siblings=4 | fits-d20-solve | 0.119 | 0.119 | 0.119 |
| overflow-chain | siblings=4 | fits-d8-solve | 0.067 | 0.067 | 0.067 |
| overflow-chain | siblings=4 | grow-d12-solve | 0.142 | 0.142 | 0.142 |
| overflow-chain | siblings=4 | grow-d16-solve | 0.185 | 0.185 | 0.185 |
| overflow-chain | siblings=4 | grow-d20-solve | 0.237 | 0.237 | 0.237 |
| overflow-chain | siblings=4 | grow-d8-solve | 0.093 | 0.093 | 0.093 |
| overflow-chain | siblings=4 | shrink-d12-solve | 0.17 | 0.17 | 0.17 |
| overflow-chain | siblings=4 | shrink-d16-solve | 0.251 | 0.251 | 0.251 |
| overflow-chain | siblings=4 | shrink-d20-solve | 0.28 | 0.28 | 0.28 |
| overflow-chain | siblings=4 | shrink-d8-solve | 0.124 | 0.124 | 0.124 |
| overflow-chain | siblings=4 | shrinkAlternating-d12-solve | 0.147 | 0.147 | 0.147 |
| overflow-chain | siblings=4 | shrinkAlternating-d16-solve | 0.197 | 0.197 | 0.197 |
| overflow-chain | siblings=4 | shrinkAlternating-d20-solve | 0.238 | 0.238 | 0.238 |
| overflow-chain | siblings=4 | shrinkAlternating-d8-solve | 0.098 | 0.098 | 0.098 |
| semantics-1000 | controls=1000 | arrow-move-pair | 1.75 | 1.854 | 1.868 |
| semantics-1000 | controls=1000 | attach-to-first-publish | 16.072 | 16.072 | 16.072 |
| semantics-1000 | controls=1000 | geometry-all-to-commit-with-semantics | 40.134 | 40.274 | 40.506 |
| semantics-1000 | controls=1000 | label-burst-all-to-publish | 1.799 | 1.957 | 2.009 |
| semantics-1000 | controls=1000 | modal-open-close | 1.519 | 1.581 | 1.617 |
| semantics-1000 | controls=1000 | tab-1000-moves | 144.439 | 144.439 | 144.439 |
| text-raster-1000 | lines=1000 | copy-1000-to-data | 7.086 | 13 | 13 |
| text-raster-1000 | lines=1000 | rasterize-1000-lines | 73.676 | 76.809 | 76.809 |
| text-list-1000 | rows=1000 | attach-to-first-commit | 104.131 | 104.131 | 104.131 |
| text-list-1000 | rows=1000 | drain-all-artifacts | 46.406 | 46.406 | 46.406 |
| text-list-1000 | rows=1000 | single-row-edit-to-artifact | 124.061 | 124.643 | 124.889 |
| text-paragraph-narrow | characters=5000, columnWidth=160 | attach-to-first-commit | 17.669 | 17.669 | 17.669 |
| text-paragraph-narrow | characters=5000, columnWidth=160 | time-to-artifact | 22.098 | 22.098 | 22.098 |
| text-burst-edits | edits-per-row=3, rows=200 | burst-to-fully-drained | 28.678 | 29.084 | 29.084 |
| text-resize-1000 | rows=1000 | resize-all-to-commit | 132.33 | 132.787 | 136.771 |
| animated-text-list-1000 | rows=1000 | animated-commit-full-list | 161.56 | 162.62 | 162.62 |
| animated-text-list-1000 | rows=1000 | attach-to-first-commit | 107.337 | 107.337 | 107.337 |
| animated-text-list-1000 | rows=1000 | drain-all-artifacts | 45.292 | 45.292 | 45.292 |
| animated-text-list-1000 | rows=1000 | idle-after-animation-settles | 0.469 | 0.473 | 0.473 |
| animated-text-list-1000-spring | rows=1000 | animated-commit-full-list | 162.883 | 163.717 | 163.717 |
| animated-text-list-1000-spring | rows=1000 | attach-to-first-commit | 108.427 | 108.427 | 108.427 |
| animated-text-list-1000-spring | rows=1000 | drain-all-artifacts | 44.79 | 44.79 | 44.79 |
| animated-text-list-1000-spring | rows=1000 | idle-after-animation-settles | 0.459 | 0.466 | 0.466 |
| wrappers-with-layers | cards=300 | attach-to-first-commit | 28.822 | 28.822 | 28.822 |
| wrappers-with-layers | cards=300 | geometry-all-cards-to-commit | 170.106 | 170.494 | 171.152 |
| wrappers-with-layers | cards=300 | renderer-apply-committed | 157.289 | 157.803 | 158.181 |
| wrappers-without-layers | cards=300 | attach-to-first-commit | 19.308 | 19.308 | 19.308 |
| wrappers-without-layers | cards=300 | geometry-all-cards-to-commit | 108.622 | 108.818 | 108.836 |
| wrappers-without-layers | cards=300 | renderer-apply-committed | 99.193 | 99.698 | 99.818 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| deep-local-edit | coalesced=0, committed=21, layers=272, requested=21 | — | — |
| wide-100 | coalesced=20, committed=42, layers=101, requested=42, resize-burst-requests=1, stale=0 | resident-before=14.203, resident-detached=14.625, resident-mounted=14.625 | — |
| wide-1000 | coalesced=20, committed=42, layers=1001, requested=42, resize-burst-requests=1, stale=0 | resident-before=15.969, resident-detached=21.656, resident-mounted=21.609 | — |
| attach-detach | layers-after=0, live-root-after-release=0 | peak=21.75, resident-after=21.719, resident-before=21.656 | — |
| state-burst | committed=21, requested=22, updates-delivered=20, updates-expected=20 | — | — |
| two-hosts | a-committed=21, a-stale=0, b-committed=21, b-stale=0 | — | — |
| cancel-latency | — | — | — |
| overflow-chain | fits-d12-hits=12, fits-d12-lookups=123, fits-d12-max-per-node=2, fits-d12-nodes=62, fits-d12-states=111, fits-d16-hits=16, fits-d16-lookups=163, fits-d16-max-per-node=2, fits-d16-nodes=82, fits-d16-states=147, fits-d20-hits=20, fits-d20-lookups=203, fits-d20-max-per-node=2, fits-d20-nodes=102, fits-d20-states=183, fits-d8-hits=8, fits-d8-lookups=83, fits-d8-max-per-node=2, fits-d8-nodes=42, fits-d8-states=75, grow-d12-hits=135, grow-d12-lookups=270, grow-d12-max-per-node=3, grow-d12-nodes=62, grow-d12-states=135, grow-d16-hits=183, grow-d16-lookups=362, grow-d16-max-per-node=3, grow-d16-nodes=82, grow-d16-states=179, grow-d20-hits=231, grow-d20-lookups=454, grow-d20-max-per-node=3, grow-d20-nodes=102, grow-d20-states=223, grow-d8-hits=87, grow-d8-lookups=178, grow-d8-max-per-node=3, grow-d8-nodes=42, grow-d8-states=91, shrink-d12-hits=180, shrink-d12-lookups=364, shrink-d12-max-per-node=3, shrink-d12-nodes=62, shrink-d12-states=184, shrink-d16-hits=244, shrink-d16-lookups=488, shrink-d16-max-per-node=3, shrink-d16-nodes=82, shrink-d16-states=244, shrink-d20-hits=308, shrink-d20-lookups=612, shrink-d20-max-per-node=3, shrink-d20-nodes=102, shrink-d20-states=304, shrink-d8-hits=116, shrink-d8-lookups=240, shrink-d8-max-per-node=3, shrink-d8-nodes=42, shrink-d8-states=124, shrinkAlternating-d12-hits=73, shrinkAlternating-d12-lookups=262, shrinkAlternating-d12-max-per-node=5, shrinkAlternating-d12-nodes=62, shrinkAlternating-d12-states=189, shrinkAlternating-d16-hits=95, shrinkAlternating-d16-lookups=342, shrinkAlternating-d16-max-per-node=5, shrinkAlternating-d16-nodes=82, shrinkAlternating-d16-states=247, shrinkAlternating-d20-hits=117, shrinkAlternating-d20-lookups=422, shrinkAlternating-d20-max-per-node=5, shrinkAlternating-d20-nodes=102, shrinkAlternating-d20-states=305, shrinkAlternating-d8-hits=41, shrinkAlternating-d8-lookups=161, shrinkAlternating-d8-max-per-node=3, shrinkAlternating-d8-nodes=42, shrinkAlternating-d8-states=120 | — | — |
| semantics-1000 | committed=21, metadata-only-publishes=20, requested-after-bursts=1, semantic-publishes=41, snapshot-records=1004, tree-leaves=1002 | resident-before=56.969, resident-detached=57.516, resident-mounted=57.516 | — |
| text-raster-1000 | bytes-per-copy-sample=84096 | resident-before=359.203, resident-holding-1000-cgimage=363.219, resident-holding-1000-data-copies=367.219 | resident deltas are sequential in one process (allocator noise, not GC-precise); compare deltas against resident-before, not absolute values |
| text-list-1000 | display-cancelled=0, display-completed=1020, display-dropped=0, display-scheduled=1020, display-stale=0, estimated-raster-bytes-rgba=102400000, layers=1001, with-artifact-after-drain=1000 | resident-after-drain=307.469, resident-after-first-commit=276.047, resident-before=274.25, resident-detached=307.75 | — |
| text-paragraph-narrow | estimated-raster-bytes-rgba=10712320, measured-height-points=4184, raster-pixel-height=8369, raster-pixel-width=320 | — | — |
| text-burst-edits | display-completed=1200, display-dropped=0, display-scheduled=1200, raw-edits=3000 | — | — |
| text-resize-1000 | committed=21, display-completed-after-resizes=19000 | — | — |
| animated-text-list-1000 | animated-properties-per-commit=1000, display-cancelled=0, display-completed=1000, display-dropped=0, display-scheduled=1000, layers-after-drain=2001, layout-coalesced=5, layout-committed=1, layout-requested=1, layout-retries=0, scene-ready-after-last-animation=1 | resident-after-animations=310.594, resident-after-drain=309.844, resident-before=308.797, resident-detached=310.609 | — |
| animated-text-list-1000-spring | animated-properties-per-commit=1000, display-cancelled=0, display-completed=1000, display-dropped=0, display-scheduled=1000, layers-after-drain=2001, layout-coalesced=5, layout-committed=1, layout-requested=1, layout-retries=0, scene-ready-after-last-animation=1 | resident-after-animations=310.75, resident-after-drain=310.656, resident-before=310.609, resident-detached=310.75 | — |
| wrappers-with-layers | layers=2401, nodes=2401 | resident-before=311.266, resident-mounted=282.156 | — |
| wrappers-without-layers | layers=1501, nodes=2401 | resident-before=282.234, resident-mounted=282.563 | — |
