#!/bin/bash
#
# Samples the login-state signals every 2 seconds, with a stamp.
#
# The question: what do the signals say when the screen is LOCKED, which is
# the state an RTC wake lands on? The scutil record carries
# kCGSessionLoginDoneKey, and ioreg carries IOHIDLockState. Which of them
# changes when the screen locks?
#
# Usage:  ./Scripts/lock-state-probe.sh [seconds]
#
# It writes to /tmp/showup_lock_state.log and prints nothing, so it can run in
# the background while the screen is locked and unlocked.

DURATION="${1:-60}"
OUT=/tmp/showup_lock_state.log

: > "$OUT"
echo "recording for ${DURATION}s into $OUT"

END=$(( $(date +%s) + DURATION ))
while (( $(date +%s) < END )); do
    {
        printf '%s  ' "$(date '+%H:%M:%S')"
        printf 'lock=%s  ' "$(ioreg -n Root -d1 -a 2>/dev/null | grep -c IOHIDLockState)"
        printf 'loginDone=%s  ' "$(sh -c "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil" 2>/dev/null | grep -o 'kCGSessionLoginDoneKey : [A-Z]*' | head -1 | cut -d' ' -f3)"
        printf 'onConsole=%s  ' "$(sh -c "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil" 2>/dev/null | grep -o 'kCGSSessionOnConsoleKey : [A-Z]*' | head -1 | cut -d' ' -f3)"
        printf 'uid=%s\n' "$(id -u)"
    } >> "$OUT" 2>&1
    sleep 2
done

echo "done -> $OUT"
