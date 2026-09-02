# Finbar feature inventory (research, 2026-09-02)

Sources: finbarapp.com (overview, help, release notes through v1.22 of Jul 26 2026),
Product Hunt, Michael Tsai's blog, Keyboard Maestro forum, Homebrew cask, and an
inspection of the installed `Finbar.app` bundle (Info.plist, `finbar-cli -h`,
`defaults read com.roeybiran.Finbar`). No Finbar code was read or copied.

## Positioning

"Your own command palette in every app." Reimplements the Mac's built-in
Help-menu search: fuzzy, remembers what you use, filterable, extensible,
AppKit-native, fast. macOS 14.6+, one-time purchase (US$ 9.99+), Sparkle
updates, opt-in analytics, `LSUIElement` (no Dock icon).

## The palette window

- Summoned by a global hot key (user default in this machine: ⌃Space).
  Non-activating floating panel: the target app stays frontmost so its
  menu bar is the one being searched.
- Header: target app icon · borderless search field ("Search") · clear (⊗)
  button · segmented control List/Outline · "⋯▾" options menu.
- Body: sectioned list. Sections: **Recents**, **Menu Items**, **Scripts**
  on the root screen; **Search** when a query is active.
- Rows: leading glyph (menu-bar item = window-like rectangle, menu item =
  rectangle with lines, script = `{}` in a square, recent = small clock
  overlay), title with matched characters underlined, optional subtitle
  showing the item path ("Format › Font"), count badge for containers
  ("File 36"), trailing key-equivalent badge (grey capsule "⇧⌘M") and
  quick-selection badge (accent capsule "⚡⌘1"). Disabled items are dimmed
  but selectable. Mark characters (✓, •, –) are shown before the title.
- Footer: full path of the selected item on the left ("Format › Text"),
  item count on the right ("36 Items").
- Scope bar under the header when scoped: "⊗ Searching in: Format".
- Window is translucent, compact, rounded; width configurable; height
  auto-fits the row count; can be freely resized (minimum enforced);
  "Center Window" resets; remembers position as fractions of the screen;
  appears on the screen with the mouse / keyboard focus / a specific one;
  shows over full-screen apps.
- Themes: System Light, System Dark, Catppuccin, Dracula, Gruvbox,
  Solarized Dark, Solarized Light, Monokai + user-defined custom themes.
  Separate choice for light and dark appearance.
- Row text size option, hide subtitles, hide count badges, reduce-motion
  aware, skeleton loading state, inline error rows (e.g. app busy),
  fruitless-search view with "Search Help Menu" fallback button.

## Searching

- Fuzzy filtering; items below a certain depth are also matched by their
  containing menu's title ("Font › Bold").
- **List mode**: flattens everything into one list sorted by match score
  (recents boosted, relevance improvements in 1.20).
- **Outline mode**: keeps hierarchy; only menus containing matches are
  shown and expanded; if a parent title matches, all children are shown;
  best match is selected. Switching modes preserves the query.
- Search state (query, results, expansion) persists across invocations
  unless "Clear search state immediately" is on.
- Rules exclude items (and their descendants) before search.

## Keyboard model

| Keys | Action |
|---|---|
| ↑ ↓ | move selection while the field keeps focus |
| ⌥↑ ⌥↓ | first / last item |
| Home End PgUp PgDn | scroll / move by page |
| → ← | expand / collapse outline row (⌥ = recursively) |
| ↩ | activate item; on a container: descend (scope) |
| ⌘↩ | reveal the live menu item in the real menu bar |
| ⌘1…⌘9 | quick-select the first nine rows (badges always visible) |
| ⌫ on empty query | leave the scope (back to root) |
| ⌘F | focus the search field |
| ⌘W ⌘H Esc | close |
| ⌘, | settings |

## Recents / learning

Every activated item is remembered per app; the root screen lists the
most relevant recents; search results are ranked by "frecency"; dynamic
titles (e.g. "Undo Typing") are handled. "Clear Recents" exists.

## Rules

Standard macOS rule editor (NSPredicateEditor). Criteria: menu item's
title, path (backslash-separated: `View\Translation`), index (position among
siblings, separators count), depth (0 = menu bar item), application name,
bundle identifier; nested Any/All groups; multiple named rules; a warning
when rules remove everything.

## Scripts

Shell scripts / AppleScript files placed in
`~/Library/Application Scripts/<bundle id>/<target app bundle id>/` appear
as items under "Scripts"; file name = title; folder is watched for changes;
a Scripts settings pane lists what was loaded; failures are reported with
a user notification.

## CLI

`finbar-cli list [--predicate <NSPredicate>]` → JSON `{ "items": [ {title,
path[], indices[], shortcut?, mark?, bundle_id?} ] }` (excludes menu bar
items, submenus and disabled items). `finbar-cli select <index> <index>…`
clicks an item by positional path. `open -ga Finbar` activates it
programmatically.

## Settings (from UI, defaults keys and strings)

General: global shortcut (recorder), apps where the shortcut is disabled,
launch at login, show menu bar extra, preferred screen, clear search state
immediately, check for updates, accessibility permission status.
Appearance: light/dark theme pickers, theme editor, row text size, show
subtitles, show count badge, window width, floating settings window.
Rules · Scripts · License/About.

## Out of scope for the clone

Licensing/trial, Sparkle auto-updates (replaced by a "Check for updates"
link to GitHub Releases), TelemetryDeck analytics.
