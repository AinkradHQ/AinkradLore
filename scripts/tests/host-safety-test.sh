#!/bin/bash
set -euo pipefail

# host-safety-test.sh
# Verification script for Task 0.3: host safety & PID isolation.

HERE="$(cd "$(dirname "$0")" && pwd)"
LORE_ROOT="$(cd "$HERE/../.." && pwd)"

# 1. Static check: ensure dangerous commands / patterns are absent
MAKEFILE="$LORE_ROOT/Makefile"
SHOOT="$LORE_ROOT/scripts/shoot.sh"
BOUNDS="$LORE_ROOT/scripts/window-bounds.swift"

if grep -E -q 'pkill|killall|pgrep -x|process whose name' "$MAKEFILE" "$SHOOT"; then
  echo "FAIL: Unsafe process name matching found in Makefile or shoot.sh" >&2
  exit 1
fi

if grep -q 'kCGWindowOwnerName' "$BOUNDS"; then
  echo "FAIL: kCGWindowOwnerName found in window-bounds.swift (must filter by kCGWindowOwnerPID)" >&2
  exit 1
fi

if ! grep -q 'AINKRAD := \$(abspath \$(CURDIR)/\.\./Ainkrad)' "$MAKEFILE"; then
  echo "FAIL: AINKRAD path in Makefile is not relative/correct" >&2
  exit 1
fi

# 2. Behaviour check: PID isolation & edge cases
DEBUG_APP_DIR="$(mktemp -d)/Debug/Ainkrad.app/Contents/MacOS"
DAILY_APP_DIR="$(mktemp -d)/Applications/Ainkrad.app/Contents/MacOS"

mkdir -p "$DEBUG_APP_DIR" "$DAILY_APP_DIR"

cat <<'EOF' > "$DEBUG_APP_DIR/Ainkrad"
#!/bin/sh
while true; do sleep 1; done
EOF
chmod +x "$DEBUG_APP_DIR/Ainkrad"

cat <<'EOF' > "$DAILY_APP_DIR/Ainkrad"
#!/bin/sh
while true; do sleep 1; done
EOF
chmod +x "$DAILY_APP_DIR/Ainkrad"

# Case (b): Nothing running -> empty output, status 0
set +e
EMPTY_OUTPUT="$("$LORE_ROOT/scripts/debug-host-pid.sh" "$(dirname "$(dirname "$DEBUG_APP_DIR")")")"
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
  echo "FAIL: debug-host-pid.sh exited with status $STATUS when nothing was running" >&2
  exit 1
fi

if [ -n "$EMPTY_OUTPUT" ]; then
  echo "FAIL: debug-host-pid.sh resolved '$EMPTY_OUTPUT' when nothing is running" >&2
  exit 1
fi

# Case (a): Only daily stub running -> empty output, status 0
"$DAILY_APP_DIR/Ainkrad" &
DAILY_PID=$!

trap 'kill -9 ${DAILY_PID:-} ${DEBUG_PID:-} 2>/dev/null || true' EXIT

sleep 0.5

set +e
DAILY_ONLY_OUTPUT="$("$LORE_ROOT/scripts/debug-host-pid.sh" "$(dirname "$(dirname "$DEBUG_APP_DIR")")")"
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
  echo "FAIL: debug-host-pid.sh exited with status $STATUS when only Daily host was running" >&2
  exit 1
fi

if [ -n "$DAILY_ONLY_OUTPUT" ]; then
  echo "FAIL: debug-host-pid.sh resolved '$DAILY_ONLY_OUTPUT' when only Daily host was running" >&2
  exit 1
fi

# Debug stub running as well -> exact Debug PID resolved, status 0
"$DEBUG_APP_DIR/Ainkrad" &
DEBUG_PID=$!

sleep 0.5

set +e
RESOLVED_PID="$("$LORE_ROOT/scripts/debug-host-pid.sh" "$(dirname "$(dirname "$DEBUG_APP_DIR")")")"
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
  echo "FAIL: debug-host-pid.sh exited with status $STATUS ($RESOLVED_PID) when Debug host was running" >&2
  exit 1
fi

if [ "$RESOLVED_PID" != "$DEBUG_PID" ]; then
  echo "FAIL: debug-host-pid.sh resolved PID '$RESOLVED_PID', expected Debug PID '$DEBUG_PID' (Daily PID was '$DAILY_PID')" >&2
  exit 1
fi

echo "PASS: host-safety-test.sh passed successfully."
