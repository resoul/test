# Espalier

Следующее поколение Trellis — **отдельная библиотека Espalier** (решено 2026-09-25: имя
`Trellis` занято другим Swift-пакетом). Пока код живёт в папке `v22/` репозитория Trellis;
потом переедет в свой репозиторий.

**Статус: движок раскладки и DSL для `UIView`/`NSView` написаны** (сверка с Chromium,
замеры скорости — [10-layout-engine.md](docs/10-layout-engine.md)); слой нод, состояние и
рендер — в проектировании. Документы фиксируют то, что согласовано в обсуждении
2026-09-24, и отдельно — то, что пока только предложено или открыто. Каждый пункт помечен
одним из статусов:

| Статус | Значение |
|---|---|
| **согласовано** | принято в обсуждении, дальше проектируем исходя из этого |
| **предложено** | вариант автора документа, явного «да» ещё не было |
| **открыто** | вопрос не решён, варианты перечислены |

Решения Trellis ([docs/decisions.md](https://github.com/resoul/test/blob/main/docs/decisions.md)) этими документами не
меняются. Там, где Espalier расходится с D-решением Trellis, это названо явно в
[01-overview.md](docs/01-overview.md#что-пересматривается-относительно-trellis).

## Код

- `Package.swift` — отдельный пакет: `LayoutCore` (движок и DSL, собирается и на Linux),
  `LayoutUIKit`, `LayoutAppKit` (адаптеры view); тесты `LayoutCoreTests`,
  `LayoutAdapterTests` (только macOS).
- `StateCore` (синхронное состояние с отслеживанием чтений) и `StateAsyncRay` (мост к
  [AsyncRay](https://github.com/resoul/AsyncRay) 1.0.0) — тесты `StateCoreTests`, `StateAsyncRayTests`.
- `Nodes`, `NodesRender`, `NodesUIKit`, `NodesAppKit` — дерево нод, отрисовка в
  `CALayer`, текст на CoreText, картинки (`Image`: `Data`/URL, дисковый кэш, декодирование
  под рамку — [11-image.md](docs/11-image.md)), `view.addSubnode(node)`.
- `Demo/` — экран на нодах (`DemoScreens`) и окно для Mac: `cd Demo && swift run`.
- `DemoiOS.swiftpm` — тот же экран на iPhone/iPad: открыть папку в Xcode, запустить на
  симуляторе.
- `Benchmarks/` — отдельный пакет: скорость движка рядом со старым движком Trellis на тех
  же деревьях. Старый движок — замороженная копия его исходников в
  `Benchmarks/Sources/PreviousLayoutEngine`, пакет ничего не берёт извне `v22/`.
- [AGENTS.md](AGENTS.md) — правила кода Espalier, в том числе: **комментарии не ссылаются на
  наши документы**; связь кода с документами — в [docs/code-map.md](docs/code-map.md).

## Документы

1. [Обзор и принципы](docs/01-overview.md) — зачем Espalier, что берём из Trellis и Texture,
   что меняем.
2. [Модули](docs/02-modules.md) — каждая система живёт отдельно и используется по
   отдельности.
3. [Layout API](docs/03-layout-api.md) — `layoutSpec()`, `FlexContainer`, модификаторы,
   элементы раскладки.
4. [Условия и адаптивность](docs/04-conditionals-and-responsive.md) — `if` против
   `Breakpoint`, видимость, адаптивные значения, кэш нод.
5. [Платформенные адаптеры](docs/05-platform-adapters.md) — одна раскладка для `Node`,
   `UIView`, `NSView`; `addSubnode`.
6. [Flexbox как в CSS](docs/06-flexbox-conformance.md) — цель «точь-в-точь» и как её
   доказывать через Chromium.
7. [Именование](docs/07-naming.md) — правило суффиксов и известные конфликты.
8. [Открытые вопросы](docs/08-open-questions.md) — что ещё предстоит решить.
9. [Тема и токены](docs/09-theme.md) — тема по умолчанию, токены отступов, где живёт
   тема.
10. [Движок раскладки](docs/10-layout-engine.md) — новый flex-движок на основе старого:
    что переносится, что пишется заново по CSS §9, этапы, их статус, замеры, диагностика.
11. [Карта кода](docs/code-map.md) — какая функция на каком документе основана.

## Источники вдохновения

- [Texture](https://github.com/TextureGroup/Texture) — модель «подкласс ноды + раскладка
  внутри + `addSubnode` в UIKit», layout spec'и без собственных view/слоёв. Код Texture
  не копируется (см. [source-provenance.md](https://github.com/resoul/test/blob/main/docs/source-provenance.md)).
- [AsyncRay](https://github.com/resoul/AsyncRay) — реактивные потоки на Swift Concurrency;
  в Espalier рассматривается как адаптер к состоянию, а не как его ядро.
