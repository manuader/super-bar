# SuperBar — design spec (2026-09-02)

A free, open-source, 100 % native macOS clone of Finbar: a command palette for
the menu bar of whatever app is in front. Feature-complete with Finbar 1.22
(see `docs/research/finbar-feature-inventory.md`), Apple-like to the pixel,
tuned for power users (keyboard first, < 16 ms interactions, progressive
loading).

## 1. Goals and non-goals

Goals: every Finbar feature; native look (materials, SF Symbols, system
typography, HIG spacing); instant feel (panel appears < 50 ms, search over
5 000 items < 5 ms, cached menu trees); zero third-party dependencies; unit
tested core; runs on macOS 14+ (Sonoma, Sequoia, Tahoe).

Non-goals: licensing/trial, telemetry, auto-updates (link to GitHub
Releases instead), Mac App Store sandboxing (Accessibility needs an
unsandboxed app).

## 2. Approaches considered

1. **AppKit palette + SwiftUI settings + shared Swift package** (chosen).
   NSPanel/NSOutlineView give total control over keyboard handling, row
   recycling and non-activating behaviour; SwiftUI `Form(.grouped)` gives the
   System Settings look for free; the package keeps logic testable with
   `swift test` in seconds.
2. Pure SwiftUI (`MenuBarExtra` + `Settings` + `List`). Faster to write, but
   `List` keyboard handling, focus in a non-activating panel and per-row
   performance with thousands of rows are all worse; rejected.
3. Electron/Tauri. Not native; rejected outright.

## 3. Architecture

```
SuperBar.app (AppKit lifecycle, LSUIElement)
 ├─ PaletteController      NSPanel (non-activating) · header · outline view · footer
 ├─ SearchSession          state machine: root / scoped / searching, list|outline
 ├─ HotKeyCenter           Carbon RegisterEventHotKey, per-app exclusion
 ├─ StatusItemController   NSStatusItem (optional)
 ├─ SettingsWindow         NSTabViewController(.toolbar) hosting SwiftUI panes
 ├─ RuleEditorSheet        NSPredicateEditor
 └─ Snapshot harness       DEBUG-only: fixture menus → PNG (visual verification)
superbar-cli               list / select, JSON output
SuperBarKit (Swift package, no UI)
 ├─ MenuModel        MenuSnapshot, MenuNode, KeyEquivalent, IndexPath helpers
 ├─ MenuSource       protocol; AXMenuSource (Accessibility), FixtureMenuSource
 ├─ Fuzzy            scorer + match ranges, list & outline filtering
 ├─ Frecency         RecentsStore (JSON on disk, per bundle id, dynamic titles)
 ├─ Rules            Rule model, NSPredicate evaluation, exclusion pass
 ├─ Scripts          ScriptsLibrary (folder scan, watcher, runner)
 ├─ Themes           Theme model, built-ins, custom theme store
 └─ Preferences      typed UserDefaults wrapper
```

Data flow: hot key → `PaletteController.show(for: frontmostApp)` → asks
`MenuCache` for a snapshot (returns cached instantly and refreshes in the
background; first load streams top-level menus as they arrive) → rules
exclusion → `SearchSession` computes rows (root / search / scoped) →
`NSOutlineView.reloadData` (diffed when small) → keyboard/mouse → activate
(`AXPress`, script run, reveal) → `RecentsStore.record` → panel hides.

Concurrency: AX traversal on a dedicated serial `DispatchQueue` (AX calls are
synchronous IPC); results are immutable value types (`Sendable`) delivered to
the main actor. Fuzzy search runs on the main thread (it is sub-millisecond
for the typical 1–3 k items) with a cancellable background fallback above
10 k rows.

## 4. Components

### 4.1 MenuModel
`MenuNode { id, title, displayTitle, path: [String], indexPath: [Int],
depth, isEnabled, isSeparator, mark, keyEquivalent, children, axRef }`.
`KeyEquivalent { modifiers: Set<Modifier>, key: String }` rendered as
"⌃⌥⇧⌘K"; maps Carbon glyphs and virtual keys to symbols.
`MenuSnapshot { app: AppInfo, roots: [MenuNode], createdAt }` plus a
flattened, precomputed search index (lowercased scalars per row).

### 4.2 AXMenuSource
`AXUIElementCreateApplication(pid)` → `AXMenuBar` → children. Uses
`AXUIElementCopyMultipleAttributeValues` (one IPC per element), a 1.5 s
messaging timeout (reports "busy" as an error row instead of hanging),
skips the "Apple" menu's dynamic Recent Items only when they fail. Actions:
`press(node)`, `reveal(node)` (opens ancestor menus with `AXPress`, then sets
`AXSelected` on the leaf), `searchHelpMenu(query)` (presses Help, types the
query with `CGEvent`).

### 4.3 Fuzzy
fzf-style scorer: ordered subsequence match on lowercased text; bonuses for
prefix, word boundary, camel-case, consecutive runs; gap penalties; match
against title first, then `displayTitle` (parent › title for depth ≥ 2), and
finally the full path. Returns `(score, ranges)`. List mode: sort by score,
tie-break by frecency then original order. Outline mode: keep ancestors of
matches, include descendants of matching parents, expanded set = menus that
contain matches, initial selection = best score.

### 4.4 Frecency
`RecentEntry { bundleID, titlePath, indexPath, uses: [Date] (last 20) }`.
Score = Σ weight(age) with 100/80/60/30/10 for < 1 h / 1 d / 7 d / 30 d /
older. Lookup by title path, fallback to index path under the same top-level
menu (dynamic titles). Persisted as JSON in
`~/Library/Application Support/SuperBar/recents.json`, written debounced.

### 4.5 Rules
`Rule { id, name, isEnabled, predicateFormat }`. Evaluated with
`NSPredicate` against `RuleSubject` (title, path, appName, bundleIdentifier,
index, depth). A matching node and all descendants are removed. If the pass
removes every node, the palette shows an error row.

### 4.6 Scripts
Root: `~/Library/Application Scripts/com.manuader.SuperBar/`. Files at the
root apply to every app; files inside `<bundle id>/` only to that app.
Title = file name without extension. Runner: `.scpt/.scptd/.applescript` →
`/usr/bin/osascript`; executable files run directly; otherwise the shebang
interpreter; `.sh/.zsh/.py/.rb/.js` fall back to their usual interpreter.
Environment gets `SUPERBAR_APP_BUNDLE_ID` and `SUPERBAR_APP_NAME`. Failures
post a user notification with stderr. Folder watched with FSEvents.

### 4.7 Themes
`Theme { id, name, isBuiltIn, colors: background, text, secondaryText,
selection, selectionText, badgeBackground, badgeText, accent, separator,
usesMaterial }`. System Light/Dark use dynamic system colors on a
`.popover` material; the six classic palettes are opaque. Custom themes are
stored as JSON in UserDefaults and edited with colour wells.

### 4.8 Palette UI (AppKit)
`NSPanel(styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable])`,
`level = .floating`, `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary, .transient]`, `hidesOnDeactivate = false`, corner
radius 12 via a masking `NSVisualEffectView`. Header 52 pt, footer 28 pt,
rows 28 pt (40 pt with subtitles), section headers 24 pt. Search field is
always first responder; ↑/↓/etc. are intercepted through
`control(_:textView:doCommandBy:)`. Selection is drawn by a custom
`NSTableRowView` (6 pt radius, accent colour). Row cell = symbol image ·
attributed title (mark, underline matches) · count badge · key badge ·
quick-select badge. Height animates to fit rows (respects Reduce Motion).
Options menu: Find ⌘F · Activate ↩ · Reveal Menu Item ⌘↩ · Search Help
Menu · Clear Recents · Center Window · Settings… ⌘, · Help · Quit ⌘Q.

### 4.9 Settings (SwiftUI in NSTabViewController toolbar tabs)
General · Appearance · Rules · Scripts · About. A first-run permission window
explains Accessibility and opens System Settings.

### 4.10 CLI
`superbar-cli list [--predicate <fmt>]` and `superbar-cli select <i>…`,
same JSON shape as Finbar's, exit codes 0/1/2.

## 5. Error handling
- No Accessibility: palette shows a single actionable row "Grant
  Accessibility access" (opens System Settings) and the status item shows a
  warning badge.
- App busy / AX timeout: inline error row with a retry action; cached
  snapshot (if any) stays visible.
- Press failure: retry after activating the app; then a notification.
- Rules exclude everything: inline error row linking to Rules settings.
- Hot key conflict: settings shows a red note; palette still opens from the
  status item.

## 6. Testing
`swift test` on SuperBarKit: fuzzy scoring/ordering/ranges, outline
filtering, key-equivalent rendering, frecency ranking and dynamic-title
fallback, rules exclusion (including descendants and the empty case),
scripts discovery/title/runner selection, theme codec. App: `xcodebuild
build`, and the snapshot harness renders the palette from fixture data to
PNG for visual review (`make snapshot`). CI runs both on `macos-15`.

## 7. Performance budget
Panel show: < 50 ms with a warm cache. First traversal of a 2 000-item app:
≈ 200–400 ms, streamed top-level-menu by menu so the UI is usable after the
first one. Query keystroke → rows: < 5 ms for 5 k rows. Memory < 40 MB.
