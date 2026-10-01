#!/usr/bin/env bash
# Render the Game Center achievement images, 1024x1024 PNG each, into
# app/.build/achievements/<vendor suffix>.png for scripts/gamecenter-config.py
# to upload. Game Center shows them in a circle, so every glyph sits well
# inside one. The palette is the game's: its green mark on the dark ground the
# app and site use, with gold for the 🏆 band a perfect round earns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/.build/achievements"
command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }
mkdir -p "$OUT"

GROUND='#1a1a1a'
GREEN='#6aaa64'
GOLD='#e5b84a'
CREAM='#fffff8'
FONT="font-family=\"Georgia, serif\" font-weight=\"bold\" text-anchor=\"middle\""

# The mark from web/favicon.svg, as make-app-icon.sh takes it, centred on its
# drawn bounds and scaled to fill `size` pixels.
pin() { # size
  local glyph scale
  glyph="$(sed -n '/<path/,/<\/svg>/p' "$ROOT/web/favicon.svg" | sed '$d')"
  scale=$(echo "$1 / 28.4" | bc -l)
  printf '<g transform="translate(512,512) scale(%s) translate(-16,-16.8)">%s</g>' "$scale" "$glyph"
}

# A five-point star of outer radius r at (cx, cy).
star() { # cx cy r fill
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import math, sys
cx, cy, r, fill = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
pts = []
for i in range(10):
    a = math.radians(-90 + i * 36)
    d = r if i % 2 == 0 else r * 0.4
    pts.append(f"{cx + d * math.cos(a):.1f},{cy + d * math.sin(a):.1f}")
print(f'<polygon points="{" ".join(pts)}" fill="{fill}" stroke-linejoin="round"/>')
PY
}

render() { # name, body
  rsvg-convert -w 1024 -h 1024 -o "$OUT/$1.png" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" fill="$GROUND"/>
  $2
</svg>
SVG
  echo "  $1.png"
}

# First Pin: the mark itself.
render first_pin "$(pin 560)"

# Bullseye: a target with the mark's dot at the centre.
render bullseye "
  <circle cx='512' cy='512' r='340' fill='none' stroke='$GREEN' stroke-width='60'/>
  <circle cx='512' cy='512' r='220' fill='none' stroke='$CREAM' stroke-width='50'/>
  <circle cx='512' cy='512' r='110' fill='$GREEN'/>"

# Golden Day: a sun.
rays=""
for i in $(seq 0 11); do
  rays="$rays<rect x='496' y='120' width='32' height='120' rx='16' fill='$GOLD' transform='rotate($((i * 30)) 512 512)'/>"
done
render golden_day "<circle cx='512' cy='512' r='210' fill='$GOLD'/>$rays"

# Seven Days Running: a week of squares, the share string's row.
squares=""
for i in $(seq 0 6); do
  squares="$squares<rect x='$((72 + i * 128))' y='456' width='112' height='112' rx='20' fill='$GREEN'/>"
done
render week_streak "$squares"

# Century: the number.
render century "<text x='512' y='655' font-size='400' fill='$GREEN' $FONT>100</text>"

# Perfect Round: one gold star, the 🏆 band.
render perfect_round "$(star 512 540 330 "$GOLD")"

# Perfect Day: five of them.
stars=""
for i in $(seq 0 4); do
  stars="$stars$(star $((164 + i * 174)) 512 90 "$GOLD")"
done
render perfect_day "$stars"

# Top Ten: the number, with the month's ring around it.
render top_ten "
  <circle cx='512' cy='512' r='420' fill='none' stroke='$GREEN' stroke-width='28'/>
  <text x='512' y='645' font-size='380' fill='$GOLD' $FONT>10</text>"
