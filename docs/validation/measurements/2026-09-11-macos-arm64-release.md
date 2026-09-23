Дата 2026-09-11T03:12:54Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| deep-local-edit | depth=30, nodes=272, siblings=8 | attach-to-first-commit | 10.886 | 10.886 | 10.886 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-apply-frames | 0.048 | 0.066 | 0.074 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-snapshot | 0.483 | 0.791 | 0.859 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | phase-solve | 3.527 | 4.932 | 5.79 |
| deep-local-edit | depth=30, nodes=272, siblings=8 | single-leaf-edit-to-commit | 4.41 | 4.514 | 4.623 |
| wide-100 | nodes=101 | attach-to-first-commit | 0.687 | 0.687 | 0.687 |
| wide-100 | nodes=101 | geometry-all-nodes-to-commit | 0.473 | 0.547 | 0.562 |
| wide-100 | nodes=101 | paint-only-all-nodes | 0.28 | 0.292 | 0.294 |
| wide-100 | nodes=101 | resize-burst-60-to-commit | 0.443 | 0.443 | 0.443 |
| wide-100 | nodes=101 | resize-to-commit | 0.434 | 0.492 | 0.498 |
| wide-1000 | nodes=1001 | attach-to-first-commit | 8.474 | 8.474 | 8.474 |
| wide-1000 | nodes=1001 | geometry-all-nodes-to-commit | 7.711 | 7.877 | 7.981 |
| wide-1000 | nodes=1001 | paint-only-all-nodes | 1.477 | 1.63 | 1.698 |
| wide-1000 | nodes=1001 | resize-burst-60-to-commit | 7.604 | 7.604 | 7.604 |
| wide-1000 | nodes=1001 | resize-to-commit | 7.485 | 7.656 | 8.03 |
| attach-detach | cycles=20, nodes=1001 | attach-commit-detach | 8.909 | 9.01 | 9.092 |
| state-burst | nodes=1001, sends=1000 | burst-to-commit | 7.999 | 8.274 | 8.543 |
| two-hosts | nodes-per-host=501 | both-hosts-update-to-commit | 3.806 | 3.941 | 3.969 |
| cancel-latency | deep-depth=200, deep-nodes=1002, wide-items=5000 | deep-cancel-to-worker-exit | 0.094 | 0.132 | 0.132 |
| cancel-latency | deep-depth=200, deep-nodes=1002, wide-items=5000 | deep-solve-uncancelled | 88.884 | 99.87 | 99.87 |
| cancel-latency | deep-depth=200, deep-nodes=1002, wide-items=5000 | wide-single-line-cancel-to-worker-exit | 0.084 | 0.136 | 0.136 |
| cancel-latency | deep-depth=200, deep-nodes=1002, wide-items=5000 | wide-single-line-solve-uncancelled | 116.305 | 122.436 | 122.436 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| deep-local-edit | coalesced=0, committed=21, layers=272, requested=21 | — | — |
| wide-100 | coalesced=20, committed=42, layers=101, requested=42, resize-burst-requests=1, stale=0 | resident-before=15.703, resident-detached=16.063, resident-mounted=16.063 | — |
| wide-1000 | coalesced=20, committed=42, layers=1001, requested=42, resize-burst-requests=1, stale=0 | resident-before=17.672, resident-detached=19.016, resident-mounted=18.969 | — |
| attach-detach | layers-after=0, live-root-after-release=0 | peak=51.375, resident-after=51.375, resident-before=19.016 | — |
| state-burst | committed=21, requested=22, updates-delivered=20, updates-expected=20 | — | — |
| two-hosts | a-committed=21, a-stale=0, b-committed=21, b-stale=0 | — | — |
| cancel-latency | — | — | — |
