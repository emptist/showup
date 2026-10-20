#!/bin/bash
#
# Records what the machine says about the login state, repeatedly, with a stamp.
#
# The question showup has to answer in program 2: the alarm stops at the first
# key press, and that key press may be the first letter of a password typed at
# the login window. The app must not be brought up before the login has
# finished, because the activation does not survive the screen coming back.
#
# So: is the screen locked, and is the login finished? The candidates:
#
#   1. `scutil show State:/Users/ConsoleUser` - the ConsoleUser record, which
#      carries `kCGSessionLoginDoneKey` and `kCGSSessionOnConsoleKey`. This is
#      the same record `CGSessionCopyCurrentDictionary` returns, but through a
#      shell tool, so it answers as root as well as as the user.
#   2. `SCDynamicStoreCopyConsoleUser` - the console uid. Zero means nobody is
#      logged in, which is the state after "Lock Screen: Log out".
#   3. The keyboard counter - the alarm's own signal, for comparison.
#
# The three states to tell apart:
#
#   1. at the desktop
#   2. at the lock screen     (what an RTC wake normally lands on)
#   3. at the login window    (what it looks like after "Lock Screen: Log out")
#
# Usage:  ./Scripts/login-state-probe.sh [seconds]
#
# Leave it running, do the things, then stop it. Everything lands in
# /tmp/showup_login_state.log.

DURATION="${1:-180}"
OUT=/tmp/showup_login_state.log

: > "$OUT"
echo "recording for ${DURATION}s into $OUT"
echo "scutil as user:" >> "$OUT"

END=$(( $(date +%s) + DURATION ))
while (( $(date +%s) < END )); do
    {
        echo "----- $(date '+%Y-%m-%d %H:%M:%S') uid=$(id -u) -----"
        sh -c "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil" 2>&1 | head -8
    } >> "$OUT" 2>&1
    sleep 5
done

echo "done -> $OUT"
