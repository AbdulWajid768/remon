#!/bin/zsh
# Launches Remon on a section and captures a window.
# Usage: scripts/screenshot.sh <section> <out.png> [wait-seconds] [window-title] [extra launch args...]
set -e
APP="${APP:-build/DerivedData/Build/Products/Debug/Remon.app}"
SECTION=$1; OUT=$2; WAIT=${3:-12}; TITLE=${4:-}
shift 4 2>/dev/null || shift $#
pkill -x Remon 2>/dev/null || true
for i in {1..20}; do pgrep -x Remon >/dev/null || break; sleep 0.5; done; pkill -9 -x Remon 2>/dev/null || true
open -n "$APP" --args -initialSection "$SECTION" -skipOnboarding YES -selectTop YES "$@"
sleep "$WAIT"
WID=$(swift scripts/window-id.swift Remon $TITLE)
screencapture -o -l "$WID" "$OUT"
echo "captured $OUT (window $WID)"
