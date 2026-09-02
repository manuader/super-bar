<p align="center">
  <img src="App/SuperBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="SuperBar icon">
</p>

<h1 align="center">SuperBar</h1>

<p align="center">
  A native, keyboard-first command palette for the menu bar of every Mac app.<br>
  Free and open source. Built with AppKit and SwiftUI, no dependencies.
</p>

---

Press a hot key in any app and SuperBar shows that app's entire menu bar as a
searchable palette: fuzzy search, learned favourites, outline browsing,
rule-based filtering, your own scripts, themes and a CLI. It is a
feature-complete, MIT-licensed alternative to [Finbar](https://www.finbarapp.com/).

## Features

| | |
|---|---|
| **Fuzzy search** | fzf-style matcher with match highlighting; deep items are found by their parent too ("Font › Bold"). |
| **List and outline modes** | *List* (⌘L) is flat: menus are rows you enter with ↩ or → and leave with ⌫ or ←, and search results are one list ranked by relevance with the item's path underneath. *Outline* (⌘O) is the real hierarchy: expand and collapse with → and ←, and while searching only the branches that contain matches stay open. The query is preserved when switching. |
| **Recents / frecency** | Every item you activate is remembered per app; the root screen lists your favourites and search results are boosted. Dynamic titles ("Undo Typing") keep their history. |
| **Browse and scope** | Walk menus with → and ←, press ↩ on a submenu to search only inside it, ⌫ on an empty query to go back. |
| **Quick selection** | ⌘1 … ⌘9 activate the first nine rows; badges are always visible. |
| **Reveal** | ⌘↩ opens the real menu and highlights the item, without triggering it. |
| **Key equivalents and marks** | Shortcuts (⇧⌘M) and marks (✓) are shown exactly as in the menu bar. Disabled items are dimmed but selectable. |
| **Rules** | The standard macOS rule editor excludes items (and everything inside them) by title, path, index, depth, app name or bundle identifier. Regular expressions supported. |
| **Scripts** | Shell scripts and AppleScript files in `~/Library/Application Scripts/com.manuader.SuperBar/` become palette items, globally or per app. The folder is watched. |
| **Themes** | System Light/Dark (translucent, follows your accent colour), Catppuccin, Dracula, Gruvbox, Solarized Dark/Light, Monokai, plus a custom theme editor. Separate light and dark choices. |
| **Fallback search** | No results? One click searches the app's own Help menu. |
| **Native** | Non-activating floating panel, SF Symbols, system materials, Reduce Motion aware, appears over full-screen apps, multi-display aware. |
| **CLI** | `superbar-cli list --predicate '…'` and `superbar-cli select 3 1` for automation tools. |

## Install

Requirements: macOS 14 Sonoma or later (tested on Sequoia and Tahoe).

1. Download `SuperBar.app` from the [Releases](https://github.com/manuader/super-bar/releases) page, or build it yourself (below), and move it to `/Applications`.
2. Launch it. SuperBar lives in the menu bar (no Dock icon).
3. Grant **Accessibility** access when asked (System Settings › Privacy & Security › Accessibility). Menus can only be read through the Accessibility API.
4. Press **⌃Space** in any app.

`open -ga SuperBar` toggles the palette from scripts and launchers without stealing focus.

## Keyboard

| Keys | Action |
|---|---|
| ⌃Space | Show / hide (configurable) |
| type | Fuzzy-filter |
| ↑ ↓, Tab / ⇧Tab | Move selection |
| ⌥↑ ⌥↓, Home, End | First / last item |
| Page Up / Page Down | Move by a page |
| → / ← | Outline: expand / collapse (⌥ for all levels); ← on a leaf selects its parent. List: enter / leave a menu |
| ↩ | Activate; on a submenu: search inside it |
| ⌘↩ | Reveal the item in the real menu bar |
| ⌘1 … ⌘9 | Quick-select |
| ⌫ (empty query) | Leave the current scope |
| Esc | Clear the query, then close |
| ⌘L / ⌘O | List / outline mode |
| ⌘F | Focus the search field |
| ⌘, | Settings |
| ⌘W / ⌘H | Close |

## Rules

Settings › Rules. Each rule is an `NSPredicate` built with the standard rule
editor. Criteria: *Menu Item's title*, *Menu Item's path*
(backslash-separated, e.g. `View\Translation`), *Menu Item's index*
(position among siblings, separators count), *Menu Item's depth* (0 for a
menu bar item), *Application's name*, *Application's bundle identifier*.
Nest *Any / All / None* groups freely. A matching item and its descendants
are removed before searching.

## Scripts

Put files in `~/Library/Application Scripts/com.manuader.SuperBar/`
(Settings › Scripts › Open in Finder creates it):

```
~/Library/Application Scripts/com.manuader.SuperBar/
├── Toggle Dark Mode.applescript        ← every app
└── com.apple.Safari/
    ├── Close Tabs to the Left.sh       ← Safari only
    └── Open as Private Tab             ← executable with a shebang
```

The file name (without extension) is the title. AppleScript files run through
`osascript`; executable files run directly; other files use their shebang or
the usual interpreter for their extension. Scripts get
`SUPERBAR_APP_NAME`, `SUPERBAR_APP_BUNDLE_ID`, `SUPERBAR_APP_PID` and
`SUPERBAR_SCRIPT_TITLE` in the environment; a non-zero exit shows a
notification with the error output.

## CLI

`SuperBar.app/Contents/MacOS/superbar-cli` (symlink it into your `PATH`). The
terminal that runs it needs Accessibility access.

```bash
superbar-cli list                                      # JSON of the frontmost app's items
superbar-cli list --predicate 'path BEGINSWITH "File"' # title, path, appName, bundleIdentifier, index, depth
superbar-cli select 0 1                                # click the 2nd item of the Apple menu
```

## Building

```bash
brew install xcodegen
make test       # SuperBarKit unit tests (swift test)
make build      # generate SuperBar.xcodeproj and build Debug
make run        # build and launch
make release    # Release build in build/SuperBar.app
make install    # copy to /Applications
make snapshot   # render the palette from fixture data into snapshots/*.png
```

The project is generated from `project.yml` with XcodeGen. `make snapshot`
renders the palette from fixture data; with Accessibility granted, the app can
also dump real menu bars and drive itself end to end (see
`.claude/skills/macos-native-app/SKILL.md` for the `SUPERBAR_DIAG*` variables). An "Apple
Development" certificate in your keychain gives the app a stable code
identity, so macOS keeps the Accessibility grant across rebuilds; otherwise the
build is ad-hoc signed and the grant has to be renewed after each build.

### Layout

```
Packages/SuperBarKit    logic: menu model, Accessibility source, fuzzy search,
                        frecency, rules, scripts, themes, preferences (+ tests)
App/SuperBar            AppKit palette, SwiftUI settings, hot keys, status item
App/SuperBarCLI         superbar-cli
App/SuperBarTests       app-level tests (search session)
docs/                   research, design spec, implementation plan
.claude/skills/         project skills for AI-assisted development
```

## Privacy

SuperBar has no analytics, no network access and no account. Recents are
stored in `~/Library/Application Support/SuperBar/recents.json`; everything
else lives in the app's preferences.

## Acknowledgements

Inspired by Roey Biran's Finbar, which pioneered this idea. SuperBar is an
independent implementation and is not affiliated with Finbar.

MIT License © 2026 Manu Ader
