# Storebench design components

Every screen in Storebench is built from the shared components in `macos/Sources/StorebenchApp/DesignSystem` and the tokens in `macos/Sources/StorebenchCore/Resources/design.json`. Use them instead of raw SwiftUI controls, menus or tables, so buttons, rows and grids look and behave the same everywhere and people recognize where things are. These rules follow Apple's Human Interface Guidelines for buttons.

## Buttons

Standard buttons share one width, the `action-width` token (192 px). The width is the same for a button on its own, in a group and as a row command, whatever its label. Buttons of the same size show that they belong together, and buttons of mixed sizes next to each other look inconsistent.

Tell buttons apart by style, not size. `StorebenchButtonStyle` has the variants: primary for the most likely action in a view (one, at most two, per view), secondary for other actions, quiet for low-emphasis commands and danger for destructive ones. A destructive button is never primary.

Only a few controls size themselves differently. Icon buttons (`size: .icon`) are square at the control height, choice chips such as the date presets use natural widths, and stretched tiles (`stretch: true`) fill their tile up to `action-max-width`.

Every button keeps the shared control height, `control-height`, and its label on one line.

## Button labels

Write labels in title-style capitalization and start with a verb, such as "Connect Reports", "Sync New Data" or "Add for Review". Short words such as "and", "for", "in", "of", "to" and "with" stay lowercase inside a label. This applies to labels that come from data files too, such as recovery actions and sync modes.

End a label with an ellipsis when the button opens another window, sheet or file panel for more input, such as "Import CSV…" or "Custom…".

A label must fit the shared width, which leaves about 160 pt for 13 pt semibold text. When it does not fit, shorten the label and put the full meaning in `.help(...)`, for example "Open App Review" with the help "Open App Review Information". Never widen the button or let the label wrap.

Use App Store Connect's exact names for its sections, states and actions, shortened only as described above.

## Button groups and footers

`StorebenchActionGroup` places related buttons in a row at the shared width and wraps them into complete rows on narrow windows. Groups start on the same leading edge as the text they belong to.

`StorebenchFormFooter` is the final command area of a card or form, below a divider. Put the primary action first.

`StorebenchCommand` is a button that can be busy or unavailable; its reason shows as hover help, so the button stays in place instead of disappearing.

## Status rows

`StorebenchStatusRow` is the list row for sources, checks and history items. It has fixed columns, so rows line up from row to row and screen to screen:

- the title and detail on the leading side, growing to fit their text
- the status, such as a sync badge or a state, in one column of `statusColumn` width (124 px)
- the row command, such as Open, Change or Open Review, in the trailing column at the shared button width
- extra buttons for the row, such as recovery actions, in a group under the title at the shared width

Do not pass a custom command width. On narrow windows the row stacks: the title above, then the status and the command on one line.

`StorebenchSyncBadge` fills the status column, so every badge has the same width whatever its label.

## Text and status areas

Reserve space for labels, hints, status and comparisons before they appear, so updates never move the layout. Static text grows to show all of it, up to about eight lines, then scrolls. Live status and feedback, such as `StorebenchFeedback` and `StorebenchTextSlot`, keep a fixed height sized for realistic messages. Nothing is clipped without a way to read it.

Cards that share a row share its height, so their buttons sit on one bottom edge.

## Icons and colors

Icons come from the registry in `design.json` through `StorebenchIcon`; do not use system symbols directly. Colors come from the named tokens through `StorebenchTheme.color(_:)`, with light, dark and increased-contrast values for each.
