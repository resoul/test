# List Comparison для iOS

Отдельное приложение с двумя контроллерами на одном наборе данных:

- **UIKit** — `UITableView`, self-sizing ячейки с Auto Layout, `UILabel`,
  `UIImageView`, горизонтальная `UICollectionView` в шапке и prefetching.
- **Nodes** — `NodeView`, `Table` с prepared API внутри вертикального `Scroll`,
  горизонтальный `Scroll` в шапке, фоновый Layout solver и bitmap renderer.

Оба экрана показывают профиль, шесть избранных маршрутов и одинаковые карточки:
текст разной длины, иллюстрация, место и кнопка сохранения. Кнопка числа записей
справа сверху выбирает **100 / 500 / 2000** или возвращает списки к началу.
Сохранённые записи общие, позиции прокрутки вкладок независимы.

## Запуск на телефоне

1. Открыть `ComparisonDemo/ComparisonDemo.xcodeproj` из корня репозитория.
2. Выбрать схему **ComparisonDemo** и подключённый iPhone.
3. В Signing & Capabilities выбрать свою команду, если существующая недоступна.
   Используется отдельный bundle identifier `dev.layout.comparison`.
4. Запустить Run. Для сравнения плавности лучше выбрать **Release** в
   Product → Scheme → Edit Scheme → Run → Build Configuration.

Минимальная система — iOS 17. Поддерживаются iPhone и iPad, портрет и ландшафт.
Обе вкладки используют одну светлую палитру независимо от системной темы.
Проект подключает только локальные пакеты NodesUI и Layout и их зависимости Basics/Data;
GRDB, AsyncRay, CocoaPods и сетевое разрешение пакетов ему не нужны.

Все 24 иллюстрации лежат в bundle, интернет и разрешения на фото не требуются.
Исходник генератора: `ComparisonDemo/Tools/GenerateArtwork.swift`. Перегенерация из
корня репозитория:

```sh
swift ComparisonDemo/Tools/GenerateArtwork.swift ComparisonDemo/App/Artwork
```

## Что сравнивается

Контент и оформление общие, UIKit и Nodes используют свои обычные layout/scroll paths.
На UIKit декодирование локальных JPEG выполняется на отдельном actor, кэш ограничен
64 MiB; на Nodes используется отдельный ImagePipeline с таким же decoded cache budget.
Кэши вкладок независимы. Общим остаётся системный файловый кэш.

В Nodes модель подготавливается detached workers через Table: локальные bytes
preload и предварительная оценка текста CoreText. Пока план не готов, карточка
показывает лёгкий placeholder. Настоящая геометрия проверяется Layout engine;
предварительная высота остаётся оценкой. `Image` работает в `.demandDriven`:
Preload получает bytes, Display декодирует, Visible повышает urgency. Изображения
и текст рисуются через общий renderer. Создание Node и CALayer commit остаются
на MainActor.

Это визуальное демо для ручной проверки, а не готовый benchmark или доказательство
превосходства одного подхода. Для замеров использовать один телефон, Release,
одинаковое число записей и Instruments; прогонять оба порядка вкладок, отдельно
холодный и повторный проход. Демо не содержит искусственных sleep/busy loops для
замедления UIKit. Горизонтальная лента встроена в общую вертикальную страницу;
координатор collapsing header и горизонтальные страницы с собственными вертикальными
списками сюда не входят.

## Проверки

Из корня репозитория:

```sh
Scripts/run-with-deadline.sh 1200 -- sh -c '
  xcodebuild test \
    -project ComparisonDemo/ComparisonDemo.xcodeproj \
    -scheme ComparisonDemo \
    -destination "platform=iOS Simulator,name=iPhone 17" \
    -resultBundlePath "$RUN_DIR/result.xcresult"
'
```

UI-тесты проверяют оба контроллера, сохранение, выбор нагрузки и поворот; снимки
экрана сохраняются в attachments xcresult. Переменные запуска для автоматизации:
`COMPARISON_ROWS=100|500|2000`, `COMPARISON_ENGINE=nodes` для старта на второй вкладке.
На физическом телефоне запуск и измерения выполняет пользователь; проверка
Simulator не считается проверкой телефона.


Проверено 2026-10-24: все три UI-теста прошли на iPhone 17 Simulator; Release-сборка
для generic iOS device собрана без подписи. Снимки успешного прогона — в
`ComparisonDemo/Previews/`. Физический телефон пока не проверен.

Журналы в корне репозитория:

- `.build/deadline-runs/comparison-ios-ui-verified-20261024/` — UI tests и xcresult;
- `.build/deadline-runs/comparison-device-release-build-20261024/` — iPhone SDK Release build;
- `.build/deadline-runs/comparison-table-regression-final-20261024/` — 315 NodesTests и
  74 выбранных Table/renderer tests после исправления ширины Cell.
