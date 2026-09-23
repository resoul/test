# ADR 0001 — `Node.style`/`Node.appearance` gain `didSet`

Дата: 2026-09-10. Часть C09.

## Изменение

`api/TrellisCore.json` помечает эти два символа как `changed`, а не `added`,
потому что API baseline снимает `declarationFragments` из symbolgraph:

```
- @MainActor var appearance: VisualStyle
+ @MainActor var appearance: VisualStyle { get set }
```

То же для `style`. Причина — переход от простого stored property (C07/C08) к
property с `didSet` (C09), который сравнивает `oldValue` с новым значением и
вызывает `markGeometryDirty`/`markAppearanceDirty` только при реальном
изменении. Symbolgraph показывает `{ get set }` явно, как только у property
появляется наблюдатель, хотя снаружи модуля тип, читаемость и записываемость
не изменились.

## Почему это не breaking change

- Внешний consumer как читал/писал `node.style`/`node.appearance` напрямую,
  так и продолжает — `check_consumer` в `verify_bootstrap.py` не менялся для
  этого и по-прежнему проходит без `@testable`.
- Никакой явный тип, доступность или направление доступа (get/set) не
  изменились; different произошло только в машинно-читаемом описании
  accessor-кind, которое сама библиотека API-diff видит как «другое», а не
  «совместимое дополнение».

## Решение

Обновить baseline через этот ADR как review-note, не ослабляя правило
`check_api.py` («removed/changed требует ADR»): единичный, явно
задокументированный случай лучше, чем исключение из линтера.
