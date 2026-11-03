#!/usr/bin/env bash
# The App Store screenshots, from the simulator: the screens a Debug build can
# reach with no login, on the iPhone, iPhone Duo and iPad sizes App Store Connect takes.
# `-tab`, `-owner` and `-autoplay` are the Debug build's launch arguments; the
# Debug build plays stage, so the round shown is staging's. Writes
# app/.build/screenshots/{iphone,duo,ipad}/NN-name.png, in the order the store
# shows them; `task asc:listing -- --apply` uploads whichever set is empty
# in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/../app"

APP=.build/DerivedData/Build/Products/Debug-iphonesimulator/Guessr.app
BUNDLE=lol.dana.guessr
[ -d "$APP" ] || { echo "no simulator build at $APP -- run: task ios:build" >&2; exit 1; }

udid() { xcrun simctl list devices available -j | jq -r --arg n "$1" '.devices[][] | select(.name == $n) | .udid' | head -1; }

# What a shot waits for: the app's own game steps (Telemetry.step), and
# AVPlayer saying the clip is on screen. A fixed sleep raced both, and lost on
# a cold first launch, which leaves the home screen or a black frame. Even
# after the clip plays, the first launch after an install can take seconds
# more to draw: a black frame is ~120 KB and one with video in it is over a
# megabyte, so a shot with a floor retakes until it clears it.
SIGNALS='(subsystem == "lol.dana.guessr" AND category == "game") OR (process == "Guessr" AND eventMessage CONTAINS "new playback state: Playing")'

shoot() { # shoot <udid> <dir> <name> <log line to wait for, or ""> <seconds to settle after it> <min bytes> <launch args...>
    local id=$1 dir=$2 name=$3 line=$4 settle=$5 floor=$6; shift 6
    local log waited=0 stream tries=0
    log=$(mktemp)
    xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
    xcrun simctl spawn "$id" log stream --style compact --predicate "$SIGNALS" >"$log" 2>/dev/null &
    stream=$!
    xcrun simctl launch "$id" "$BUNDLE" "$@" >/dev/null
    while [ -n "$line" ] && ! grep -q "$line" "$log"; do
        if [ $((waited += 1)) -gt 180 ]; then
            kill "$stream"; rm -f "$log"
            echo "  $name: no '$line' from the app in 90 s" >&2; return 1
        fi
        sleep 0.5
    done
    kill "$stream"; rm -f "$log"
    sleep "$settle"
    until xcrun simctl io "$id" screenshot "$dir/$name.png" >/dev/null 2>&1 &&
        [ "$(stat -f %z "$dir/$name.png")" -ge "$floor" ]; do
        [ $((tries += 1)) -lt 30 ] || { echo "  $name: still blank after 30 s" >&2; return 1; }
        sleep 1
    done
    echo "  $dir/$name.png"
}

# <simulator>:<dir>. ONLY="ipad duo" shoots just those dirs.
for spec in "iPhone 18 Pro Max:iphone" "iPhone Duo:duo" "iPad Pro 13-inch (M5):ipad"; do
    IFS=: read -r sim leaf <<<"$spec"; dir=.build/screenshots/$leaf
    [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $leaf "* ]] || continue
    id=$(udid "$sim")
    [ -n "$id" ] || { echo "no simulator named '$sim' -- xcrun simctl list devices available" >&2; exit 1; }
    echo "$sim ($id)"
    mkdir -p "$dir"; rm -f "$dir"/*.png
    xcrun simctl boot "$id" 2>/dev/null || true
    xcrun simctl bootstatus "$id" -b >/dev/null
    if [ "$leaf" = duo ]; then
        # The Duo boots folded and simctl cannot unfold it, so its inner display
        # stays black until someone unfolds it in DeviceHub, Xcode's simulator app.
        open "$(xcode-select -p)/../Applications/DeviceHub.app"
        read -rp "  unfold the iPhone Duo in DeviceHub, then press Return " </dev/tty
    fi
    # Apple's own screenshot status bar: full signal, full battery, 9:41.
    xcrun simctl status_bar "$id" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    # A fresh install and a fresh Keychain: the player id lives there and the
    # day's progress follows the id from the server, so without the reset a
    # rerun opens on whatever round the last one reached.
    xcrun simctl uninstall "$id" "$BUNDLE" 2>/dev/null || true
    xcrun simctl keychain "$id" reset >/dev/null
    xcrun simctl install "$id" "$APP"
    # The round once its clip plays; then a warm launch with autoplay, which
    # guesses after 5 s and holds the reveal for 6, shot once the guess lands
    # and the map has flown to the answer; then Settings, which has no step.
    # The reveal has no floor: it holds for 6 s, and a retake past it would
    # catch the next round.
    shoot "$id" "$dir" 01-round "new playback state: Playing" 2 1000000 -tab Play
    shoot "$id" "$dir" 02-reveal game.guessed 3 0 -tab Play -autoplay 1
    shoot "$id" "$dir" 03-settings "" 6 0 -tab Settings
    xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
    xcrun simctl status_bar "$id" clear
done
echo "done: $(find .build/screenshots -name '*.png' | wc -l | tr -d ' ') screenshots"
