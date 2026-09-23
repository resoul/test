# C17 — NodeHostBridge и сквозной CALayer путь

Дата: 2026-09-10.

`NodeHostBridge` владеет одной прикреплённой logical tree, её
`RenderCoordinator` и `LayerRenderer`; `hostLayer` заимствуется слабо. Initial
host state передаётся целиком в `attach`, поэтому первый snapshot не видит
промежуточные bounds/scale/insets/direction.

## Контракт владения

- Root сильно удерживается bridge до `detach`; после detach и отсутствия
  внешних владельцев освобождается.
- Один root разрешён ровно в одном bridge. Второй `attach` возвращает `false`,
  логирует `already-mounted` и ничего не меняет.
- Малый weak `rootOwners` нужен только для этой ownership-проверки. Он не
  хранит node lookup: тот остаётся единственным `LayerRegistry` C16.
- `detach` отменяет scheduler, очищает callback root и удаляет только слои
  текущего renderer. Повторный attach создаёт новый coordinator.

## LayerTreeTests на macOS

`NodeHostBridgeTests` использует голый `CALayer`, без NSView и симулятора:

1. трёхуровневое дерево проходит Node → snapshot → solver → coordinator →
   LayerRenderer и создаёт ожидаемую native hierarchy;
2. attach передаёт initial scale/insets/direction, а две синхронные host
   setters дают один актуальный commit;
3. replacement, запрет второго host, detach и reattach проверены явно;
4. suspend → child mutation + bounds/scale → resume создаёт только latest
   commit, а временный root освобождается после detach.

## Проверки

| Команда | Результат |
|---|---|
| `python3 Scripts/check_policy.py` | PASS, 0 diagnostics |
| `swift test --filter NodeHostBridgeTests` | PASS, 3 tests |
| `python3 Scripts/check_api.py --module TrellisRender --update --review-note docs/validation/c17-node-host-bridge.md` | UPDATED, 10 additive symbols (`NodeHostBridge`) |
| `python3 Scripts/check_all.py` | PASS |
