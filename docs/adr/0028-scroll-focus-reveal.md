# ADR 0028 — раскрытие ScrollNode перед focus и AX-прокрутка

Дата: 2026-09-22. R08. Уточнение D37/D38/D44 согласовано пользователем в этой сессии.

Скрытые committed элементы могут участвовать в поиске **цели раскрытия**, но не
становятся focus/AX-кандидатами до появления видимой области. Геометрия, opacity,
обычные clip-предки, enabled, live route и modal scope продолжают проверяться.
Поиск использует физические направления и score D38, committed traversal order
при равенстве, preferredNext до геометрии. Видимая выбранная цель остаётся делом
существующего focus engine. Нельзя прокрутить скрытую цель через обычный clip.

Для скрытой цели сначала рассчитываются offsets всех scroll-предков изнутри наружу.
Проверяется, что итог действительно видим; затем синхронные native scroll commands
раскрывают её без анимации. Это не создаёт фоновых задач или отложенных запросов;
Reduce Motion не требует отдельного пути. ScrollNode с выключенным input и активное
пользовательское движение не перехватываются. После каждого callback проверяется
mount, после раскрытия — текущая eligibility и scope.

Если прежний focus полностью уйдёт из viewport, он очищается до публикации offset,
чтобы fallback не присвоил новой карточке focus до подтверждения платформы.
На tvOS стрелка раскрывает цель и выставляет pending native request; только
`didUpdateFocus` подтверждает новую identity (`reason: .native`). Для обычного
keyboard focus bridge после раскрытия выполняет штатный переход. Прямой
`focus(offscreenID)` по-прежнему отклоняется: нового публичного API не добавлено.

AX scroll — отдельный путь, не перемещение keyboard focus или VoiceOver cursor.
UIKit proxy принимает `accessibilityScroll`; AppKit публикует доступные page actions
через `NSAccessibilityCustomAction`. Action прокручивает ближайшего eligible
ScrollNode-предка на размер viewport по физическому направлению; на границе может
перейти к следующему предку внутри scope. Stale endpoint/epoch, hidden/disabled,
нет движения или активный input возвращают false. Снимки обновляются тем же
native offset-путём без solve/raster. Новые UI-названия живут только в адаптере.

## API baseline review

R08 не добавляет public declarations: новые cross-module helpers имеют `package`
access. Проверка baseline обнаружила ранее не снятые изменения ADR 0027 и первой
части R08: `NativeScrollBacking.makeChildBacking`, `contentOriginInHost`,
`apply(configuration:)`, `dispose`, `setFrame(_:relativeTo:)` вместо `setFrame(_:)`,
а также default implementation `makeChildBacking`. Обновление baseline в этой
сессии включает именно эти уже описанные протокольные изменения; остальные
модули имеют только изменения source-location metadata.
