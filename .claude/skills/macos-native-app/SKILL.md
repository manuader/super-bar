---
name: macos-native-app
description: Use when building, changing, running or debugging SuperBar (or any AppKit/SwiftUI macOS utility in this repo) — project layout, XcodeGen workflow, build/test/run/snapshot commands, signing and TCC gotchas, non-activating panel patterns, performance rules.
---

# macOS native app development (SuperBar)

## Layout
- `Packages/SuperBarKit` — pure logic (models, fuzzy search, frecency,
  rules, scripts, themes, Accessibility source). Test with `swift test`.
- `App/SuperBar` — AppKit app (palette, settings). `App/SuperBarCLI` — CLI.
- `project.yml` — XcodeGen spec; `SuperBar.xcodeproj` is generated, never
  edited by hand. `make project` regenerates it.

## Commands (always via the Makefile)
| Task | Command |
|---|---|
| Kit tests | `make test` |
| Generate + build app | `make build` (Debug) / `make release` |
| Run the app | `make run` |
| Visual check without permissions | `make snapshot` → `snapshots/*.png` |
| Install to /Applications | `make install` |

Signing: `DEVELOPMENT_TEAM` env var (see Makefile) enables automatic signing
with an "Apple Development" identity. Without it, builds are ad-hoc signed
(`-`), which changes the code identity on every build and makes macOS forget
the Accessibility grant. Prefer a stable identity while iterating.

## Rules that keep the app fast and native
1. Palette UI is AppKit: `NSPanel(.nonactivatingPanel)`, view-based
   `NSOutlineView`, fixed row heights, no auto layout inside rows (manual
   `layout()`), `NSVisualEffectView` for materials, SF Symbols via
   `NSImage(systemSymbolName:)` with `.withSymbolConfiguration`.
2. Never call Accessibility APIs on the main thread; use `AXMenuSource`'s
   queue and deliver immutable `MenuSnapshot`s.
3. The search field stays first responder; intercept navigation through
   `control(_:textView:doCommandBy:)` selectors (`moveUp:`, `moveDown:`,
   `insertNewline:`, `cancelOperation:`, `scrollPageUp:`,
   `scrollToBeginningOfDocument:`, `moveToBeginningOfParagraph:` …).
4. Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
5. Settings are SwiftUI `Form { … }.formStyle(.grouped)` hosted in an
   `NSTabViewController(tabStyle: .toolbar)` — that is the System Settings
   look. No custom chrome.
6. Persist only through `Preferences` (typed UserDefaults). No singletons
   inside SuperBarKit other than `Preferences.shared`.
7. Language mode Swift 5 with `-strict-concurrency=targeted`; annotate UI
   types `@MainActor`; keep `MenuNode`/`MenuSnapshot` value types.

## Debugging
- `/usr/bin/log show --last 5m --predicate 'subsystem == "com.manuader.SuperBar"'` for
  persisted notice lines (show/hide/hot key); `/usr/bin/log stream … --debug` for key
  presses and queries. Always use the absolute path: zsh has a `log` builtin.
- Accessibility state: `SuperBar --check-ax` prints trusted status.
- If the hot key does not fire: another app owns it
  (`RegisterEventHotKey` → `eventHotKeyExistsErr`, shown in Settings).
- Snapshot harness env: `SUPERBAR_FIXTURE=1 SUPERBAR_QUERY=bld
  SUPERBAR_MODE=list|outline SUPERBAR_APPEARANCE=dark SUPERBAR_SNAPSHOT=out.png`.

## Real-menu diagnostics (needs Accessibility granted to the app)
```
open -n -a build/DerivedData/Build/Products/Debug/SuperBar.app \
  --env SUPERBAR_DIAG=/tmp/diag --env SUPERBAR_DIAG_QUERY=bld          # dumps every running app
  --env SUPERBAR_DIAG_APPS=com.apple.finder --env SUPERBAR_DIAG_PRESS=com.apple.finder:6.14
  --env SUPERBAR_DIAG_REVEAL=com.apple.finder:2.0  --env SUPERBAR_DIAG_HELP=com.apple.finder:tags
  --env "SUPERBAR_DIAG_E2E=bring all to front"                          # drives the installed app
```
  --env SUPERBAR_DIAG_INDEX=1                                            # crawl + search benchmark
  --env SUPERBAR_DIAG_OPEN=/path/to/folder                               # checks Finder really opens a tab

Wait for `<dir>/done`, then read `summary.txt`. Real-menu palette PNGs:
`--env SUPERBAR_SNAPSHOT=/tmp/x.png --env SUPERBAR_REAL_APP=com.apple.finder`.

## The file index (`open` command)
- Storage is columnar (`FileTable`): folded name bytes in one flat buffer plus
  parallel mask/offset/length/heat arrays. Never put per-entry arrays back into
  `FileEntry` — that cost 1.4 s per search over 200k entries instead of 8 ms.
- Crawl with `contentsOfDirectory(at:includingPropertiesForKeys:)`, never
  `fileExists(atPath:isDirectory:)` per child: bulk resource keys took the real
  crawl from 10.8 s to 0.38 s.
- `.skipsHiddenFiles` does not exclude `.DS_Store`; check the dot prefix too.
- Heat propagates from an opened path up its ancestors (halved per level), and
  the crawl depth is derived from heat. That is what makes a rarely used
  subfolder of a hot project findable.
- Searching runs on the index queue and delivers to the main actor with a
  generation token; the palette shows the previous results until the new ones
  land, which avoids flicker.

## Driving the app with synthetic keys
Create the event source with `.privateState` and set `event.flags = []`.
With `.combinedSessionState` the modifiers of the hot key leak into later
events, so "o" arrives as ⌃O and triggers an editing shortcut instead of text.

## Verification before claiming done
`make test && make build && make snapshot`, then look at the PNGs.
