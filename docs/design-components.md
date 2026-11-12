# Storebench design components

Every screen in Storebench is built from the shared components in `macos/Sources/StorebenchApp/DesignSystem` and the tokens in `macos/Sources/StorebenchCore/Resources/design.json`. Use them instead of raw SwiftUI controls, menus or tables, so buttons, rows and grids look and behave the same everywhere and people recognize where things are. These rules follow Apple's Human Interface Guidelines for [buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [layout](https://developer.apple.com/design/human-interface-guidelines/layout) and [settings](https://developer.apple.com/design/human-interface-guidelines/settings).

## Layout and density

Pages use 16–24 pt outer margins, 16 pt card padding and 12 pt between related components. Keep fields, their explanations and their commands together. Cards in a grid share a height within each row; longer copy wraps inside its column instead of widening the grid.

Settings use 8 pt between rows, one label column and a shared 300 pt control column. Narrow panes stack the control below its label. Field labels and hints each reserve one text line; static explanations grow when they need more room. A field whose feedback is shown separately can set its hint track to zero. Card headings group a small icon, a 15 pt title and its description on the same leading edge. Empty text tracks do not reserve several explanatory lines.

Tables use 32 pt headers and 44 pt rows. Full cell values remain available through the shared value inspector. Metric cards keep a compact label, value and explanation with their neighbors aligned.

## Table tools

`StorebenchTableControls` uses a native macOS search field with immediate results, a compact Sort menu and a Rows per Page menu. A scoped Filter menu shows the selected filter in its accessible value and hover help. These tools keep the shared control-height track; narrow views wrap without widening their surrounding cards. `StorebenchDataTable` groups tools, column headings, rows and the result/page footer in one surface. Column headings can sort, dividers can resize, and row actions belong in a trailing menu. Alternating system row colors help track wide tables. The full-value inspector stays available on click, with its info affordance shown on hover rather than repeated prominently in every cell.

Sheets keep a compact title row, a scrolling body with 16 pt insets and a separate command footer. Related sections use the same 12 pt spacing as workspace pages.

## Selections and menus

Selection fields use macOS popup buttons, with the system's menu placement, checkmarks, focus ring and keyboard navigation. A long selected value keeps its full title and explanation in hover help and VoiceOver. Searchable selections use a bounded list with arrow-key navigation. Independent options use native checkboxes; exclusive radio choices use compact shared rows that grow with their labels and support arrow keys.

Command menus group related actions with native separators and submenus. Keep destructive actions separate from ordinary commands. Section navigation uses quiet links; it does not compete with Save or Connect actions.

## Commands and their context

Secondary commands belong to the content they control. Cards and sections accept a compact header accessory; collection records keep it beside their disclosure, outside the expand and collapse target. A closed record keeps its menu available. Use `StorebenchIconMenu` for several secondary commands and `StorebenchIconButton` for a single recognizable action such as Refresh. Both use the shared square control footprint, hover help and an accessible name that identifies their scope.

Field commands sit beside the input through `StorebenchFormField` or `StorebenchPicker`'s accessory. Model refresh stays beside the model, and account options beside the account. Keep Save, Add, Connect and reviewed Sync actions visible in the form's command area.

Collection sort, page size, order, default expansion and page-wide expand or collapse actions live in the list's View Options menu beside its result count. Language card menus control that language's text section visibility, remembered across versions. The All Languages submenu explicitly applies a layout everywhere. Opening or closing one language's text section never changes another language's height. Layout preferences never change listing text.

Disclosure actions preserve the clicked heading's existing position in every enclosing native viewport, for both opening and closing. They never scroll an already visible heading to the top or force keyboard focus away from an editor. This applies to workspace pages, settings, sheets, nested inspectors and bulk layout commands. A shrinking page keeps only the scroll range needed to avoid clamping the working position; ordinary scrolling releases it without moving the content. Later measurements preserve the heading until a newer interaction takes over. Explicit navigation and Edit requests still reveal their destination. Use immediate layout updates. Language text headings repeat the language and name the fields inside the section. Separators distinguish adjacent text sections and the language card's heading from its editor.

## Pricing model context

Prices by Country or Region starts with the shared Price Model option group and its native Price Strategy selector. Keep the chosen model's explanation, guide price and country preview together. Show CSV input only for manually entered prices. Alternative pricing editors stay out of the selected model's workspace; Apple prices are shown for Apple's strategy or an explicit comparison. Keep Countries with No or Few Purchases available beside the focused workflow. Choosing a model changes local presentation and never approves a price update.

Preview Prices becomes Cancel Calculation in the same command slot while running. Reserve one status track for the source or Apple price-matching progress. Show calculated model amounts while Apple matches are checked, and distinguish Checking, Not Checked, No Estimate and No Match. Only a completed preview with a matched guide price can be saved. Changing an input cancels the obsolete calculation; a late result cannot replace the current model or feedback.

## Media ordering

Use the shared material selection, drag source and card toolbar for screenshot and preview ordering. A click selects; Command-click toggles membership and Shift-click selects a range. A double-click opens the screenshot. The visible Actions menu and native context menu expose the same move commands, with destructive actions separated at the end.

Show selection with a border and checkmark. Show insertion with one narrow accent edge and a subtle glow in the destination gap, after the preceding visible card when one exists. Dragging several records preserves their original relative order. Hover changes only feedback; committing a drop updates the order once. Keep the source enabled during its native drag session, and animate only the committed card movement and insertion feedback, respecting Reduce Motion.

## Image inspection and crop tools

Image viewers keep Previous and Next together, zoom in its own group, and Download Original at the trailing edge. The shared media toolbar keeps these groups intact and uses two rows in narrow sheets. Zoom Out and Zoom In use adjacent minus and plus buttons; both stay visible at the zoom limits. A native slider and percentage popup share that row. The popup offers Fit Image and magnification presets; double-click switches between Fit and 100%.

Crop editors reuse the same zoom controls with a 100–400% range. Recenter Crop belongs beside Crop and Zoom, while orientation, frame settings and file quality stay with their own labels. Keep the last rendered preview visible until its replacement is ready, preserving its proportions. Card navigation, duplication and Undo/Redo use compact shared tools beside the card list; destructive commands stay in its options menu.

## Release submission

Quick Release uses the shared step grid: a fixed step rail beside one working pane, stacked above it on narrow windows. The numbers 1–4 stay visible beside status icons and labels. Its four steps are Prepare Release, What's New in This Version, Add Build and Add for Review. Back and Next move inside Quick Release. Add Build names the build command and its approval sheet. Add for Review opens a separate submission approval; creation has its own Create Version approval. Each sheet shows the exact change before sending. Save Draft keeps work local without opening approval. Submission reuses the version and build already chosen in the flow. Green checks mean ready, yellow means checking, unsaved work, pending sync or approval, and red means missing or invalid required information. A normal prepared update reuses its checked listing and settings; release notes and the new build remain required. Unknown checks never turn green. A version creation blocked by Apple names the current version and state, with a direct link to that platform’s version. Open Version recovery opens the version settings instead of returning to the sync panel. Other listing text and release details start collapsed, with their statuses and Edit commands in shared status rows. Changing steps or closing a section keeps mounted editors and unfinished inputs. Saves, sync reviews and requirement fixes stay on this page. The normal text review sends the quick fields; opening Other Listing Text also enables a text-only review of those additional fields, without sending screenshots.

Overview shows compact release rows with an independent Continue Release command and a disclosure for details. Each account, app, platform and version remembers its expanded or minimized state across visits; changed status and updated plans do not reopen a minimized version. New versions follow the Release Cards default in General settings, initially Expanded. Expand All and Minimize All act on the entire release list. Minimizing the last expanded card can show the native “Minimize all by default?” window-modal popup with Yes, Ask Later and No. The popup overlays its window without adding a card or moving page content. It never appears just from restoring a saved layout. Ask Later postpones it one day; Escape chooses Ask Later. No disables the suggestion until enabled in Settings.

Expanded release details show Apple's current state, up to three requirements and an And More count. The smaller Release card in Apps shows the next requirement and a count for the rest. Missing fields, work to review and unconfirmed checks remain distinct. Submitted versions show their Apple state without repeating old preparation blockers. Reserve summary and feedback tracks so background updates do not move adjacent commands. The app's Release card keeps the workflow grid shared with its other cards. Longer overview release lists use the shared pagination and View Options.

Settings keeps a shared search field above the pane. Search results identify the setting and its pane, and opening a result reveals its section, including settings inside collapsed groups. Searching keeps the current editor mounted, so clearing a query retains unfinished inputs. Moving to a different pane still goes through the existing save and discard review. Search indexes public setting labels and explanations; it never indexes saved account names, credentials or values.

Release states open from their last encrypted local observation and are checked again after unlock. Small version-state reads are shared, limited to two concurrent apps and refreshed periodically behind visible work. Failures retain the last confirmed state and show that its latest check failed. Full preparation follows the configured preparation limit. These reads do not import revisions or send changes to Apple.

Add for Review shows one ordered list of confirmed missing requirements across the release. Resolve Next Item opens the relevant field or step and keeps a return to the submission checklist. Unknown checks remain distinct from missing answers. App Privacy and Tax Category can be completed inside the submission step using their existing forms, local drafts and guarded Apple reviews.

Current Apple state takes precedence over an older failed submission attempt. Waiting for Review and later states show that the version is already submitted; the flow offers its next release step instead of another submission. Preparation commands show why they are unavailable beside the command. A press during a read is retained until the choices settle. Preparing or resuming a review never approves it.

## Refresh and sync feedback

Refresh Status updates the current release step's cards and its checklist through one freshness boundary. Matching Apple reads are shared across those cards. Keep editors and their layout mounted while refreshing. With unsaved inputs, show Save, Discard and Cancel: Save uses the existing local draft validators; Discard restores saved drafts; Cancel keeps editing. A changed editor or newer input invalidates an earlier choice. Failed saves keep inputs and stop the refresh.

Current sync cards compare with Apple again after saved fixes and explicit refreshes. A stopped run remains in history; its old refusal is not a current comparison. Show a green check and a checked or synced time beside the material when Apple matches, including when there is nothing left to send. Clear that indication when the inputs change. Preparing a comparison or refreshing a card never approves an Apple write.

## Text comparisons

`StorebenchTextDifference` uses the shared word markings: added text is green and bold, removed text is red and struck through. Listing editors expose View Changes beside the changed-field count and in their command footer. The comparison opens a read-only snapshot, shows changed fields together and can compare the import or the loaded draft. Exact before and after text remains available within each field.

## Buttons

Standard buttons share one width, the `action-width` token (192 pt). The width is the same for a button on its own, in a group and as a row command, whatever its label. Buttons of the same size show that they belong together, and buttons of mixed sizes next to each other look inconsistent.

Tell buttons apart by style, not size. `StorebenchButtonStyle` has the variants: primary for the most likely action in a view (one, at most two, per view), secondary for other actions, quiet for low-emphasis commands and danger for destructive ones. A destructive button is never primary.

Primary, secondary and destructive standard actions use macOS push buttons, including system press, focus and disabled states. Quiet commands have no persistent border; their hover and press surfaces provide feedback without competing with the primary action.

Only a few controls size themselves differently. Icon buttons (`size: .icon`) are square at the control height, choice chips such as the date presets use natural widths, and stretched tiles (`stretch: true`) fill their tile up to `action-max-width`. `StorebenchSectionLinks` uses natural-width quiet targets to navigate within a page and wraps them when needed.

Every button keeps the shared control height, `control-height`, and its label on one line.

## Button labels

Write labels in title-style capitalization and start with a verb, such as "Connect Reports", "Sync New Data" or "Add for Review". Short words such as "and", "for", "in", "of", "to" and "with" stay lowercase inside a label. This applies to labels that come from data files too, such as recovery actions and sync modes.

End a label with an ellipsis when the button opens another window, sheet or file panel for more input, such as "Import CSV…" or "Custom…".

A label must fit the shared width, which leaves about 160 pt for 13 pt text. When it does not fit, shorten the label and put the full meaning in `.help(...)`, for example "Open App Review" with the help "Open App Review Information". Never widen the button or let the label wrap.

Use App Store Connect's exact names for its sections, states and actions, shortened only as described above.

## Button groups and footers

`StorebenchActionGroup` places related buttons in a row at the shared width and wraps them into complete rows on narrow windows. Groups start on the same leading edge as the text they belong to.

`StorebenchFormFooter` is the final command area of a card or form, below a divider. Put the primary action first. Contextual editor footers span the form width even when nested inside a command group; only individual buttons use button-sized cells. Group Save Draft and Sync to Apple inside the same contextual footer, and keep Refresh beside the card heading. Feedback and explanations share the full copy track instead of wrapping inside a narrow button column.

`StorebenchCommand` is a button that can be busy or unavailable; its reason shows as hover help, so the button stays in place instead of disappearing.

## Where controls belong

Every button, spinner and progress bar sits in a shared component that owns its place, never loose in a card body or beside text in an ad-hoc row.

- Read and refresh commands go in the card header through the card's accessory or actions.
- The card's work goes in `StorebenchFormFooter` or the editor footer.
- Related commands inside a step, disclosure or record go in `StorebenchActionGroup`, and natural-width choice chips such as date presets go in `StorebenchChipGroup`.
- A record line with its own commands uses `StorebenchActionRow`: the copy on the leading track and the commands on a trailing track that moves under the copy in narrow windows.
- A command that acts on one field uses `StorebenchInputActions`, `StorebenchFieldCommands` or the field's accessory.
- A table's command column uses `StorebenchTableActions`, and a record name that opens its record uses `StorebenchRecordLink`.
- A preview that opens, enlarges or plays itself uses `StorebenchMediaButton`; while its file is read, `StorebenchMediaStatus` shows the spinner or the reason nothing is drawn.
- A running operation shows one `StorebenchProgressStatus` line, with a bar when its amount is known and its label in a fixed track. Loading content uses `StorebenchLoadingStatus`. A step that is running or failed shows `StorebenchStepState` beside its name.
- Ranked shares, such as the leading territories, use `StorebenchShareRow`; its bar is a measure, not progress.

## Status rows

`StorebenchStatusRow` is the list row for sources, checks and history items. It has fixed columns, so rows line up from row to row and screen to screen:

- the title and detail on the leading side, growing to fit their text
- the status, such as a sync badge or a state, in one column of `statusColumn` width (124 pt)
- the row command, such as Open, Change or Open Review, in the trailing column at the shared button width
- extra buttons for the row, such as recovery actions, in a group under the title at the shared width

Do not pass a custom command width. On narrow windows the row stacks: the title above, then the status and the command on one line.

`StorebenchSyncBadge` fills the status column, so every badge has the same width whatever its label.

## Text and status areas

Reserve space for labels, hints, status and comparisons before they appear, so updates never move the layout. Static text grows to show all of it, up to about eight lines, then scrolls. Live status and feedback, such as `StorebenchFeedback` and `StorebenchTextSlot`, keep a fixed height sized for realistic messages. Nothing is clipped without a way to read it.

An Edit action reveals its section and requests keyboard focus through the shared text control. Keep the native input mounted when saving or ending a focused edit. Field feedback and Done actions reserve their tracks before they appear. Expanding sections and revealing fields use an immediate layout update, so scrolling does not compete with animated changes in editor height.

Media edits opened from the release checklist use `StorebenchEditorGuide`: a named section, complete instructions and a Done action within one padded surface. Explain that Done saves locally and returns to the checklist, while Sync to Apple opens a separate review. Static instructions grow with their text; narrow panes place the command below them. Keep the guide separate from the media cards that follow, with the shared section gap between their borders.

Field focus frames extend 8 pt into the surrounding padding. They never touch the input or its feedback, and showing or hiding a frame never changes the editor's geometry. Do not draw a focus surface behind nested media cards or place unpadded instructions on its edge.

Cards that share a row share its height, so their buttons sit on one bottom edge.

## Icons and colors

Icons come from the registry in `design.json` through `StorebenchIcon`; do not use system symbols directly. Native menus use template images drawn from the same registry. Colors come from the named tokens through `StorebenchTheme.color(_:)`, with light, dark and increased-contrast values for each. Native table surfaces, alternating rows and search fields use macOS semantic colors and control rendering.
