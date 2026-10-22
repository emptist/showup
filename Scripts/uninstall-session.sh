#!/bin/bash
# The uninstall session: one password, once, and showup is gone.
#
# Root side (here and only here):
#   - the renewal daemon is stopped and its plist removed
#   - any showup process of any identity is stopped, politely first
#   - the kernel's own wake list is cleared of showup's one-shots, read
#     from `pmset -g sched` rather than guessed
#   - the binary and its stamp are removed
# The user side:
#   - the agent is stopped and its plist removed
#   - the contract and the lock are removed with it
# The logs stay: they are the record of what ran, and the 7-day rule prunes
# them the way it always has.
#
# Every step prints what it did; a step that cannot be carried out is said
# out loud between steps, with what is already true.

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall-session: the root side of the uninstall is what's behind the password:" >&2
    echo "uninstall-session: run   sudo Scripts/uninstall-session.sh" >&2
    exit 1
fi

die_step() {
    echo "uninstall-session: FAILED: $*" >&2
    echo "uninstall-session: what is already true is left in place; see the lines above." >&2
    exit 1
}

say() { echo "uninstall-session: $*"; }

CONSOLE_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
CONSOLE_UID=$(id -u "$CONSOLE_USER")
USER_CONTRACT_DIR=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
[ -z "$USER_CONTRACT_DIR" ] && USER_CONTRACT_DIR="/Users/$CONSOLE_USER"

SIGNED_DIR="$USER_CONTRACT_DIR/Library/Application Support/showup"

DAEMON_LABEL="com.showup.renew"
AGENT_LABEL="com.showup"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="$USER_CONTRACT_DIR/Library/LaunchAgents/$AGENT_LABEL.plist"

say "uninstalling showup's install for $CONSOLE_USER"

say "[1/5] stopping the renewal daemon and removing its plist"
if launchctl bootout system/"$DAEMON_LABEL" 2>/dev/null; then
    say "      the daemon was stopped"
else
    say "      the daemon was not running"
fi
rm -f "$DAEMON_PLIST" && say "      $DAEMON_PLIST removed"

say "[2/5] stopping any showup that is still running"
# The agent is going out next, but a hand-started run, or one a kill left
# alive, does not belong to launchd. A polite stop lets its own exit handler
# take its kernel wake back; the sweep behind this step catches whatever
# survives.
if pgrep -x showup >/dev/null; then
    pkill -x showup && say "      the running showup was asked to stop"
    sleep 3
    pkill -9 -x showup 2>/dev/null && say "      one showup refused to stop and was killed"
else
    say "      none was running"
fi

say "[3/5] taking back the wakes showup armed in the kernel"
SCHED=$(pmset -g sched 2>/dev/null)
# One-shots read: "[0]  wake at 10/22/2026 18:40:44 by 'owner'". Only the
# entries under showup's own tag belong to it; everyone else's alarms are
# not this script's business.
ENTRIES=$(echo "$SCHED" | grep -E 'wake at [0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}' | grep "com\.showup\.wake")
if [ -z "$ENTRIES" ]; then
    say "      none of the kernel's scheduled wakes belong to showup; nothing to take back"
else
    echo "$ENTRIES" | while IFS= read -r entry; do
        WHEN=$(echo "$entry" | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}')
        if [ -n "$WHEN" ]; then
            if pmset schedule cancel wake "$WHEN"; then
                say "      took back the wake at $WHEN"
            else
                say "      WARNING the kernel did not take back the wake at $WHEN (pmset refused)"
            fi
        else
            say "      WARNING could not read a wake instant out of: $entry"
        fi
    done
fi

say "[4/5] stopping the user agent and removing its plist"
if launchctl bootout gui/"$CONSOLE_UID"/"$AGENT_LABEL" 2>/dev/null; then
    say "      the agent was stopped"
else
    say "      the agent was not running"
fi
rm -f "$AGENT_PLIST" && say "      $AGENT_PLIST removed"

say "[5/5] removing the binary, the contract and the lock (the logs and their 7-day rule stay)"
rm -f /usr/local/bin/showup /usr/local/bin/showup.stamp && say "      the installed binary is gone"
rm -f "$SIGNED_DIR/schedule.txt" "$SIGNED_DIR/showup.lock" /var/db/showup.lock 2>/dev/null
[ -d "$SIGNED_DIR" ] && rmdir "$SIGNED_DIR" 2>/dev/null
say "      the contract and the locks are gone"

cat <<EOF

Uninstall done. One password was asked for, this one's.
  the renewal daemon is stopped and gone
  any showup that was still running was stopped
  the kernel list holds no wake of showup's (check: pmset -g sched)
  the agent is stopped and gone
  the binary is gone
  the logs told their story in $USER_CONTRACT_DIR/Library/Logs/showup and stay until the 7-day rule clears them

EOF
