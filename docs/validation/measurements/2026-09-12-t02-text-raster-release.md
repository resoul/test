Дата 2026-09-12T10:08:16Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| text-raster-1000 | lines=1000 | copy-1000-to-data | 9.643 | 13.701 | 13.701 |
| text-raster-1000 | lines=1000 | rasterize-1000-lines | 73.569 | 87.173 | 87.173 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| text-raster-1000 | bytes-per-copy-sample=84096 | resident-before=320.781, resident-holding-1000-cgimage=324.781, resident-holding-1000-data-copies=328.797 | resident deltas are sequential in one process (allocator noise, not GC-precise); compare deltas against resident-before, not absolute values |
