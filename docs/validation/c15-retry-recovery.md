# C15 — ограниченный retry и recovery

Дата: 2026-09-10.

`RenderCoordinatorTests.test_renderCoordinator_retryBudgetStopsAndNewStateRecovers`
сначала commit'ит корректный кадр 100×100, затем управляемо отвергает каждый result.
Coordinator выполняет семь повторов и на восьмом failure пишет `retry-exhausted`, не
запускает девятый, сохраняет frame 100×100 и последний корректный result. После новой
внешней invalidation rejection выключается, budget сбрасывается и кадр 300×300 commit'ится.

Отдельный burst-тест отправляет 100×100 → 200×200 → 300×300 в одном MainActor turn:
создаётся один solver request, commit получает 300×300, retry budget остаётся нулевым.
Supersede уже выполняющейся работы идёт через `LayoutScheduler.cancel()` и потому не
попадает в guard-failure path.

Проверка: `swift test --filter RenderCoordinatorTests` — 5 tests passed.
