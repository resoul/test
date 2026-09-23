Дата 2026-09-14T07:23:48Z · resoul’s MacBook Air · Version 26.4.1 (Build 25E253) · release · TRELLIS_LOG=off · итераций 20

| Fixture | Параметры | Метрика | p50 ms | p95 ms | max ms |
|---|---|---|---|---|---|
| transition-open-close | cycles=20 | attach-to-first-commit | 35.798 | 35.798 | 35.798 |
| transition-open-close | cycles=20 | close-arm | 0 | 0 | 0 |
| transition-open-close | cycles=20 | present-prepare-and-arm | 0.409 | 0.599 | 0.755 |

| Fixture | Счётчики | Память MiB | Заметки |
|---|---|---|---|
| transition-open-close | layers-after-detach=0, layers-during-open-session=5 | resident-after-detach-cleanup=17.859, resident-after-drain=17.391, resident-before=11.031, resident-during-open-session=17.813 | measures synchronous prepare/arm/cleanup cost only, via public API (presentTransition/closeTransition/detach); real animation-completion wall-clock (prepare-to-.presented) could not be measured headlessly on this toolchain — see docs/validation/m14-close-result-b.md |
