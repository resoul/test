# ADR 0003 — C12 flexbox port: two non-breaking `LayoutResult`/`LayoutInputSnapshot` API changes

Дата: 2026-09-10. Часть C12.

## Изменение 1 — `LayoutResult.init` получил `environmentRevision`/`contentRevision`

`api/TrellisCore.json` помечает старый 2-аргументный `init(placements:treeIdentity:)`
как `removed` (не `changed`) — добавление параметров меняет mangled-имя.

Причина: у Weave `LayoutResult` всегда нёс `environmentRevision`/`contentRevision`
для staleness-проверки на commit (сравнение с текущими ревизиями живого дерева).
C11 (сделанная до реального движка) сознательно оставила эти поля не перенесёнными,
потому что производителя ещё не было. Теперь `FlexboxEngine.layoutContainer` —
этот производитель: он получает оба значения прямо из `LayoutInputSnapshot`
(`input.environmentRevision`, `input.contentRevision`) и должен передать их
дальше в результат, иначе `LayoutResult` не сможет сообщить, из какого
состояния дерева он посчитан.

Новые параметры — с дефолтом `0` в конце списка, поэтому оба существующих
2-аргументных вызова (C11 тесты, внешний consumer не использует
`LayoutResult` напрямую) продолжают компилироваться без изменений.

## Изменение 2 — `LayoutInputSnapshot.init`'s `style` получил дефолт `LayoutStyle()`

Помечено `changed`, не `removed`/`added` — сигнатура (типы, лейблы) не
менялась, только declaration fragment показывает добавленный дефолт.

Причина: перенесённые тесты Weave используют `LayoutInputSnapshot(identity:
children:)` без `style` (Weave: `style: LayoutStyle = LayoutStyle()` уже был
дефолтным). Trellis-версия C10 по недосмотру объявила `style` обязательным —
несоответствие обнаружено при порте C12 и исправлено сейчас, а не
унаследовано молча.

## Почему обе правки не breaking

Оба изменения — чисто аддитивные для вызывающего кода: любой существующий
вызов с явным `style`/`environmentRevision`/`contentRevision` компилируется
как раньше. Единственный эффект — новые вызовы могут опускать эти
аргументы. Внешний consumer (`verify_bootstrap.py`) не создаёт ни
`LayoutResult`, ни `LayoutInputSnapshot` напрямую и не требует правок.
