#!/bin/bash
#
# The sleep test.
#
# Output here is deliberately large, sparse and high contrast: the person
# running this reads it at a glance, mid-test, possibly half awake. Anything
# subtle is a thing they will miss and then be asked to debug.

set -euo pipefail

BOLD=$'\033[1m'
BRIGHT=$'\033[1;37m'
DIM=$'\033[2m'
OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
big()  { printf '\n%s%s%s\n\n' "$BOLD$BRIGHT" "$*" "$OFF"; }

APP="${1:-TextEdit}"
MINUTES="${2:-4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOWUP="$ROOT/.build/release/showup"
CAPTURE=/tmp/showup_sleep_test.log

if [[ ! -x "$SHOWUP" ]]; then
    big "BUILDING"
    (cd "$ROOT" && swift build -c release)
fi

# The log is named for the moment showup starts, so predict it rather than
# showing the newest one that happens to exist, which is usually an old run.
START_EPOCH=$(( $(date +%s) + 60 ))
PREDICTED="/var/log/showup${START_EPOCH}.log"

say "${BOLD}showup sleep test${OFF}"
say ""
say "${BOLD}app${OFF}      $APP"
say "${BOLD}appears${OFF}   $MINUTES minutes from now, at $(date -v"+${MINUTES}M" +%H:%M)"
say "${BOLD}log${OFF}       $PREDICTED"

big "STEP 1 of 3   TYPE YOUR PASSWORD"

read -r -p "  " _

say ""
say "${BOLD}${BRIGHT}STEP 2 of 3   THE MAC WILL SLEEP IN 10 SECONDS${OFF}"
say "  ${DIM}nothing to do. wait.${OFF}"

sudo "$SHOWUP" -a "$APP" -t "$(date -v"+${MINUTES}M" +%H:%M)" > "$CAPTURE" 2>&1 &
SHOWUP_PID=$!

sleep 10
say ""
say "${BOLD}${BRIGHT}STEP 2   SLEEPING NOW${OFF}"
sudo pmset sleepnow

# --- wait for the alarm, then say so as loudly as possible ---------------
say ""
big "STEP 3 of 3   WAIT FOR THE RINGING"

deadline=$(( $(date +%s) + MINUTES * 60 + 180 ))
while (( $(date +%s) < deadline )); do
    if grep -q "rang .* to be heard" "$CAPTURE" 2>/dev/null; then
        printf '\n\a\a%s%s  IT IS RINGING - UNLOCK NOW  %s%s\n\n' "$BOLD" "$BRIGHT" "$BRIGHT" "$OFF"
        break
    fi
    if grep -q "brought .* to the foreground" "$CAPTURE" 2>/dev/null; then
        break
    fi
    sleep 1
done

read -r -p "  ${DIM}press return when you are back at the machine${OFF} " _
sleep 20

big "WHAT HAPPENED"

if grep -q "brought .* to the foreground" "$CAPTURE" 2>/dev/null; then
    say "${BOLD}${BRIGHT}APP CAME UP${OFF}"
else
    say "${BOLD}${BRIGHT}APP DID NOT COME UP${OFF}"
fi

say ""
say "${BOLD}full transcript${OFF}"
sed 's/^/  /' "$CAPTURE"

say ""
say "${BOLD}${BRIGHT}IS $APP IN FRONT OF YOU NOW?${OFF}"
say "${BOLD}${BRIGHT}  YES / NO${OFF}"
read -r -p "  " _

kill "$SHOWUP_PID" 2>/dev/null || true
say ""
say "stopped."
say "log: $CAPTURE"
say "also: sudo cat $PREDICTED 2>/dev/null"