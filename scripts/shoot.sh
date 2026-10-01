#!/bin/bash
# Screenshot the editor, so "does this look right?" costs seconds.
#
#   ./scripts/shoot.sh out.png            # whatever is open
#   ./scripts/shoot.sh out.png --pid 1234 # target specific PID
#
# Deliberately does NOT open a named note: nothing in the host takes a note as
# a launch argument, and a script that pretended to would be worse than one
# that is honest about needing the note open already.
set -euo pipefail
OUT="${1:-editor.png}"
PID=""

if [ "${2:-}" = "--pid" ]; then
  PID="${3:-}"
elif [ $# -ge 2 ]; then
  echo "Usage: $0 [out.png] [--pid PID]" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
LORE_ROOT="$(cd "$HERE/.." && pwd)"
DEBUG_APP="$LORE_ROOT/../Ainkrad/build/Build/Products/Debug/Ainkrad.app"

if [ -z "$PID" ]; then
  PID="$("$HERE/debug-host-pid.sh" "$DEBUG_APP")"
fi

if [ -z "$PID" ]; then
  echo "Debug Ainkrad is not running — try: make run" >&2
  exit 1
fi

HELPER="$HERE/.window-bounds"

# Built on demand and cached; it is 30 lines and needs no build system.
if [ ! -x "$HELPER" ] || [ "$HERE/window-bounds.swift" -nt "$HELPER" ]; then
  swiftc -O "$HERE/window-bounds.swift" -o "$HELPER"
fi

# Activate first. An occluded window captures whatever is in front of it, and a
# region capture cannot tell the difference — so this would silently produce a
# screenshot of the terminal.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
sleep 1.5

REGION="$("$HELPER" "$PID")"
screencapture -x -R "$REGION" "$OUT"
echo "$OUT  ($REGION)"
