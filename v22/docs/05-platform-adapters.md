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

`LayoutView: UIView` и `LayoutNSView: NSView` (имена — открыто) сами переопределяют
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
| Система координат | y вниз | y вверх, если не `isFlipped` — адаптер переворачивает или требует `isFlipped` (открыто) |
| Направление письма | `effectiveUserInterfaceLayoutDirection` | `userInterfaceLayoutDirection` |
| Округление к пикселям | `traitCollection.displayScale` | `window.backingScaleFactor` (переиспользовать `PixelRoundingPolicy` Trellis) |
| Измерение ребёнка | `sizeThatFits` | `fittingSize` / `intrinsicContentSize` |

Правило для пользователя: у детей view с `layoutSpec()` нет Auto Layout-констрейнтов —
frame выставляет раскладка. Снаружи сам view свободно живёт в Auto Layout через
`intrinsicContentSize`.

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
