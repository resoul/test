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

**Статус: реализовано** для `UIView`/`NSView` (модули `LayoutUIKit`/`LayoutAppKit`):
`func layoutSpec() -> LayoutSpec?`. Возвращаемый тип — `LayoutSpec`, а не `Layout`, чтобы не
спорить с `SwiftUI.Layout` в файлах, где импортирован SwiftUI.

`.padding` на элементе ведёт себя как в SwiftUI — применяется к тому, что до него:
`avatar.size(48).padding(8)` — аватар 48 в слоте 64; `avatar.padding(8).size(48)` — слот 48,
аватар 32. На контейнере `.padding` — обычный отступ содержимого.

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

**Статус: согласовано** (по принципу), детали — предложено. **Срез реализован
(2026-09-24)** в модуле `Nodes`: `Node` (`layoutSpec()`, `update()`, `layoutContent`,
`frame`, `subnodes`, `supernode`, `isMounted`) и `NodeHost` (размер, масштаб, направление,
`onNeedsLayout`, `layoutIfNeeded()`). Раскладка всего дерева — один проход движка: нода с
`layoutSpec()` в раскладке родителя встраивается в неё как flex-контейнер
(`LayoutElement.embeddedLayout`), кадры детей — в координатах своей ноды. Что прочитано в
`layoutSpec()` — зависимость раскладки; что в `update()` — зависимость `update()`, который
идёт до первого замера ноды. 9 тестов на Linux.

**Второй срез (2026-09-24):** `Appearance` (фон, скругление, рамка, прозрачность, обрезка —
смена перерисовывает без раскладки), `NodesRender.LayerRenderer` (одно дерево `CALayer` на
дерево нод, только QuartzCore, общий для UIKit и AppKit), `NodeView`/`NodeNSView` и
`view.addSubnode(node)`. `NodeNSView` — layer-hosting с `isGeometryFlipped`, чтобы
AppKit не трогал геометрию слоя. Apple-часть на Linux не компилируется — проверяется на
Mac (`NodesRenderTests`).

**Третий срез (2026-09-24):** `Text` (CoreText, модуль `NodesRender`): измерение
(min-content — самое длинное слово, max-content — самая длинная строка, высота при ширине,
первая базовая линия) и рисование строятся одной `TextLayout`, так что измеренное
совпадает с нарисованным; `LayerDrawing` — нода рисует своё содержимое в bitmap слоя,
перерисовка только при смене ревизии, размера или масштаба. Картинка в `contents`
показывается как есть при любой геометрии слоёв вокруг — рисуется всегда прямо (#129).
Демо `v22/Demo` на Mac: текст, вид, раскладка — подтверждены скриншотом.

**Четвёртый срез (2026-09-24): нажатия.** `Node.hitTest` (самая глубокая видимая нода;
выступающие за рамку дети ловятся, если родитель не обрезает), `Node.onTap` — нажатие
получает ближайшая нода с действием вверх по дереву, как у кнопки: засчитывается, если
отпущено над той же нодой; `pressChanged` — вид нажатого состояния. `NodeHost.pointerDown/
pointerUp/pointerCancelled`, адаптеры передают touches (UIKit) и мышь (AppKit); то, что
не попало в ноду с действием, идёт дальше по responder chain. `Button` в `NodesRender`.
Демо — все кнопки нодами.

**Пятый срез (2026-09-24): `NodeCache`** (см. 04) **и расчёт в фоне.** `LayoutCore`:
`LayoutSpec.prepare` → `PreparedLayout` (`input` — `Sendable`, решается где угодно;
`apply(result, in:, scale:)` — на MainActor); `ContentMeasurer.requiresMainThread` (у
измерителей view — `true`). `NodeHost.solvesInBackground`: после первого прохода движок
работает на своём потоке со стеком 8 МиБ; `layoutSpec()`/`update()` и применение кадров —
на главном; до прихода новых кадров остаются старые; обогнанный расчёт отменяется
(`Thread.cancel` → точки отмены движка) и выбрасывается; раскладка с view внутри решается
на главном. Первый проход синхронный — view не появляется пустым. Демо включает фоновый
режим. Не сделано: расчёт в фоне, `NodeCache`, стиль шрифта
(жирность, межстрочный интервал, число строк), выравнивание по правому краю для RTL.

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
