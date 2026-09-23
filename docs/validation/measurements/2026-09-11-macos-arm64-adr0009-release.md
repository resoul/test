Дата 2026-09-11T09:50:49Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| deep-local-edit | depth=30, nodes=272, siblings=8 | attach-to-first-commit | 5.156 | 5.156 | 5.156 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-apply-frames | 0.039 | 0.043 | 0.046 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-snapshot | 0.437 | 0.465 | 0.531 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-solve | 0.293 | 0.327 | 0.347 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | single-leaf-edit-to-commit | 1.561 | 1.722 | 1.731 |
| wide-100 | nodes=101 | attach-to-first-commit | 1.142 | 1.142 | 1.142 |
| wide-100 | nodes=101 | geometry-all-nodes-to-commit | 0.498 | 0.522 | 0.526 |
| wide-100 | nodes=101 | paint-only-all-nodes | 0.265 | 0.272 | 0.273 |
| wide-100 | nodes=101 | resize-burst-60-to-commit | 0.483 | 0.483 | 0.483 |
| wide-100 | nodes=101 | resize-to-commit | 0.46 | 0.494 | 0.506 |
| wide-1000 | nodes=1001 | attach-to-first-commit | 8.486 | 8.486 | 8.486 |
| wide-1000 | nodes=1001 | geometry-all-nodes-to-commit | 7.633 | 7.82 | 7.837 |
| wide-1000 | nodes=1001 | paint-only-all-nodes | 1.549 | 1.82 | 1.887 |
| wide-1000 | nodes=1001 | resize-burst-60-to-commit | 7.332 | 7.332 | 7.332 |
| wide-1000 | nodes=1001 | resize-to-commit | 7.887 | 10.583 | 12.44 |
| attach-detach | cycles=20, nodes=1001 | attach-commit-detach | 8.895 | 9.238 | 9.252 |
| state-burst | nodes=1001, sends=1000 | burst-to-commit | 7.77 | 7.848 | 7.9 |
| two-hosts | nodes-per-host=501 | both-hosts-update-to-commit | 3.672 | 3.731 | 3.749 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-cancel-to-worker-exit | 2.261 | 2.703 | 2.703 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-solve-uncancelled | 13.981 | 15.179 | 15.179 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-cancel-to-worker-exit | 1.442 | 1.54 | 1.54 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-solve-uncancelled | 120.091 | 160.438 | 160.438 |
| overflow-chain | siblings=4 | fits-d12-solve | 0.075 | 0.075 | 0.075 |
| overflow-chain | siblings=4 | fits-d16-solve | 0.093 | 0.093 | 0.093 |
| overflow-chain | siblings=4 | fits-d20-solve | 0.111 | 0.111 | 0.111 |
| overflow-chain | siblings=4 | fits-d8-solve | 0.055 | 0.055 | 0.055 |
| overflow-chain | siblings=4 | grow-d12-solve | 0.129 | 0.129 | 0.129 |
| overflow-chain | siblings=4 | grow-d16-solve | 0.168 | 0.168 | 0.168 |
| overflow-chain | siblings=4 | grow-d20-solve | 0.219 | 0.219 | 0.219 |
| overflow-chain | siblings=4 | grow-d8-solve | 0.085 | 0.085 | 0.085 |
| overflow-chain | siblings=4 | shrink-d12-solve | 0.155 | 0.155 | 0.155 |
| overflow-chain | siblings=4 | shrink-d16-solve | 0.226 | 0.226 | 0.226 |
| overflow-chain | siblings=4 | shrink-d20-solve | 0.266 | 0.266 | 0.266 |
| overflow-chain | siblings=4 | shrink-d8-solve | 0.115 | 0.115 | 0.115 |
| overflow-chain | siblings=4 | shrinkAlternating-d12-solve | 0.132 | 0.132 | 0.132 |
| overflow-chain | siblings=4 | shrinkAlternating-d16-solve | 0.179 | 0.179 | 0.179 |
| overflow-chain | siblings=4 | shrinkAlternating-d20-solve | 0.216 | 0.216 | 0.216 |
| overflow-chain | siblings=4 | shrinkAlternating-d8-solve | 0.087 | 0.087 | 0.087 |
| wrappers-with-layers | cards=300 | attach-to-first-commit | 17.157 | 17.157 | 17.157 |
| wrappers-with-layers | cards=300 | geometry-all-cards-to-commit | 10.999 | 11.279 | 11.305 |
| wrappers-with-layers | cards=300 | renderer-apply-committed | 3.914 | 4.016 | 4.04 |
| wrappers-without-layers | cards=300 | attach-to-first-commit | 17.047 | 17.047 | 17.047 |
| wrappers-without-layers | cards=300 | geometry-all-cards-to-commit | 9.983 | 35.21 | 53.174 |
| wrappers-without-layers | cards=300 | renderer-apply-committed | 2.834 | 3.098 | 3.56 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| deep-local-edit | coalesced=0, committed=21, layers=272, requested=21 | — | — |
| wide-100 | coalesced=20, committed=42, layers=101, requested=42, resize-burst-requests=1, stale=0 | resident-before=13.094, resident-detached=13.453, resident-mounted=13.453 | — |
| wide-1000 | coalesced=20, committed=42, layers=1001, requested=42, resize-burst-requests=1, stale=0 | resident-before=15.078, resident-detached=18.891, resident-mounted=18.859 | — |
| attach-detach | layers-after=0, live-root-after-release=0 | peak=51.25, resident-after=51.219, resident-before=18.891 | — |
| state-burst | committed=21, requested=22, updates-delivered=20, updates-expected=20 | — | — |
| two-hosts | a-committed=21, a-stale=0, b-committed=21, b-stale=0 | — | — |
| cancel-latency | — | — | — |
| overflow-chain | fits-d12-hits=12, fits-d12-lookups=123, fits-d12-max-per-node=2, fits-d12-nodes=62, fits-d12-states=111, fits-d16-hits=16, fits-d16-lookups=163, fits-d16-max-per-node=2, fits-d16-nodes=82, fits-d16-states=147, fits-d20-hits=20, fits-d20-lookups=203, fits-d20-max-per-node=2, fits-d20-nodes=102, fits-d20-states=183, fits-d8-hits=8, fits-d8-lookups=83, fits-d8-max-per-node=2, fits-d8-nodes=42, fits-d8-states=75, grow-d12-hits=135, grow-d12-lookups=270, grow-d12-max-per-node=3, grow-d12-nodes=62, grow-d12-states=135, grow-d16-hits=183, grow-d16-lookups=362, grow-d16-max-per-node=3, grow-d16-nodes=82, grow-d16-states=179, grow-d20-hits=231, grow-d20-lookups=454, grow-d20-max-per-node=3, grow-d20-nodes=102, grow-d20-states=223, grow-d8-hits=87, grow-d8-lookups=178, grow-d8-max-per-node=3, grow-d8-nodes=42, grow-d8-states=91, shrink-d12-hits=180, shrink-d12-lookups=364, shrink-d12-max-per-node=3, shrink-d12-nodes=62, shrink-d12-states=184, shrink-d16-hits=244, shrink-d16-lookups=488, shrink-d16-max-per-node=3, shrink-d16-nodes=82, shrink-d16-states=244, shrink-d20-hits=308, shrink-d20-lookups=612, shrink-d20-max-per-node=3, shrink-d20-nodes=102, shrink-d20-states=304, shrink-d8-hits=116, shrink-d8-lookups=240, shrink-d8-max-per-node=3, shrink-d8-nodes=42, shrink-d8-states=124, shrinkAlternating-d12-hits=73, shrinkAlternating-d12-lookups=262, shrinkAlternating-d12-max-per-node=5, shrinkAlternating-d12-nodes=62, shrinkAlternating-d12-states=189, shrinkAlternating-d16-hits=95, shrinkAlternating-d16-lookups=342, shrinkAlternating-d16-max-per-node=5, shrinkAlternating-d16-nodes=82, shrinkAlternating-d16-states=247, shrinkAlternating-d20-hits=117, shrinkAlternating-d20-lookups=422, shrinkAlternating-d20-max-per-node=5, shrinkAlternating-d20-nodes=102, shrinkAlternating-d20-states=305, shrinkAlternating-d8-hits=41, shrinkAlternating-d8-lookups=161, shrinkAlternating-d8-max-per-node=3, shrinkAlternating-d8-nodes=42, shrinkAlternating-d8-states=120 | — | — |
| wrappers-with-layers | layers=2401, nodes=2401 | resident-before=95.859, resident-mounted=101.109 | — |
| wrappers-without-layers | layers=1501, nodes=2401 | resident-before=103.641, resident-mounted=92.203 | — |
