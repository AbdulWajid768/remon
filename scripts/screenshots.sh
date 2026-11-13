#!/bin/zsh
# Regenerates the screenshots in docs/screenshots from the built app.
# Usage: scripts/screenshots.sh [name ...]      (no names → all of them)
#
# Needs a Debug build first:
#   xcodebuild -project Remon.xcodeproj -scheme Remon -configuration Debug -derivedDataPath build/DerivedData build
set -e
cd "$(dirname "$0")/.."
OUT=docs/screenshots
mkdir -p "$OUT"
TARGETS=("$@")

# run <name> <section> <wait> <window-title> [extra launch args…]
run() {
    local name=$1
    if (( ${#TARGETS} )) && ! (( ${TARGETS[(Ie)$name]} )); then return; fi
    echo "▸ $name"
    scripts/screenshot.sh "$2" "$OUT/$name.png" "$3" "$4" "${@:5}"
}

#   name             section       wait  title      extra launch args
run overview         overview       14   ''
run overview-light   overview       14   ''         -appearance Light
run system           system         16   ''
run apps             apps           14   ''
run connections      connections    14   ''
run map              map            20   ''
run history          history        14   ''
run log              log            14   ''
run speed-test       'speed test'   14   ''
run alerts           alerts         14   ''
run rules            rules          14   ''
run quick-open       apps           14   ''         -quickOpen YES
# The Settings window is titled after its selected tab; the menu bar panel is its own window.
run settings         overview       14   General    -openSettings YES
run menu-bar-panel   overview       14   'Menu Bar' -previewMenuPanel YES
# The welcome sheet — the screen whose mark the app icon is built from.
run onboarding       overview       14   ''         -showOnboarding YES

# The menu bar item itself — a strip of the real menu bar, not a window, so it is captured by region.
if (( ${#TARGETS} == 0 )) || (( ${TARGETS[(Ie)menu-bar-item]} )); then
    echo "▸ menu-bar-item"
    pkill -x Remon 2>/dev/null || true; sleep 1
    open -n build/DerivedData/Build/Products/Debug/Remon.app \
        --args -skipOnboarding YES -redactIdentity YES -showMenuBarItem YES
    sleep 14
    WIDTH=$(swift scripts/menu-bar-rect.swift)   # "<x> <y> <w> <h>" of the strip to grab
    screencapture -o -R "${WIDTH// /,}" "$OUT/menu-bar-item.png"
    echo "captured $OUT/menu-bar-item.png"
fi

pkill -x Remon 2>/dev/null || true
echo "done"
