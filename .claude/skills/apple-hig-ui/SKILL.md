---
name: apple-hig-ui
description: Use when designing or reviewing any SuperBar surface (palette rows, badges, header, footer, settings panes, status item) so it looks indistinguishable from Apple's own macOS UI — typography, spacing, materials, colours, symbols, motion.
---

# Apple-like macOS UI (SuperBar design tokens)

## Typography (system font only)
- Search field: `.systemFont(ofSize: 15)` (Spotlight-like), placeholder
  `secondaryLabelColor`.
- Row title 13 pt regular; subtitle/path 11 pt `secondaryLabelColor`;
  section header 11 pt semibold `secondaryLabelColor` uppercase-free
  ("Menu Items"); footer 11 pt secondary; badges 11 pt medium, monospaced
  digits (`.monospacedDigitSystemFont`).
- "Row text size" setting scales title/subtitle by 0 / +1 / +2 pt.

## Layout
- Panel width 640 (min 480, max 1200), corner radius 12, content inset 8.
- Header 52 pt: app icon 28×28 at x=16 · field · trailing controls 8 pt apart.
- Row 28 pt (40 pt when subtitles are shown), row inset 8 pt, icon 20 pt
  column, title x = icon + 12 pt, badges right-aligned with 8 pt gaps.
- Section header 24 pt with 8 pt top gap. Footer 28 pt above a 1 px
  `separatorColor` line.
- Selection: rounded rect radius 6 inset 8 pt, `controlAccentColor`;
  selected text `alternateSelectedControlTextColor` (white), badges on a
  selected row become white-on-translucent-white.

## Colour and material
- System themes: `NSVisualEffectView` material `.popover`, blending
  `.behindWindow`, state `.active`; text `labelColor` etc. so light/dark
  are automatic. Custom themes: opaque `background` colour, no material.
- Count badge: `quaternaryLabelColor` background capsule, `secondaryLabelColor`
  text. Key-equivalent badge: same capsule, text `labelColor` at 85 %.
  Quick-select badge: `controlAccentColor` at 15 % background, accent text,
  `bolt.fill` symbol 9 pt.
- Disabled rows: title alpha 0.4.

## Symbols (SF Symbols, template, `.regular` weight)
menu bar item `menubar.rectangle` · menu item `list.bullet.rectangle` ·
submenu `list.bullet.rectangle.portrait`? — keep `list.bullet.rectangle` with a
chevron; script `curlybraces.square`; recent overlay `clock` 9 pt; list mode
`list.bullet`; outline mode `list.bullet.indent`; options `ellipsis.circle` +
`chevron.down`; clear `xmark.circle.fill`; help fallback `questionmark.circle`;
warning `exclamationmark.triangle.fill` (`systemYellowColor`).

## Motion
- Height changes: 0.15 s ease-out; none with Reduce Motion.
- No fade-in on show (Finbar removed it; instant feels faster).
- Row insert/remove: `.effectFade` only when < 50 rows change.

## Settings
`Form { Section { … } }.formStyle(.grouped)` — labels on the left, controls
on the right, no custom fonts, `LabeledContent` for read-only values,
`Toggle`, `Picker(.menu)`, `Slider` with value label, footers via
`Section(footer:)`. Tabs: General `gearshape`, Appearance `paintpalette`,
Rules `list.bullet.rectangle.portrait`, Scripts `curlybraces`, About `info.circle`.
