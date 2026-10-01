#!/bin/bash
set -euo pipefail

# debug-host-pid.sh <path-to-.app>
# Prints the PID of the process whose executable or script command path is <app>/Contents/MacOS/Ainkrad.
# Prints nothing if there is none.

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  echo "Usage: $0 <path-to-.app>" >&2
  exit 1
fi

APP_PATH="${APP_PATH%/}"
TARGET_BIN="$(cd "$APP_PATH/Contents/MacOS" 2>/dev/null && pwd)/Ainkrad"

if [ -z "$TARGET_BIN" ]; then
  exit 0
fi

ps -axo pid=,command= | awk -v t="$TARGET_BIN" '
  BEGIN { found = 0 }
  {
    p = $1;
    sub(/^[ \t]*[0-9]+[ \t]+/, "");
    if (!found && ($0 == t || $0 ~ ("^/bin/sh " t "$") || $0 ~ ("^" t " "))) {
      print p;
      found = 1;
    }
  }
'
