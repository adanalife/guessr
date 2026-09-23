#!/usr/bin/env bash
# Render the iOS app icon's three appearance variants from the game's mark,
# web/favicon.svg, in the composition tempomat's icon uses: the glyph at 62% of
# the 1024 canvas, light drawn opaque on off-white, dark and tinted drawn on
# transparency for iOS to composite (tinted must be grayscale, so it is white).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGO="$ROOT/web/favicon.svg"
OUT="$ROOT/app/Guessr/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }

# The mark's drawn bounds inside its 32x32 viewBox, stroke included; centring
# on these rather than the viewBox keeps the pin optically centred.
BOX_X=16 BOX_Y=16.8 BOX_SIZE=28.4
FILL=0.62
GREEN='#6aaa64'

glyph="$(sed -n '/<path/,/<\/svg>/p' "$LOGO" | sed '$d')"

render() { # name, fill colour for the mark, background element (or empty)
  local name="$1" fg="$2" bg="$3"
  local scale
  scale=$(echo "1024 * $FILL / $BOX_SIZE" | bc -l)
  rsvg-convert -w 1024 -h 1024 -o "$OUT/$name.png" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  $bg
  <g transform="translate(512,512) scale($scale) translate(-$BOX_X,-$BOX_Y)">
    $(printf '%s' "$glyph" | sed "s/$GREEN/$fg/g")
  </g>
</svg>
SVG
  echo "  $name.png"
}

mkdir -p "$OUT"
render icon-light "$GREEN" '<rect width="1024" height="1024" fill="#FAFAF8"/>'
render icon-dark "$GREEN" ''
render icon-tinted '#FFFFFF' ''
cat >"$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "icon-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
