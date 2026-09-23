Дата 2026-09-11T08:30:17Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| deep-local-edit | depth=30, nodes=272, siblings=8 | attach-to-first-commit | 5.214 | 5.214 | 5.214 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-apply-frames | 0.066 | 0.196 | 0.263 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-snapshot | 0.589 | 4.306 | 10.342 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-solve | 0.427 | 7.605 | 14.332 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | single-leaf-edit-to-commit | 1.619 | 1.754 | 1.928 |
| wide-100 | nodes=101 | attach-to-first-commit | 1.536 | 1.536 | 1.536 |
| wide-100 | nodes=101 | geometry-all-nodes-to-commit | 0.51 | 0.534 | 0.555 |
| wide-100 | nodes=101 | paint-only-all-nodes | 0.261 | 0.271 | 0.273 |
| wide-100 | nodes=101 | resize-burst-60-to-commit | 0.384 | 0.384 | 0.384 |
| wide-100 | nodes=101 | resize-to-commit | 0.475 | 0.524 | 0.579 |
| wide-1000 | nodes=1001 | attach-to-first-commit | 8.631 | 8.631 | 8.631 |
| wide-1000 | nodes=1001 | geometry-all-nodes-to-commit | 7.479 | 7.595 | 7.625 |
| wide-1000 | nodes=1001 | paint-only-all-nodes | 1.533 | 1.585 | 1.612 |
| wide-1000 | nodes=1001 | resize-burst-60-to-commit | 7.284 | 7.284 | 7.284 |
| wide-1000 | nodes=1001 | resize-to-commit | 7.217 | 7.276 | 7.298 |
| attach-detach | cycles=20, nodes=1001 | attach-commit-detach | 8.815 | 9.003 | 9.057 |
| state-burst | nodes=1001, sends=1000 | burst-to-commit | 7.685 | 7.818 | 7.851 |
| two-hosts | nodes-per-host=501 | both-hosts-update-to-commit | 3.624 | 3.746 | 3.779 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-cancel-to-worker-exit | 2.203 | 2.353 | 2.353 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | deep-solve-uncancelled | 13.227 | 14.844 | 14.844 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-cancel-to-worker-exit | 1.368 | 1.451 | 1.451 |
| cancel-latency | deep-depth=1500, deep-nodes=7502, wide-items=5000 | wide-single-line-solve-uncancelled | 121.034 | 125.877 | 125.877 |
| wrappers-with-layers | cards=300 | attach-to-first-commit | 19.353 | 19.353 | 19.353 |
| wrappers-with-layers | cards=300 | geometry-all-cards-to-commit | 12.944 | 13.064 | 13.109 |
| wrappers-with-layers | cards=300 | renderer-apply-committed | 3.867 | 4.183 | 4.293 |
| wrappers-without-layers | cards=300 | attach-to-first-commit | 20.365 | 20.365 | 20.365 |
| wrappers-without-layers | cards=300 | geometry-all-cards-to-commit | 12.938 | 13.154 | 13.159 |
| wrappers-without-layers | cards=300 | renderer-apply-committed | 3.163 | 11.565 | 43.688 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| deep-local-edit | coalesced=0, committed=21, layers=272, requested=21 | — | — |
| wide-100 | coalesced=20, committed=42, layers=101, requested=42, resize-burst-requests=1, stale=0 | resident-before=13.406, resident-detached=13.828, resident-mounted=13.828 | — |
| wide-1000 | coalesced=20, committed=42, layers=1001, requested=42, resize-burst-requests=1, stale=0 | resident-before=15.453, resident-detached=18.766, resident-mounted=18.719 | — |
| attach-detach | layers-after=0, live-root-after-release=0 | peak=51.172, resident-after=51.141, resident-before=18.766 | — |
| state-burst | committed=21, requested=22, updates-delivered=20, updates-expected=20 | — | — |
| two-hosts | a-committed=21, a-stale=0, b-committed=21, b-stale=0 | — | — |
| cancel-latency | — | — | — |
| wrappers-with-layers | layers=2401, nodes=2401 | resident-before=66.969, resident-mounted=71.359 | — |
| wrappers-without-layers | layers=1501, nodes=2401 | resident-before=73.891, resident-mounted=74.25 | — |
