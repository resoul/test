# T08 — Accessibility текста (`TrellisCore`)

Дата: 2026-09-12. Карточка [implementation-plan-4.md](../implementation-plan-4.md) §5,
реализует D57. Зависит от T04 ([t04-text-node.md](t04-text-node.md)) и A06
(готово, [a06-semantic-tree.md](a06-semantic-tree.md) — сверено:
`AccessibilityTree`/`SemanticSnapshot`/адаптеры не менялись, значение
`accessibility` читается тем же путём независимо от источника).

## 1. Что добавлено

`Sources/TrellisCore/Text/TextNode.swift` — `syncAccessibilityDefaults()`:

- Вызывается из `init` (после `super.init`, когда `id`/`environment` уже
  существуют для `markSemanticsDirty`) и из `document`'s `didSet` при каждом
  реальном изменении текста.
- Заполняет `accessibility.isElement = true`, `label = <plain characters>`,
  `role = .text`, по одному полю — не трогая поле, которое автор явно
  переопределил.
- «Автор победил» отслеживается тремя приватными теневыми полями
  (`lastAutoIsElement: Bool?`, `lastAutoLabel: String??`,
  `lastAutoRole: AccessibilityRole??`) — сравнение текущего значения
  `accessibility.<поле>` с тем, что сама нода последний раз туда
  записала. Не флаг на `AccessibilityProperties` (тип общий для всех `Node`,
  не должен нести понятие «автоматическое vs. авторское» ради одного
  подкласса) — компромисс, явно принятый в D57's addendum.

Ничего менять в `AccessibilityTree`, `SemanticSnapshot`, UIKit/AppKit-адаптерах
не потребовалось — `.combine`, резолв роли и маппинг `.text`/`.header` уже
работали по значению `accessibility`, откуда бы оно ни пришло.

## 2. Найденный и исправленный баг: override «забывался» на второй смене текста

Первая версия `syncAccessibilityDefaults()` безусловно перезаписывала все три
теневых поля после проверки `if`'ов:

```swift
lastAutoIsElement = updated.isElement
lastAutoLabel = updated.label
lastAutoRole = updated.role
```

Если автор переопределил поле (например, `accessibility.isElement = false`),
`updated.isElement` на этом вызове остаётся `false` (веткa `if` не сработала,
значение не переписывалось на `true`) — но строка выше всё равно
записывает `lastAutoIsElement = false`, то есть **авторское** значение
становится «последним автоматическим». На следующей смене текста проверка
`accessibility.isElement == lastAutoIsElement` (`false == false`) ложно
считывается как «автор ничего не трогал», и `isElement` тихо возвращается к
`true` — override пропадает не сразу, а после второй смены текста.

Обнаружено регрессионным тестом до коммита карточки
(`t08_optOutSurvivesASecondTextChangeTooNotJustTheFirst` — не попало в
зафиксированный код ни разу, поэтому запись здесь, а не в
[defects.md](../defects.md), тем же принципом, что T05's
`CTParagraphStyleSetting` находка). Исправлено: каждое теневое поле
обновляется только внутри своей ветки `if` — если ветка не сработала (override
в силе), теневое значение остаётся замороженным на последнем настоящем
автоматическом значении, и живое значение продолжает расходиться с ним
навсегда, пока override не будет снят автором явно.

Один оставшийся, документированный в коде предел: если автор присвоит полю
**точно** то значение, которое уже показано автоматически, синхронизация не
отличит это от «нетронуто» и может переписать его на следующей смене текста —
узкое совпадение, которое T08's приёмка не требует закрывать (только то, что
*настоящий* override — почти всегда другая строка/роль — переживает
дальнейшие изменения).

## 3. Тесты и результаты

14 новых тестов, весь пакет зелёный на трёх платформах:

| Платформа | TrellisCoreTests | TrellisRenderTests |
|---|---|---|
| macOS (`swift test`) | — | — (585 тестов пакета целиком) |
| iOS 26.5 Simulator | 419/419 | 163/163 |
| tvOS 26.5 Simulator | 419/419 | 163/163 |

- `Tests/TrellisCoreTests/Text/TextNodeAccessibilityTests.swift` (10) —
  заполнение по умолчанию при создании и на смену текста; republish semantics
  даже когда автор не трогал accessibility; тот же текст — no-op; авторский
  label/role/`isElement`-опт-аут/полная замена `accessibility` переживают
  дальнейшие смены текста; пустая строка заполняет label.
- `Tests/TrellisCoreTests/Semantics/AccessibilityTreeTests.swift` (+2) —
  native дерево видит `label == text` для реальной `TextNode`; `.combine`
  объединяет несколько `TextNode` в один label в порядке чтения.
- `Tests/TrellisRenderTests/TextNodeInvalidationTests.swift` (+2) — смена
  текста с итоговым размером, совпавшим с прежним (`PortableTextMeasurer`'s
  модель даёт одинаковый размер для строк одной длины), всё равно даёт flush
  через `geometryRevision`, не завязана на изменение самого frame; чисто
  AX-правка (`node.accessibility.label = ...`) идёт semantics-only без нового
  layout snapshot.

## Приёмка T08

- `TextNode` заполняет `accessibility` по D57, автор побеждает; label из
  plain characters; явный override отличим от автоматического значения —
  done, §1-2, `t08_anAuthoredLabelSurvivesLaterTextChanges`,
  `t08_optOutSurvivesASecondTextChangeTooNotJustTheFirst`.
- Смена текста проходит measurement при metric-инвалидации даже если итоговый
  размер совпал; AX-override — semantics-only fast path — done,
  `t08_textChangeWithTheSameMeasuredSizeStillFlushes`,
  `t08_axOnlyOverrideTakesTheSemanticsOnlyFastPathWithoutANewLayoutSnapshot`.
- VoiceOver-роли `.text`/`.header` через существующий mapping A09/A10 — не
  изменялись, значение `accessibility.role` те же пути читают независимо от
  источника; ручная проверка на устройстве/симуляторе с VoiceOver не
  выполнялась (не проверено — как и во всех прежних карточках без физического
  доступа к устройствам).

Следующая карточка — T09 (Environment в хостах: `TextRendererKey`/`LocaleKey`
на `attach`).
