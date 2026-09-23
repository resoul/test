# M03 — Scope intent в pending и commit

Дата: 2026-09-13. Карточка [implementation-plan-5.md](../implementation-plan-5.md)
§5; зависимости M02 и T03–T09 закрыты. Эта карточка реализует только запись и
доставку intent; создание `CAAnimation` остаётся M04.

## 1. Реализация

- `Animation`/`AnimationCurve` — `Sendable, Hashable` value-типы в
  `TrellisCore`: `.none`, `.smooth` (250 ms ease-in-out), linear/easeIn/easeOut/
  easeInOut с `Duration`; неположительная длительность нормализуется в `.none`.
- `Node.animate` открывает синхронный scope внутри существующего
  `InvalidationTransaction`. Корень выдаёт монотонный `sequence`, а
  `notifyPending` отмечает релевантную мутацию **до** clean-to-dirty guard.
  Поэтому новый scope видит изменение даже в уже открытом pending window.
- Pending-запись содержит только `(scopeNodeID, sequence, epoch, animation)`:
  без `Node`, closure, `CALayer` и solver snapshot. No-op и semantic-only closure
  записи не создают. До attach и во время suspend мутации применяются, intent
  не сохраняется.
- Scope разрешается по актуальному дереву: поздно созданный Arrangement wrapper
  входит в область предка, удалённый или ушедший в другой root scope не
  разрешается. На пересечении побеждает наибольший `sequence`.
- `AnimationCommitEnvelope` живёт рядом с `HostRenderRequest`, но не внутри
  него. Обычный layout, same-work, paint/display-only пути публикуют envelope;
  semantic-only публикует пустую metadata и не воспроизводит предыдущую.
- При stale/cancel/retry active intents переносятся отдельно и объединяются по
  `(epoch, sequence)`. Более новый `.none` не теряется. Appearance/display/
  semantic mutation, пришедшая после snapshot, поглощается тем же успешным
  geometry commit, поскольку эти значения читаются live при публикации.

## 2. Детерминированная приёмка

Добавлено 13 тестов:

- `AnimationIntentTests.swift`: value API; mutation до/внутри/после scope;
  nested `.none`; no-op/semantic-only; два root; commit-time scope resolution;
  weak release; deferred Arrangement wrapper; unmounted/suspended поведение.
- `AnimationIntentCommitTests.swift`: два независимых paint-only scope;
  одноразовое потребление и semantic-only; same-work без изменения layout
  identity; controlled retry со старым `.smooth` и новым `.none`; live
  appearance mutation при commit validation; suspend и replacement epochs.

Целевой прогон:

```text
TRELLIS_LOG=off swift test --filter m03_
13 tests passed
```

## 3. Проверки

- `python3 Scripts/check_policy.py` — PASS, 0 diagnostics.
- `TRELLIS_LOG=off swift test --filter m03_` — PASS, 13/13.
- `python3 Scripts/check_api.py --module TrellisCore --update --review-note
  docs/validation/m03-animation-intents.md` — UPDATED, 18 добавленных symbol graph
  записей (`Animation`, `AnimationCurve`, `Node.animate` и синтезированный
  `Hashable`); `changed`/`removed` пусты.
- `TRELLIS_LOG=off python3 Scripts/check_all.py` — PASS: policy и verifier,
  strict format/build/test, external consumer, API baselines включая tvOS,
  52 macOS screenshot scenarios и `TRELLIS_LOG` behavior; итог
  `PASS C03/C04/C05 quality gates`.

Новых дефектов при реализации не найдено.
