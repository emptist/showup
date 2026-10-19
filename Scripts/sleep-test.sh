#!/bin/bash
#
# The test that cannot be simulated: put the Mac to sleep for real, let the RTC
# alarm bring it back, and see whether the alarm is heard and the app is waiting
# after you log in.
#
# Usage:  ./Scripts/sleep-test.sh [AppName] [minutesFromNow]
#
# Everything that can be faked is faked in the test suite. This is the rest.
#
# Needs sudo, twice: once for pmset, once for the sleep itself. showup runs
# under sudo too, so it can schedule the RTC wake.

set -euo pipefail

APP="${1:-TextEdit}"
MINUTES="${2:-4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOWUP="$ROOT/.build/release/showup"
CAPTURE=/tmp/showup_sleep_test.log

if [[ ! -x "$SHOWUP" ]]; then
    echo "building showup..."
    (cd "$ROOT" && swift build -c release)
fi

echo "== asking for sudo =="
sudo -v

# Both timestamps come from the same clock, or the wake and the app land on
# different minutes.
TARGET="$(date -v"+${MINUTES}M" +%H:%M)"
TARGET_STAMP="$(date -v"+${MINUTES}M" +"%Y-%m-%d %H:%M:%S")"

echo
echo "  app          $APP"
echo "  surfaces at  $TARGET   (in $MINUTES minutes)"
echo "  showup file  $(ls -t /var/log/showup*.log 2>/dev/null | head -1 || echo '(will be created)')"
echo
echo "  What happens:"
echo "    1. showup asks the kernel to wake the Mac a minute early."
echo "    2. This script sleeps the Mac for real."
echo "    3. The RTC alarm brings it back and the alarm rings."
echo "    4. LOG IN. The app should already be launched and waiting for you."
echo
echo "  Starting at $TARGET_STAMP"
echo
read -r -p "  Press return to begin. " _

# showup is run as root because only root may set the RTC wake.
sudo "$SHOWUP" -a "$APP" -t "$TARGET" 2>&1 | tee "$CAPTURE" &
SHOWUP_PID=$!

# Let showup schedule the wake before the machine goes down, or there is
# nothing to wake it.
sleep 10

echo
echo "== sleeping the Mac now =="
sudo pmset sleepnow

echo "== the Mac should wake by itself =="
echo "   (press return here only if it does not)"
read -r -p "   " _

wait "$SHOWUP_PID" 2>/dev/null || true
echo
echo "== done. transcript: $CAPTURE =="