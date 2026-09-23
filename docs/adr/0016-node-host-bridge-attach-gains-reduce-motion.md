# ADR 0016 — `NodeHostBridge.attach` получает `reduceMotion`

Дата: 2026-09-13. Карточка M05 (implementation-plan-5.md §5), реализует D67.

## Изменение

```
 public func attach(
     root newRoot: Node,
     bounds: LayoutFrame,
     scale: Double,
     safeAreaInsets: DirectionalEdgeInsets = DirectionalEdgeInsets(),
     layoutDirection: LayoutDirection = .leftToRight,
     textRenderer: (any TextRenderer)? = nil,
-    localeIdentifier: String? = nil
+    localeIdentifier: String? = nil,
+    reduceMotion: Bool? = nil
 ) -> Bool { ... }

+public func updateReduceMotion(_ isEnabled: Bool) { ... }
```

`Node` (`TrellisCore`) получает один новый convenience-метод того же вида, что
`setTextRenderer`/`setLocaleIdentifier`:

```
+public func setReduceMotion(_ isEnabled: Bool)
```

и один новый environment-ключ:

```
+public enum ReduceMotionKey: EnvironmentKey
+extension EnvironmentValues { public var reduceMotion: Bool { get set } }
```

`api/TrellisCore.json` фиксирует ключ/аксессор/convenience-метод как `added`;
`api/TrellisRender.json` фиксирует новый `updateReduceMotion` как `added` и
`attach` — как `removed`+`added` (mangled name меняется вместе с сигнатурой),
тот же класс изменения, что ADR 0015 уже задокументировал для
`textRenderer`/`localeIdentifier`.

## Почему это не source-breaking

Новый параметр `reduceMotion` — `nil` по умолчанию. Существующий вызов
`bridge.attach(root:bounds:scale:safeAreaInsets:layoutDirection:textRenderer:
localeIdentifier:)` (без нового именованного аргумента) продолжает
компилироваться и вести себя ровно как раньше: `nil` означает «не трогать
`ReduceMotionKey` на этом attach», так что headless-хост или существующий
вызывающий код видит `ReduceMotionKey.defaultValue == false`, то же самое, что
было неявно до этой карточки. Меняется только mangled-имя инициализатора.

## Почему параметр на `attach`, а не отдельный вызов `updateReduceMotion` сразу после него

Тот же аргумент, что ADR 0015 уже привёл для `textRenderer`/`localeIdentifier`:
`attach` — «one consistent initial host state», устанавливаемое до первого
`coordinator.invalidate(...)`, чтобы первый flush сразу видел финальное
окружение вместо двух проходов солвера (`false` → затем реальное значение).

`updateReduceMotion` — отдельный метод (не часть `updateBridgeState`'s общего
`updateSafeArea`/`updateLayoutDirection`/`updateLocaleIdentifier`), потому что
он несёт дополнительное побочное действие, которого нет у остальных трёх:
включение Reduce Motion **посреди** активного перехода должно немедленно
завершить уже идущие явные анимации (D67), а не просто пометить окружение
для следующего коммита. Это оправдывает отдельный именованный метод даже
притом что хосты вызывают его из того же `updateBridgeState()`, что и три
остальных — вызывающий код группирует их вместе, но семантика внутри
`NodeHostBridge` не идентична.

## Решение

Обновить baseline через `check_api.py --tvos --update --review-note
docs/adr/0016-node-host-bridge-attach-gains-reduce-motion.md`.
