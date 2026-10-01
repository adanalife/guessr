#!/usr/bin/env bash
# The App Store screenshots, from the simulator: the screens a Debug build can
# reach with no login, on the iPhone and iPad sizes App Store Connect asks for.
# `-tab`, `-owner` and `-autoplay` are the Debug build's launch arguments; the
# Debug build plays stage, so the round shown is staging's. Writes
# app/.build/screenshots/{iphone,ipad}/NN-name.png, in the order the store
# shows them; `task asc:listing -- --apply` uploads whichever set is empty
# in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/../app"

APP=.build/DerivedData/Build/Products/Debug-iphonesimulator/Guessr.app
BUNDLE=lol.dana.guessr
[ -d "$APP" ] || { echo "no simulator build at $APP -- run: task ios:build" >&2; exit 1; }

udid() { xcrun simctl list devices available -j | jq -r --arg n "$1" '.devices[][] | select(.name == $n) | .udid' | head -1; }

shoot() { # shoot <udid> <dir> <name> <seconds to wait> <launch args...>
    local id=$1 dir=$2 name=$3 wait=$4; shift 4
    xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$id" "$BUNDLE" "$@" >/dev/null
    sleep "$wait"
    xcrun simctl io "$id" screenshot "$dir/$name.png" >/dev/null
    echo "  $dir/$name.png"
}

for spec in "iPhone 17 Pro Max:iphone" "iPad Pro 13-inch (M5):ipad"; do
    sim=${spec%%:*}; dir=.build/screenshots/${spec##*:}
    id=$(udid "$sim")
    [ -n "$id" ] || { echo "no simulator named '$sim' -- xcrun simctl list devices available" >&2; exit 1; }
    echo "$sim ($id)"
    mkdir -p "$dir"; rm -f "$dir"/*.png
    xcrun simctl boot "$id" 2>/dev/null || true
    xcrun simctl bootstatus "$id" -b >/dev/null
    # Apple's own screenshot status bar: full signal, full battery, 9:41.
    xcrun simctl status_bar "$id" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    # A fresh install and a fresh Keychain: the player id lives there and the
    # day's progress follows the id from the server, so without the reset a
    # rerun opens on whatever round the last one reached.
    xcrun simctl uninstall "$id" "$BUNDLE" 2>/dev/null || true
    xcrun simctl keychain "$id" reset >/dev/null
    xcrun simctl install "$id" "$APP"
    # The round once its clip has loaded from stage (a cold first launch on
    # the iPad takes over ten seconds); then a second, warm launch with
    # autoplay, which guesses after 5 s and holds the reveal for 6, so 10 s
    # lands inside round one's reveal. The iPad simulator loads unevenly:
    # look at every frame before uploading, and rerun if one is still loading.
    shoot "$id" "$dir" 01-round 18 -tab Play
    shoot "$id" "$dir" 02-reveal 10 -tab Play -autoplay 1
    shoot "$id" "$dir" 03-boards 6 -owner 1 -tab Boards
    shoot "$id" "$dir" 04-settings 6 -tab Settings
    xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
    xcrun simctl status_bar "$id" clear
done
echo "done: $(find .build/screenshots -name '*.png' | wc -l | tr -d ' ') screenshots"
