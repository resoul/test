# Layout API

Имена в примерах черновые, кроме отмеченных как согласованные.

## Модель: как в Texture

**Статус: согласовано.**

- Подкласс `Node` создаёт дочерние ноды **один раз** в `init` и хранит их в свойствах.
- Внешний вид (`appearance`, `textStyle`, …) — свойства самих нод, задаются в `init` или
  при смене данных.
- Раскладка — отдельный метод, который **только ссылается** на существующие ноды и
  никогда их не создаёт.
- Нода встраивается в UIKit/AppKit через `addSubnode` ([05-platform-adapters.md](05-platform-adapters.md)).

```swift
final class ProfileCard: Node {
    private let avatar = Image()
    private let title = Text()
    private let subtitle = Text()
    private let follow = Button("Follow")

    init(user: User) {
        super.init()
        appearance.background = .color(.card)
        appearance.cornerRadius = 12
        avatar.appearance.cornerRadius = 24
        title.textStyle = .headline
        subtitle.textStyle = .caption
        update(user)
    }

    func update(_ user: User) {
        avatar.url = user.avatarURL
        title.text = user.name
        subtitle.text = user.handle
    }

    override func layoutSpec() -> Layout {
        FlexContainer(.row) {
            avatar
                .size(48)

            FlexContainer(.column) {
                title
                subtitle
            }
            .gap(4)
            .flex(grow: 1, shrink: 1)

            follow
        }
        .alignItems(.center)
        .gap(12)
        .padding(16)
    }
}

// UIKit
view.addSubnode(ProfileCard(user: user))
```

Почему создание нод не переносится в раскладку: раскладка пересчитывается (поворот, смена
данных, брейкпоинт). Нода, созданная внутри, была бы новой на каждом проходе — терялись бы
слой, состояние и анимации. Отвергнутые варианты: создание в раскладке с кэшем по позиции
и описания-значения с реконсиляцией (SwiftUI).

## Метод раскладки

**Статус: предложено** — имя `layoutSpec()`.

- Имя `layout()` **нельзя**: у `NSView` уже есть системный `layout()` (аналог
  `layoutSubviews`), и `override` там означал бы совсем другое. `layoutSpec()` свободно
  в UIKit и AppKit и отсылает к Texture. Альтернативы: `arrange()`, `makeLayout()`.
- Метод **не является** result builder'ом: он возвращает одно значение `Layout`, внутри
  доступен обычный Swift — `guard`, локальные переменные, ранний `return`. Builder
  действует только внутри фигурных скобок контейнеров.
- Один и тот же протокол «у меня есть раскладка» реализуют `Node`, `UIView`- и
  `NSView`-адаптеры.
- Когда раскладку надо пересчитать из-за смены данных, вызывается аналог
  `setNeedsLayout` (в Trellis — `markArrangementDirty()`). Имя — открыто.

## Элементы раскладки

**Статус: согласовано.**

- Элементом является **сама нода** (или `UIView`/`NSView` в соответствующем адаптере).
  Обёртки `Leaf(node)` нет.
- **Опциональный элемент** (`Image?`) допустим: `nil` просто пропускается.
- Контейнеры — **только описание геометрии**, как `ASLayoutSpec`. `FlexContainer` не
  становится нодой и не получает `CALayer`.

## Управление subnodes

**Статус: согласовано** (по принципу), детали — предложено.

- Управление включено всегда (аналог `automaticallyManagesSubnodes` без флага).
- Нода из свойства, упомянутая в результате `layoutSpec()`, смонтирована как subnode.
- Нода, не упомянутая в этом проходе, **снимается с экрана, но остаётся жива** — её держит
  свойство. Вернулась в раскладку — та же нода, тот же `NodeID`, тот же слой.
- Нода, упомянутая дважды в одном проходе, — ошибка раскладки: диагностика через
  `Log.on`, проход отклоняется целиком (как валидация C21 в Trellis).
- Ручные `addSubnode`/`removeFromSupernode` для ноды с `layoutSpec()` — **открыто**:
  запрещать, как D05 в Trellis, или разрешить ручной режим, когда `layoutSpec()` не
  переопределён.

## Модификаторы — параметры места в родителе

**Статус: согласовано.**

Модификатор возвращает значение «элемент + параметры для родителя» и **ничего не пишет в
ноду**. Следствия:

- удалил модификатор — его эффекта больше нет, следов прошлого прохода не остаётся;
- одну ноду можно поставить в разные раскладки (например, в разные ветки `Breakpoint`) с
  разными параметрами;
- базовые свойства ноды (`style` в Trellis) остаются под контролем владельца ноды.

Это исправляет известное неудобство Texture, где `node.style.flexGrow` хранится в ребёнке,
хотя имеет смысл только относительно родителя.

`.padding(...)` на элементе — отступ **в раскладке** (аналог `ASInsetLayoutSpec`), а не
свойство ноды.

## Словарь первой версии

**Статус: предложено.** Цель — покрыть CSS Flexbox полностью
([06-flexbox-conformance.md](06-flexbox-conformance.md)).

Контейнеры:

| Контейнер | Смысл |
|---|---|
| `FlexContainer(.row / .column / .rowReverse / .columnReverse)` | CSS `display: flex` |
| `Overlay` / `.background { }` / `.overlay { }` | наложение, как `ASOverlayLayoutSpec`/`ASBackgroundLayoutSpec` |
| `Center` | центрирование, как `ASCenterLayoutSpec` |
| `Spacer` | гибкий промежуток (`flex-grow: 1` пустого элемента) |
| `Breakpoint` | ветка по ширине контейнера ([04](04-conditionals-and-responsive.md)) |

Модификаторы контейнера: `.justifyContent`, `.alignItems`, `.alignContent`, `.wrap`,
`.gap(row:column:)`, `.padding`.

Модификаторы элемента: `.flex(grow:shrink:basis:)`, `.alignSelf`, `.size`,
`.width`/`.height` (points / percent / auto), `.minWidth`/`.maxWidth`/`.minHeight`/
`.maxHeight`, `.aspectRatio`, `.margin` (включая `auto`), `.order`, `.position(.absolute)`
с `top`/`leading`/`bottom`/`trailing`, `.zIndex`.

Модификаторы видимости и условные модификаторы — в
[04-conditionals-and-responsive.md](04-conditionals-and-responsive.md).

## Расширяемость

**Статус: открыто.** В Trellis словарь закрыт (`lower()` распознаёт только свои типы). В
v22 нужен способ написать собственный контейнер (как подкласс `ASLayoutSpec`). Ограничение
— фоновый расчёт: собственный контейнер обязан быть `Sendable`-описанием с чистой функцией
раскладки, без доступа к живым нодам. Форма протокола — предмет отдельного обсуждения.
