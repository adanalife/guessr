#!/usr/bin/env bash
# Render the App Clip card's header image, 1800x1200 PNG, into
# app/.build/appclip/header.png for scripts/asc-listing.py to upload. The
# palette is the app's paper and ink (GuessrKit's Style.swift) with the game's
# green mark, pinned above a road. No text: the card sets the app's name and
# the subtitle beneath the image itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/.build/appclip"
command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }
mkdir -p "$OUT"

PAPER='#fffff8'
INK='#111111'

# The mark from web/favicon.svg, as make-app-icon.sh takes it, centred on its
# drawn bounds at (cx, cy) and scaled to fill `size` pixels.
pin() { # cx cy size
  local glyph scale
  glyph="$(sed -n '/<path/,/<\/svg>/p' "$ROOT/web/favicon.svg" | sed '$d')"
  scale=$(echo "$3 / 28.4" | bc -l)
  printf '<g transform="translate(%s,%s) scale(%s) translate(-16,-16.8)">%s</g>' "$1" "$2" "$scale" "$glyph"
}

rsvg-convert -w 1800 -h 1200 -o "$OUT/header.png" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1200" viewBox="0 0 1800 1200">
  <rect width="1800" height="1200" fill="$PAPER"/>
  <path d="M-40 1010 C 500 860, 1300 1060, 1840 900" fill="none" stroke="$INK" stroke-width="150" stroke-linecap="round"/>
  <path d="M-40 1010 C 500 860, 1300 1060, 1840 900" fill="none" stroke="$PAPER" stroke-width="10" stroke-dasharray="60 50"/>
  $(pin 900 520 620)
</svg>
SVG
echo "  header.png"
