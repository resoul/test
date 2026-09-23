# R01 — Flux как фундамент: аудит

Дата: 2026-09-14. R01 выполнена как проверка зависимости. **Flux 1.2.0 не готов
для подключения в R02 без отдельных исправлений #56–#59**. Зелёный audit-run
подтверждает воспроизведение дефектов, а не корректность этих поведений.
TrellisFlux/новая SPM-зависимость не добавлены: это R02. D14/D22 не изменены,
предложения P6 не переведены в принятые D-контракты.

## Проверенный источник

| Поле | Результат |
|---|---|
| Checkout | `../old/flux`, чистый на начало и конец аудита |
| Remote | `https://github.com/resoul/flux.git` (checkout использует SSH origin) |
| Revision | `7e98033b26e793e36f3902fdc073f5d26969f6c6` |
| Release | `1.2.0`; `git ls-remote` подтвердил этот revision у `refs/tags/1.2.0` |
| Локальные теги | 1.0.0, 1.0.1, 1.1.0; локального 1.2.0 нет |
| Weave | `Package.resolved` закрепляет 1.2.0 на том же revision; Weave не менялся |
| Лицензия | MIT, Copyright (c) 2026 resoul; LICENSE присутствует в git archive |
| Manifest | tools 5.9, language versions 5 и 6; macOS 14/iOS 16/tvOS 16/watchOS 9/visionOS 1 |
| Проверенная сборка | Apple Swift 6.3.3, Swift language mode 6, `-strict-concurrency=complete`, macOS arm64, Xcode SDK |

Release pin для R02 должен быть **новым проверенным** exact release или полным
revision, содержащим исправления. `from: "1.2.0"` и факт совместимости с Swift 6
не являются приёмкой. Этот аудит не утверждает доступность будущего release.
Локальная разработка — отдельный consumer с `.package(path: ...)` или SPM edit
override; опубликованный manifest должен использовать remote pin. Сам audit
поддерживает `--checkout /path/to/flux`, но всегда извлекает ровно указанный выше
revision через `git archive`, игнорируя рабочие изменения. Это override места
хранения git objects, а не способ незаметно проверить другой код.

## Воспроизведение

Из корня Trellis:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
python3 Scripts/check_flux_foundation.py --output /tmp/trellis-r01-results
```

[Runner](../../Scripts/check_flux_foundation.py) создаёт временный checkout без
изменения Flux/Weave. Сначала запускает весь оригинальный suite; затем вставляет
строго проверенные по тексту scheduling hooks в копию исходников и запускает
только [R01Audit](r01-flux/FoundationAudit.swift). При несовпадении instrumentation
скрипт завершается ошибкой. [Барьеры](r01-flux/Hooks.swift) используют actors и
continuations, без sleeps, polling, unsafe-аннотаций и stress в качестве оракула.
Suite сериализован; каждый тест ограничен минутой, subprocess — четырьмя минутами.
Логи и команды сохраняются в output. Временный пакет удаляется после прогона.
Runner запускается отдельно от check_all.py: R01 требует checkout источника,
не вводя его как обязательную зависимость обычной сборки Trellis. R02 должен
подключить тесты интеграции к штатной проверке вместе с зависимостью.

Instrumentation расширяет допустимое окно исполнения и ничего не исправляет:

- modify/distinct: pause **после storage read**, до compare/transform/write;
- replay: pause **после registration/current**, до yield; отдельный ack после yield;
- flatMapLatest: pause **после cancellation guard**, до yield; ack после replace;
- sinks: ack **после цикла**. В cancellation-тестах до/внутри handler новые await
  не добавлены — воспроизведение не создаёт искусственного actor hop перед handler.

Для flatMapLatest пауза моделирует конкурентную отмену между guard и yield:
это разные операции в разных tasks, их не защищает один lock/actor transaction.
Тест не измеряет частоту гонки в production. Он также не обещает отозвать значение,
уже доставленное до переключения: проверяется именно yield **после** replace.

## Результаты и границы гарантий

| Проверка | Наблюдение |
|---|---|
| Штатный Flux suite | 138 тестов, Swift 6 complete concurrency, проходит |
| CurrentValue.modify × 2 | Оба читают 0; итог 1 вместо 2 — #56 |
| CurrentValueDistinct.modify × 2 | Та же потеря increment — #56 |
| CurrentValueDistinct.set(1) × 2 | Оба читают 0; поочерёдный release с чтением между yields даёт две единицы — #56 |
| Replay/set | Регистрация с 0 → set(1) → replay(0); storage = 1, subscriber получает 0 — #57 |
| Cancel до MainActor delivery | Отмена до запуска task; buffered `[1,2,3]` всё равно вызывают handler — #58 |
| Cancel внутри MainActor callback | Отмена при первом callback; оставшиеся buffered значения также доставляются — #58 |
| Latest, значение прошло guard | Switch/cancel → release старого yield; старое 10 доходит после switch, затем новое 20 — #59 |
| Latest, ответ после termination | Старый continuation возвращает `.terminated`; новое 20 доставляется |
| Bounded buffering | Pipe newest(2), 100 sends без consumer: 98 видимых drops, остаток 98/99; finish освобождает subscribers |
| Наследование buffer policy | map сохраняет newest(2) Pipe / newest(1) CurrentValue; cold `from` остаётся без bounded policy |
| Subscription lifetime | cancel снимает handle из bag и после выхода sink source subscriberCount = 0 |
| Bag lifetime | deinit отменяет subscription, weak handle становится nil |

Дефекты зарегистрированы в [реестре #56–#59](../defects.md). Исправлений внешнего
Flux в этой карточке нет; они должны получить отдельный Flux commit/release и
regression-тесты с **корректными**, а не characterization-ожиданиями. Затем повторить
штатный suite, эти interleavings и проверить новый pin перед закрытием R02.

Ограниченный AsyncStream buffer не означает backpressure на producer и не
ограничивает автоматически каждый пользовательский Task. Pipe по умолчанию хранит
64 значения на подписчика; CurrentValue — 1. Cold factories и deprecated unbounded
операторы допускают неограниченную очередь. Для действий `.send` скрывает overflow;
нужны `sendObservingOverflow` и явная политика R04. Для UI R03/R04 сохраняют session
identity/revision check у commit: даже исправленная отмена не откатывает уже
выполненный callback и не останавливает произвольный producer без cancellation linkage.
Async replay не обеспечивает синхронный initial первого кадра D14.

## Swift 6 и unchecked-типы внешней зависимости

В Flux 11 `@unchecked Sendable` объявлений: Pipe, Subscription, SubscriptionBag,
TaskBox, TerminationStorage, _SubscriptionBox, два subscription gates и три
_CombineLatestState. Прочитаны поля/операции: изменяемые словари, состояния,
handlers и task handles синхронизируются NSLock; closure-поля Sendable,
AsyncStream continuations передаваемы. Это локальная синхронизация памяти,
**не** доказательство атомарности composed операций между actor/lock boundaries.
Именно поэтому Swift 6 пропускает #56–#59. Blanket-исключений для Trellis policy нет.

TaskBox.cancelCurrent не делает box навсегда terminal: последующий replace может
установить новую task. SharedFlux — одноразовый bridge, terminal после последней
отписки, повторное подключение не перезапускает upstream. Его проверка gate перед
registration не атомарна с actor registration. Эти дополнительные границы требуют
проверки при выборе операторов для R03/R04, текущие 11 тестов не являются полным
доказательством корректности всего Flux runtime. Текущая проверка lifetime касается
Pipe/sink/Bag, а не каждого произвольного графа операторов или удержания live Node.

## Evidence и платформы

Сохранены [baseline.log](r01-flux/baseline.log), [audit.log](r01-flux/audit.log) и
[results.json](r01-flux/results.json). Audit: 11 тестов. Все ожидания объяснены выше.
В исходном suite есть предупреждения об использовании deprecated unbounded
операторов и лишних await; прогон не заявлен как warnings-as-errors.
Начальный sandbox-прогон не прошёл: compiler cache недоступен и окружение выбирало
CLT SDK. Успешный запуск использует явно выбранный Xcode SDK и доступ к cache;
сбой окружения не выдаётся за дефект Flux.

R01 выполнен на macOS arm64. iOS/tvOS consumer/API/matrix проверяет R02 после
подключения зависимости; в этой карточке эти прогоны не заявлены. Native scrolling,
устройства и производительность относятся к R06 и далее.

## Проверка Trellis

Policy: 0 diagnostics; 20 policy fixtures и 3 verifier tests прошли. Formatter
проверил production/тесты Trellis и отдельно два новых Swift audit-файла.
Обычный `check_all.py` сначала остановился на существующем M12-тесте:
[excerpt первого сбоя](r01-flux/trellis-initial-failure.log), дефект #60.
Повтор без изменений Sources/Tests прошёл все 702 теста и внешний consumer.
Первый сбой не удалён из evidence и не объявлен исправленным.

Повторный `check_all.py` завершился с exit 0: API baseline Core/Render/AppKit/UIKit
и tvOS surface совпадают, 62 macOS screenshot-эталона совпадают, TRELLIS_LOG
проверен в реальном процессе. Полная Simulator/device matrix не запускалась:
R01 не меняет runtime или платформенные adapters.
