# ADR 0015 — `NodeHostBridge.attach` получает `textRenderer`/`localeIdentifier`

Дата: 2026-09-12. Карточка T09 (implementation-plan-4.md §5), реализует D51/D53.

## Изменение

```
 public func attach(
     root newRoot: Node,
     bounds: LayoutFrame,
     scale: Double,
     safeAreaInsets: DirectionalEdgeInsets = DirectionalEdgeInsets(),
-    layoutDirection: LayoutDirection = .leftToRight
+    layoutDirection: LayoutDirection = .leftToRight,
+    textRenderer: (any TextRenderer)? = nil,
+    localeIdentifier: String? = nil
 ) -> Bool { ... }

+public func updateLocaleIdentifier(_ identifier: String) { ... }
```

`Node` (`TrellisCore`) получает два новых convenience-метода того же вида, что
`setLayoutDirection`/`setSafeAreaInsets`:

```
+public func setTextRenderer(_ renderer: (any TextRenderer)?)
+public func setLocaleIdentifier(_ identifier: String)
```

`api/TrellisCore.json` фиксирует оба как `added`; `api/TrellisRender.json`
фиксирует новый `updateLocaleIdentifier` как `added` и `attach` — как
`removed`+`added` (mangled name меняется вместе с сигнатурой).

## Почему это не source-breaking

Оба новых параметра `attach` — `nil` по умолчанию. Существующий вызов
`bridge.attach(root:bounds:scale:safeAreaInsets:layoutDirection:)` (без двух
новых именованных аргументов) продолжает компилироваться и вести себя ровно
как раньше: `nil` для `textRenderer`/`localeIdentifier` — то же самое, что
происходило неявно до T09 (headless-нода читает `TextRendererKey.defaultValue
== nil` → `PortableTextMeasurer`, D51; `LocaleKey.defaultValue == "en"`).
Меняется только mangled-имя инициализатора — тот же класс изменения, что уже
происходил в ADR 0011/0014 (новый параметр с default ломает символ, не
исходный код).

## Почему параметры на `attach`, а не отдельный `updateTextRenderer`/`setTextRenderer` после него

`NodeHostBridge.attach` уже документирован как «Atomically attaches a root
using one consistent initial host state» — `safeAreaInsets`/`layoutDirection`
устанавливаются внутри него, до первого `coordinator.invalidate(...)`, чтобы
первый flush уже видел полное окружение и не тратил лишний проход. Установка
`textRenderer`/`localeIdentifier` отдельным вызовом после `attach()` вернула
бы `true` для первого flush с `nil`/`"en"` и заставила бы второй flush сразу
вслед за первым — два прохода солвера вместо одного на каждый `attach`.

`updateLocaleIdentifier` — отдельный метод, а не часть `updateBridgeState`'s
уже существующих `updateSafeArea`/`updateLayoutDirection`, потому что вызов
инициируется другим событием (`NSLocale.currentLocaleDidChangeNotification`,
не layout-lifecycle) — тот же принцип, что развёл `updateSafeArea`/
`updateLayoutDirection` на два метода, а не один `updateHostState(...)`,
несмотря на то что оба вызываются из одного и того же `updateBridgeState()`.
`updateTextRenderer` не добавлен: ни один хост не меняет измеритель после
`attach` в этой карточке — добавление непроверенного API без вызывающей
стороны не входит в T09.

## Решение

Обновить baseline через `check_api.py --tvos --update --review-note
docs/adr/0015-node-host-bridge-attach-gains-text-environment.md`.
