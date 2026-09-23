# ADR 0034 — TableNode, row actions and swipe policy

Date: 2026-09-23. Card: R12c, plan 6. Status: accepted. Builds on ADR 0030–0033 and P6.6.

## Context

Result C needs a table with rows in sections, separators, selection and swipe actions (P6.6):
leading/trailing, several actions, full swipe, RTL, correct behaviour on update/delete,
failure/retry, alternative input and accessibility, and a policy so a pager can take the
horizontal gesture. It must use the shared collection runtime.

## Decision

- **Rows with context.** `CollectionNode` gains a source → window transform, so the source can
  keep the user's items while the window sees `TableRow<Item>`: value, section ID, first/last in
  section, selection. Context is part of equality, so moving to the first/last position or a
  selection change updates the cell in place. Lists and grids use the identity transform. The
  loader keeps reading the untransformed source (ADR 0032's synchronous completion).
- **Cells.** `TableCellProvider` wraps the user's provider; `TableCellNode` holds an optional
  section header (composed into the section's first row, not sticky), the row — action buttons
  underneath and the user's content on top, shifted by the reveal — and a separator (hidden on
  a section's last row). Selection is table state (`selection`, `selectionMode`) that a model
  may own; taps also reach `events.onSelect`.
- **Gestures.** `RowSwipeRecognizer` begins only when the first movement past its threshold
  is at least as horizontal as vertical; vertical drags fail it and stay with the native
  scroll view (the table's ScrollNode uses directional lock). The tap recognizer sits on the
  content, so a tap on a revealed action button is not also a row tap.
- **Swipe state.** `RowSwipeController`: one open row by item ID; reveal past half the buttons
  opens, past `fullSwipeFraction` of the width performs the side's first action (when
  `allowsFullSwipe`); a side without actions does not open. An action receives the item ID; a
  running action blocks repeats; completion closes the row; failure keeps it open in `.failed`
  with a Retry button; a row removed from the data closes and its action never moves to a
  neighbour or repeats. `.leading`/`.trailing` are reading-direction sides; right-to-left
  mirrors the physical drag and offset.
- **Policy.** `SwipeActionsPolicy` `.automatic` (default), `.disabled`, `.enabled`;
  `.automatic` follows `RowSwipeContextKey` (environment, layout- and paint-neutral), which a
  composite container sets to `false`; `.enabled` overrides it. Live cells re-evaluate the
  policy on policy changes and every host commit. Disabling the gesture never removes the
  actions.
- **Accessibility.** The row content is one element (combined children) carrying the item's
  identifier, selection and the actions as custom actions, performed through the same
  controller; the section header and revealed buttons (role `.button`) are separate elements.
  VoiceOver, switch control and the macOS/tvOS accessibility paths reach every action without
  the gesture.

## Consequences

`CollectionNode` is generic over the provider and the source item type
(`CollectionNode<Provider, SourceItem>`). Sticky section headers, context menus and
keyboard shortcuts for row actions are not part of this card; accessibility custom actions are
the non-gesture path. The pager's use of `RowSwipeContextKey` is R14.
