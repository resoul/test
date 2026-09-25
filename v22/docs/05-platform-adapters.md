# Платформенные адаптеры

**Статус: согласовано** как цель (P5): одна раскладка для `Node`, `UIView`, `NSView`.
Механика — **предложено**.

## Одна раскладка — три носителя

```swift
final class ProfileCardView: UIView {
    private let avatar = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let follow = UIButton(type: .system)

    override func layoutSubviews() {
        super.layoutSubviews()
        FlexContainer(.row) {
            avatar.size(48)
            FlexContainer(.column) { title; subtitle }
                .gap(4)
                .flex(grow: 1)
            follow
        }
        .alignItems(.center)
        .gap(12)
        .padding(16)
        .apply(in: bounds)
    }
}
```

Тот же синтаксис, тот же движок, что и у `Node`. Отличаются измерение элемента
(`sizeThatFits` вместо CoreText-измерения ноды) и место расчёта (main вместо фона) — см.
[02-modules.md](02-modules.md#правила).

## Как вызывается раскладка

Нужны оба способа.

### Базовые классы

`LayoutView: UIView` и `LayoutNSView: NSView` (имена согласованы 2026-09-25) сами переопределяют
`layoutSubviews` / `NSView.layout()` и зовут `layoutSpec()`. Пользователь переопределяет
только `layoutSpec()` — так же, как у `Node`.

### Протокол + одна строка

Для классов, которые нельзя унаследовать от нашего базового: `UITableViewCell`,
`UICollectionViewCell`, `UIControl`, чужие view. Пользователь реализует `layoutSpec()` и
пишет одну строку в своём `layoutSubviews`, например `applyLayout()`.

Автоматически переопределить `layoutSubviews` из протокола Swift не умеет; swizzling
исключён (Swift 6, хрупкость, скрытое поведение).

`Node` вызывает `layoutSpec()` сам — базовый класс.

## Что адаптер обязан закрыть

| Задача | UIKit | AppKit |
|---|---|---|
| Сообщить собственный размер наружу | `sizeThatFits` + `intrinsicContentSize` (иначе Auto Layout и self-sizing ячейки не узнают высоту) | `fittingSize` + `intrinsicContentSize` |
| Запросить пересчёт | `setNeedsLayout` + `invalidateIntrinsicContentSize` | `needsLayout = true` + `invalidateIntrinsicContentSize` |
| Система координат | y вниз | y вверх, если не `isFlipped`. **Реализовано:** `LayoutNSView` и `NodeNSView` перевёрнуты сами; при вызове через протокол (`applyLayoutSpec()` в чужом view) адаптер отражает y, если родитель не перевёрнут |
| Направление письма | `effectiveUserInterfaceLayoutDirection` | `userInterfaceLayoutDirection` |
| Округление к пикселям | `traitCollection.displayScale` | `window.backingScaleFactor` (переиспользовать `PixelRoundingPolicy` Trellis) |
| Измерение ребёнка | `sizeThatFits` | `fittingSize` / `intrinsicContentSize` |

Правило для пользователя: у детей view с `layoutSpec()` нет Auto Layout-констрейнтов —
frame выставляет раскладка. Снаружи сам view свободно живёт в Auto Layout через
`intrinsicContentSize`.

### Mac Catalyst

Catalyst-приложение — UIKit-приложение: в нём работают `LayoutUIKit`/`NodesUIKit`, а
`LayoutAppKit`/`NodesAppKit` собираются пустыми. В Catalyst импортируются и UIKit, и AppKit, но
`NSView` недоступен, поэтому AppKit-адаптеры закрыты `#if canImport(AppKit) && !canImport(UIKit)`
(реализовано 2026-09-25, дефект #153). Приложению с общим кодом для Mac и Catalyst нужно то же
условие: `#if canImport(AppKit)` в Catalyst истинно и выбрало бы AppKit-адаптер.

```swift
#if canImport(AppKit) && !canImport(UIKit)
    import NodesAppKit   // Mac
#else
    import NodesUIKit    // iOS, iPadOS, tvOS, Mac Catalyst
#endif
```

### Прокрутка

Реализовано 2026-09-25, [03](03-layout-api.md) (девятый срез). Рисуют слои нод; адаптер
даёт только системную физику и пересылает смещение в `Scroll.platformDidScroll(to:)`.

- **iOS, iPadOS, Catalyst.** На каждую видимую прокрутку — пустой `UIScrollView` над её
  кадром (`ScrollDriver`); его `panGestureRecognizer` добавлен на `NodeView`. Касания над
  ним `NodeView.hitTest` забирает себе, поэтому нажатия доходят до нод. Скрытый или с
  выключенным взаимодействием `UIScrollView` свой пан не начинает — проверено на Simulator.
  Какой пан начать, решает `gestureRecognizerShouldBegin`: самая внутренняя прокрутка под
  пальцем, которой есть куда двигаться по своей оси (`NodeHost.scrolls(at:)`) — лента
  вбок внутри списка. Касание во время инерции только останавливает её. Смещение, заданное
  кодом, `UIScrollView` догоняет после отрисовки. `scrollsToTop` оставлен системным
  (свойство недоступно на tvOS, ветвиться по платформе нельзя): с одной прокруткой на
  экране нажатие на строку состояния прокручивает наверх.
- **Mac.** `NodeNSView.scrollWheel`: дельты колеса и трекпада (инерция трекпада приходит
  событиями от системы) двигают самую внутреннюю прокрутку под курсором; дошедшая до края
  передаёт остаток внешней; жест трекпада держится за прокрутки, где начался. Колесо мыши —
  строками по 10 pt. Что прокруткам не нужно — дальше по цепочке ответчиков. Трекпад тянет
  за край с сопротивлением и отпускает пружиной (`Scroll.platformDidScroll`, `overscroll`),
  инерция у края отскакивает; колесо мыши упирается.
- **tvOS и iPad с клавиатурой — фокус.** Движок фокуса ищет только в видимой области, кроме
  прокручиваемых контейнеров. Каждая прокрутка поэтому — `ScrollFocusContainer`: фокус-элемент,
  который сам фокус не берёт, `UIFocusItemScrollableContainer` и своё пространство координат
  (содержимое, сдвинутое на смещение, как `bounds` у `UIScrollView`). Фокусируемые ноды внутри —
  его дети с рамками в координатах содержимого; движок находит их за краем окна и задаёт
  `contentOffset`, который двигает `Scroll` в анимации фокуса. Пустой `UIScrollView` физики из
  `focusItems(in:)` исключён — иначе движок видел бы лишний контейнер. На TV физики касаний
  нет, прокручивает только фокус.

«Рисование» остаётся за самими view (`draw(_:)`) или за `CALayer` нод; раскладка только
расставляет frame.

## Встраивание нод

- `view.addSubnode(node)` на `UIView`/`NSView` незаметно создаёт хост-сессию для этого
  корня (в Trellis сейчас нужен явный `TrellisHostView` + `attach(root:)`).
- `node.view` по требованию — как в Texture — **открыто**.
- Время жизни: хост живёт, пока нода смонтирована в view; удаление из superview — detach.
  Детали (suspend при скрытии окна, несколько корней в одном view) — **открыто**.

## Смешанные деревья

**Статус: вторая очередь.**

- `UIView` внутри раскладки `Node` (текстовый ввод, карта, видео) — обобщение нативного
  backing, который Trellis уже умеет для scroll (аналог `initWithViewBlock` в Texture).
- `Node` внутри раскладки `UIView` — адаптер делает `addSubnode` сам.

Оба направления реальны, но это самая трудоёмкая часть. Первая очередь — три однородных
случая: только ноды, только `UIView`, только `NSView`.
