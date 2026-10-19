#!/bin/bash
#
# Records what `scutil` says about the console user, repeatedly, with a stamp.
#
# The point is to have real output for each of the three states showup has to
# tell apart, rather than a guess or an older implementation:
#
#   1. at the desktop
#   2. at the lock screen        (what an RTC wake normally lands on)
#   3. at the login window       (what it looks like after "Lock Screen: Log out")
#
# Usage:  ./Scripts/console-user-probe.sh [seconds]
#
# Leave it running, do the things, then stop it. Everything lands in
# /tmp/showup_console_probe.log.

DURATION="${1:-180}"
OUT=/tmp/showup_console_probe.log

: > "$OUT"
echo "recording for ${DURATION}s into $OUT"

END=$(( $(date +%s) + DURATION ))
while (( $(date +%s) < END )); do
    {
        echo "----- $(date '+%Y-%m-%d %H:%M:%S') -----"
        sh -c "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil" 2>&1
        echo "lock state: $(ioreg -n Root -d1 -a 2>/dev/null | grep -c IOHIDLockState)"
    } >> "$OUT" 2>&1
    sleep 5
done

echo "done -> $OUT"