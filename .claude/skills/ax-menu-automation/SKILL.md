---
name: ax-menu-automation
description: Use when reading, searching, pressing or revealing another app's menu bar through the macOS Accessibility API (AXUIElement) — attribute names, key-equivalent decoding tables, separators, timeouts, permission handling, reveal and Help-menu fallback techniques.
---

# Menu bar automation with the Accessibility API

## Reading the tree
```swift
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1.5)          // avoid hanging on busy apps
var bar: AnyObject?
AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar)
```
Children of the menu bar are `AXMenuBarItem`s (Apple, File, Edit…). Each has one
`AXMenu` child whose children are `AXMenuItem`s; a submenu item has an
`AXMenu` child again. Read attributes in one IPC per element with
`AXUIElementCopyMultipleAttributeValues` for:
`AXTitle, AXRole, AXEnabled, AXChildren, AXMenuItemCmdChar,
AXMenuItemCmdModifiers, AXMenuItemCmdVirtualKey, AXMenuItemCmdGlyph,
AXMenuItemMarkChar`.

- Separator: role `AXMenuItem`, empty title, no children, disabled. Keep it
  in index counting (Finbar-compatible), never display it.
- Errors: `.cannotComplete`/timeout ⇒ app busy; `.apiDisabled` ⇒ no
  permission; `.invalidUIElement` ⇒ stale reference (re-walk by indices).
- The Apple menu and "Services" are large but fine; "Open Recent"/"Window"
  contents are dynamic — never cache their titles as identity, use index
  paths as the fallback key.

## Key equivalents
`AXMenuItemCmdModifiers` is a Carbon mask: 0 ⇒ ⌘ only, +1 ⇧, +2 ⌥, +4 ⌃,
+8 "no ⌘". Display order: ⌃ ⌥ ⇧ ⌘.
`AXMenuItemCmdChar` may be a printable char (uppercase it) or a Unicode
function-key char (U+F700 ↑, U+F701 ↓, U+F702 ←, U+F703 →, U+F704…F70F
F1–F12, U+F728 ⌦, U+F729 ↖, U+F72B ↘, U+F72C ⇞, U+F72D ⇟, U+0008/U+007F ⌫,
U+0003 ⌤, U+000D ↩, U+0009 ⇥, U+0019 ⇤, U+001B ⎋, " " ␣).
`AXMenuItemCmdGlyph` (Carbon glyph ids) wins when present: 2 ⇥, 3 ⇤, 4 ⌤,
9 ␣, 10 ⌦, 11 ↩, 23 ⌫, 27 ⎋, 28 ⌧, 98 ⇞, 99 ⇟, 100 ⇪, 101 ←, 102 →, 103 ↑,
104 ↓, 111–125 F1–F15, 140 ⏏, 143–146 F16–F19.
`AXMenuItemCmdVirtualKey` fallback: 122 F1, 120 F2, 99 F3, 118 F4, 96 F5,
97 F6, 98 F7, 100 F8, 101 F9, 109 F10, 103 F11, 111 F12, 123 ←, 124 →,
125 ↓, 126 ↑, 115 ↖, 119 ↘, 116 ⇞, 121 ⇟, 117 ⌦, 53 ⎋, 48 ⇥, 49 ␣, 36 ↩,
51 ⌫, 76 ⌤.

## Actions
- Activate: hide our panel first (it is non-activating so the target keeps
  focus), then `AXUIElementPerformAction(item, kAXPressAction)`. On failure
  activate the app (`NSRunningApplication.activate`) and retry once.
- Reveal (⌘↩): press the `AXMenuBarItem`, then press each ancestor submenu
  item (opens it), then set `kAXSelectedAttribute = true` on the leaf; close
  with Escape (`CGEvent` keycode 53) when done.
- Help-menu fallback: press the Help `AXMenuBarItem` (its search field gets
  focus), then type the query by posting a `CGEvent` with
  `keyboardSetUnicodeString`.

## Permission
`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` prompts
once; later, deep-link
`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
Grants are tied to the code signature: ad-hoc builds lose them every rebuild.

## Verified against real apps (2026-09-02)
Finder, Notes, Terminal, Xcode, IntelliJ, Arc, Chrome, WhatsApp, Claude all
load with the batched attribute reads: 175–842 nodes in 0.2–1.5 s cold,
~100–200 ms warm. Items read while the app is *not* frontmost report many
`disabled` flags (apps disable items when they lack focus); the palette is
non-activating so in real use the target keeps focus and the flags are right.
Untitled items owning an empty `AXMenu` are the Help menu's search field:
treat them as separators. Apple-menu titles carry badge text
("System Settings…, 1 update"); strip it.

## Driving the app for tests
- Run the app through LaunchServices so it is trusted: `open -n -a Build.app
  --env SUPERBAR_DIAG=/dir …`. Binaries started from a shell inherit the
  terminal's (untrusted) TCC identity.
- Synthetic keys posted to the HID tap go to the *active* app, not to a
  non-activating key panel. To type into the palette from another process use
  `CGEvent.postToPid(pid)`. Physical typing is routed correctly by the window
  server.
- `SUPERBAR_DIAG_E2E="<item title>"` performs the whole flow against the
  installed instance and checks `recents.json`.
