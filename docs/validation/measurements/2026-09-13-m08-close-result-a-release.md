Дата 2026-09-13T16:19:25Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| deep-local-edit | depth=30, nodes=272, siblings=8 | attach-to-first-commit | 3.962 | 3.962 | 3.962 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-apply-frames | 0.075 | 0.076 | 0.081 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-snapshot | 0.405 | 0.428 | 0.446 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-solve | 0.33 | 0.351 | 0.359 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | single-leaf-edit-to-commit | 4.914 | 5.226 | 5.382 |
| wide-100 | nodes=101 | attach-to-first-commit | 0.942 | 0.942 | 0.942 |
| wide-100 | nodes=101 | geometry-all-nodes-to-commit | 1.049 | 1.142 | 1.147 |
| wide-100 | nodes=101 | paint-only-all-nodes | 0.498 | 0.552 | 0.566 |
| wide-100 | nodes=101 | resize-burst-60-to-commit | 1.004 | 1.004 | 1.004 |
| wide-100 | nodes=101 | resize-to-commit | 1.004 | 1.161 | 1.864 |
| wide-1000 | nodes=1001 | attach-to-first-commit | 15.454 | 15.454 | 15.454 |
| wide-1000 | nodes=1001 | geometry-all-nodes-to-commit | 40.163 | 42.49 | 42.706 |
| wide-1000 | nodes=1001 | paint-only-all-nodes | 26.59 | 27.569 | 27.959 |
| wide-1000 | nodes=1001 | resize-burst-60-to-commit | 39.166 | 39.166 | 39.166 |
| wide-1000 | nodes=1001 | resize-to-commit | 39.206 | 39.43 | 39.578 |
| attach-detach | cycles=20, nodes=1001 | attach-commit-detach | 16.118 | 16.236 | 16.29 |
| state-burst | nodes=1001, sends=1000 | burst-to-commit | 40.179 | 41.176 | 41.253 |
| two-hosts | nodes-per-host=501 | both-hosts-update-to-commit | 19.851 | 20.013 | 20.087 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-cancel-to-worker-exit | 2.554 | 2.922 | 2.922 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-solve-uncancelled | 15.466 | 17.437 | 17.437 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-cancel-to-worker-exit | 1.849 | 1.99 | 1.99 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-solve-uncancelled | 242.238 | 246.807 | 246.807 |
| overflow-chain | siblings=4 | fits-d12-solve | 0.091 | 0.091 | 0.091 |
| overflow-chain | siblings=4 | fits-d16-solve | 0.111 | 0.111 | 0.111 |
| overflow-chain | siblings=4 | fits-d20-solve | 0.131 | 0.131 | 0.131 |
| overflow-chain | siblings=4 | fits-d8-solve | 0.074 | 0.074 | 0.074 |
| overflow-chain | siblings=4 | grow-d12-solve | 0.141 | 0.141 | 0.141 |
| overflow-chain | siblings=4 | grow-d16-solve | 0.235 | 0.235 | 0.235 |
| overflow-chain | siblings=4 | grow-d20-solve | 0.261 | 0.261 | 0.261 |
| overflow-chain | siblings=4 | grow-d8-solve | 0.097 | 0.097 | 0.097 |
| overflow-chain | siblings=4 | shrink-d12-solve | 0.184 | 0.184 | 0.184 |
| overflow-chain | siblings=4 | shrink-d16-solve | 0.26 | 0.26 | 0.26 |
| overflow-chain | siblings=4 | shrink-d20-solve | 0.28 | 0.28 | 0.28 |
| overflow-chain | siblings=4 | shrink-d8-solve | 0.135 | 0.135 | 0.135 |
| overflow-chain | siblings=4 | shrinkAlternating-d12-solve | 0.148 | 0.148 | 0.148 |
| overflow-chain | siblings=4 | shrinkAlternating-d16-solve | 0.199 | 0.199 | 0.199 |
| overflow-chain | siblings=4 | shrinkAlternating-d20-solve | 0.258 | 0.258 | 0.258 |
| overflow-chain | siblings=4 | shrinkAlternating-d8-solve | 0.102 | 0.102 | 0.102 |
| semantics-1000 | controls=1000 | arrow-move-pair | 1.754 | 1.876 | 1.878 |
| semantics-1000 | controls=1000 | attach-to-first-publish | 15.914 | 15.914 | 15.914 |
| semantics-1000 | controls=1000 | geometry-all-to-commit-with-semantics | 40.108 | 40.383 | 40.408 |
| semantics-1000 | controls=1000 | label-burst-all-to-publish | 1.888 | 2.09 | 2.223 |
| semantics-1000 | controls=1000 | modal-open-close | 1.527 | 1.628 | 1.719 |
| semantics-1000 | controls=1000 | tab-1000-moves | 146.813 | 146.813 | 146.813 |
| text-raster-1000 | lines=1000 | copy-1000-to-data | 9.314 | 18.829 | 18.829 |
| text-raster-1000 | lines=1000 | rasterize-1000-lines | 83.29 | 98.077 | 98.077 |
| text-list-1000 | rows=1000 | attach-to-first-commit | 105.41 | 105.41 | 105.41 |
| text-list-1000 | rows=1000 | drain-all-artifacts | 78.003 | 78.003 | 78.003 |
| text-list-1000 | rows=1000 | single-row-edit-to-artifact | 124.942 | 128.125 | 138.131 |
| text-paragraph-narrow | characters=5000, columnWidth=160 | attach-to-first-commit | 18.2 | 18.2 | 18.2 |
| text-paragraph-narrow | characters=5000, columnWidth=160 | time-to-artifact | 22.307 | 22.307 | 22.307 |
| text-burst-edits | edits-per-row=3, rows=200 | burst-to-fully-drained | 29.12 | 29.433 | 29.433 |
| text-resize-1000 | rows=1000 | resize-all-to-commit | 132.091 | 141.983 | 146.278 |
| animated-text-list-1000 | rows=1000 | animated-commit-full-list | 165.426 | 166.214 | 166.214 |
| animated-text-list-1000 | rows=1000 | attach-to-first-commit | 108.747 | 108.747 | 108.747 |
| animated-text-list-1000 | rows=1000 | drain-all-artifacts | 46.04 | 46.04 | 46.04 |
| animated-text-list-1000 | rows=1000 | idle-after-animation-settles | 0.456 | 0.459 | 0.459 |
| wrappers-with-layers | cards=300 | attach-to-first-commit | 29.563 | 29.563 | 29.563 |
| wrappers-with-layers | cards=300 | geometry-all-cards-to-commit | 170.437 | 171.217 | 174.385 |
| wrappers-with-layers | cards=300 | renderer-apply-committed | 157.888 | 162.812 | 203.027 |
| wrappers-without-layers | cards=300 | attach-to-first-commit | 20.101 | 20.101 | 20.101 |
| wrappers-without-layers | cards=300 | geometry-all-cards-to-commit | 109.041 | 112.763 | 116.181 |
| wrappers-without-layers | cards=300 | renderer-apply-committed | 99.515 | 101.197 | 102.243 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| deep-local-edit | coalesced=0, committed=21, layers=272, requested=21 | — | — |
| wide-100 | coalesced=20, committed=42, layers=101, requested=42, resize-burst-requests=1, stale=0 | resident-before=14.219, resident-detached=14.578, resident-mounted=14.578 | — |
| wide-1000 | coalesced=20, committed=42, layers=1001, requested=42, resize-burst-requests=1, stale=0 | resident-before=15.984, resident-detached=21.656, resident-mounted=21.609 | — |
| attach-detach | layers-after=0, live-root-after-release=0 | peak=21.719, resident-after=21.688, resident-before=21.656 | — |
| state-burst | committed=21, requested=22, updates-delivered=20, updates-expected=20 | — | — |
| two-hosts | a-committed=21, a-stale=0, b-committed=21, b-stale=0 | — | — |
| cancel-latency | — | — | — |
| overflow-chain | fits-d12-hits=12, fits-d12-lookups=123, fits-d12-max-per-node=2, fits-d12-nodes=62, fits-d12-states=111, fits-d16-hits=16, fits-d16-lookups=163, fits-d16-max-per-node=2, fits-d16-nodes=82, fits-d16-states=147, fits-d20-hits=20, fits-d20-lookups=203, fits-d20-max-per-node=2, fits-d20-nodes=102, fits-d20-states=183, fits-d8-hits=8, fits-d8-lookups=83, fits-d8-max-per-node=2, fits-d8-nodes=42, fits-d8-states=75, grow-d12-hits=135, grow-d12-lookups=270, grow-d12-max-per-node=3, grow-d12-nodes=62, grow-d12-states=135, grow-d16-hits=183, grow-d16-lookups=362, grow-d16-max-per-node=3, grow-d16-nodes=82, grow-d16-states=179, grow-d20-hits=231, grow-d20-lookups=454, grow-d20-max-per-node=3, grow-d20-nodes=102, grow-d20-states=223, grow-d8-hits=87, grow-d8-lookups=178, grow-d8-max-per-node=3, grow-d8-nodes=42, grow-d8-states=91, shrink-d12-hits=180, shrink-d12-lookups=364, shrink-d12-max-per-node=3, shrink-d12-nodes=62, shrink-d12-states=184, shrink-d16-hits=244, shrink-d16-lookups=488, shrink-d16-max-per-node=3, shrink-d16-nodes=82, shrink-d16-states=244, shrink-d20-hits=308, shrink-d20-lookups=612, shrink-d20-max-per-node=3, shrink-d20-nodes=102, shrink-d20-states=304, shrink-d8-hits=116, shrink-d8-lookups=240, shrink-d8-max-per-node=3, shrink-d8-nodes=42, shrink-d8-states=124, shrinkAlternating-d12-hits=73, shrinkAlternating-d12-lookups=262, shrinkAlternating-d12-max-per-node=5, shrinkAlternating-d12-nodes=62, shrinkAlternating-d12-states=189, shrinkAlternating-d16-hits=95, shrinkAlternating-d16-lookups=342, shrinkAlternating-d16-max-per-node=5, shrinkAlternating-d16-nodes=82, shrinkAlternating-d16-states=247, shrinkAlternating-d20-hits=117, shrinkAlternating-d20-lookups=422, shrinkAlternating-d20-max-per-node=5, shrinkAlternating-d20-nodes=102, shrinkAlternating-d20-states=305, shrinkAlternating-d8-hits=41, shrinkAlternating-d8-lookups=161, shrinkAlternating-d8-max-per-node=3, shrinkAlternating-d8-nodes=42, shrinkAlternating-d8-states=120 | — | — |
| semantics-1000 | committed=21, metadata-only-publishes=20, requested-after-bursts=1, semantic-publishes=41, snapshot-records=1004, tree-leaves=1002 | resident-before=57.016, resident-detached=57.578, resident-mounted=57.578 | — |
| text-raster-1000 | bytes-per-copy-sample=84096 | resident-before=335.922, resident-holding-1000-cgimage=322.109, resident-holding-1000-data-copies=330.656 | resident deltas are sequential in one process (allocator noise, not GC-precise); compare deltas against resident-before, not absolute values |
| text-list-1000 | display-cancelled=0, display-completed=1020, display-dropped=0, display-scheduled=1020, display-stale=0, estimated-raster-bytes-rgba=102400000, layers=1001, with-artifact-after-drain=1000 | resident-after-drain=273.422, resident-after-first-commit=241.547, resident-before=239.453, resident-detached=274.25 | — |
| text-paragraph-narrow | estimated-raster-bytes-rgba=10712320, measured-height-points=4184, raster-pixel-height=8369, raster-pixel-width=320 | — | — |
| text-burst-edits | display-completed=1200, display-dropped=0, display-scheduled=1200, raw-edits=3000 | — | — |
| text-resize-1000 | committed=21, display-completed-after-resizes=19000 | — | — |
| animated-text-list-1000 | animated-properties-per-commit=1000, display-cancelled=0, display-completed=1000, display-dropped=0, display-scheduled=1000, layers-after-drain=2001, layout-coalesced=5, layout-committed=1, layout-requested=1, layout-retries=0, scene-ready-after-last-animation=1 | resident-after-animations=273.594, resident-after-drain=272.656, resident-before=271.516, resident-detached=273.609 | — |
| wrappers-with-layers | layers=2401, nodes=2401 | resident-before=274.453, resident-mounted=247.063 | — |
| wrappers-without-layers | layers=1501, nodes=2401 | resident-before=247.141, resident-mounted=247.531 | — |
