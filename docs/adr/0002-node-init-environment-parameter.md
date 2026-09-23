# ADR 0002 — `Node.init` gains an `environment` parameter

Дата: 2026-09-10. Часть C10.

## Изменение

`api/TrellisCore.json` помечает старый инициализатор как `removed` (а не
`changed`), потому что добавление параметра меняет mangled-имя символа:

```
- init(style: LayoutStyle = LayoutStyle(), appearance: VisualStyle = VisualStyle())
+ init(style: LayoutStyle = LayoutStyle(), appearance: VisualStyle = VisualStyle(),
+      environment: EnvironmentScope? = nil)
```

## Почему это не breaking change для существующих вызовов

Новый параметр `environment` — с дефолтом `nil` в конце списка. Каждый
существующий вызов (`Node()`, `Node(style: …)`, `Node(style:appearance:)`)
продолжает компилироваться и вести себя одинаково: `nil` даёт узел без
унаследованного окружения, ровно как раньше. Единственный внешний consumer
(`Scripts/verify_bootstrap.py::check_consumer`, `Card: Node`) не менялся и
проходит без правок.

Ломается только *бинарная* сигнатура (mangled name), что для source-уровня
Swift-пакета без ABI-стабильности не является проблемой на этом этапе.

## Решение

Обновить baseline через этот ADR: единственный практический эффект —
`Node(environment:)` теперь можно передать сразу при создании узла (C10),
не только через отдельный вызов `inheritEnvironment(from:)` после.
