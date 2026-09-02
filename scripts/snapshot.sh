#!/bin/bash
# Renders the palette in its main states from fixture data (no Accessibility
# permission needed). Usage: scripts/snapshot.sh <SuperBar.app> <output dir>
set -u
APP="$1"; OUT="$2"; BIN="$APP/Contents/MacOS/SuperBar"
mkdir -p "$OUT"
run() {
  local name="$1"; shift
  if env "$@" SUPERBAR_SNAPSHOT="$OUT/$name.png" "$BIN" >/dev/null 2>"$OUT/$name.log"; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name (see $OUT/$name.log)"
  fi
}
echo "Rendering snapshots into $OUT"
run root-light          SUPERBAR_APPEARANCE=light
run root-dark           SUPERBAR_APPEARANCE=dark
run root-outline        SUPERBAR_APPEARANCE=light SUPERBAR_MODE=outline
run search-list         SUPERBAR_APPEARANCE=light SUPERBAR_QUERY=bld SUPERBAR_MODE=list
run search-outline      SUPERBAR_APPEARANCE=light SUPERBAR_QUERY=b SUPERBAR_MODE=outline
run scoped              SUPERBAR_APPEARANCE=light SUPERBAR_SCOPE=Format SUPERBAR_QUERY=text
run no-results          SUPERBAR_APPEARANCE=light SUPERBAR_QUERY=zzzz
run permission          SUPERBAR_APPEARANCE=light SUPERBAR_STATE=permission
run busy                SUPERBAR_APPEARANCE=dark SUPERBAR_STATE=busy
run loading             SUPERBAR_APPEARANCE=light SUPERBAR_STATE=loading
run theme-catppuccin    SUPERBAR_APPEARANCE=dark SUPERBAR_THEME=catppuccin
run theme-dracula       SUPERBAR_APPEARANCE=dark SUPERBAR_THEME=dracula SUPERBAR_QUERY=bld
run theme-solarized-light SUPERBAR_APPEARANCE=light SUPERBAR_THEME=solarized-light
