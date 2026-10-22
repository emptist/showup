#!/bin/bash
# The install session: one password, at install, and nothing after.
#
# What lands where (run `sudo Scripts/install-session.sh <app> <times>`):
#   root, here and only here:
#     - the release build into /usr/local/bin, with its stamp
#     - /Library/LaunchDaemons/com.showup.renew.plist, and the daemon
#       started once, so tonight's moments are armed before the Mac sleeps
#   the user, from the same script, without needing any further password:
#     - the schedule contract, seeded by a dry-run
#     - ~/Library/LaunchAgents/com.showup.plist, started once at load
#
# Every step prints what it did with grounded paths, and a step that could
# not be carried out stops the script between steps, saying what is already
# true so far - what landed stays landed, and the receipt says so.
#
# Rerunning updates in place: plists are rewritten, the daemon and agent are
# bootout-ed before their bootstrap, and the contract is reseeded.

set -u

APP="${1:-}"
TIMES="${2:-}"
BUILD_DIR="${SHOWUP_BUILD_DIR:-.build/release}"

if [ "$(id -u)" -ne 0 ]; then
    echo "install-session: the root side of the install is what's behind the password:" >&2
    echo "install-session: run   sudo Scripts/install-session.sh <app> <times, like 04:00,08:00>" >&2
    exit 1
fi

die_step() {
    echo "install-session: FAILED: $*" >&2
    echo "install-session: what is already true is left in place; see the lines above." >&2
    exit 1
}

say() { echo "install-session: $*"; }

[ -n "$APP" ] || { echo "install-session: no app given. Usage: sudo Scripts/install-session.sh <app> <times, like 04:00,08:00>" >&2; exit 2; }
[ -n "$TIMES" ] || { echo "install-session: no times given. Usage: sudo Scripts/install-session.sh <app> <times, like 04:00,08:00>" >&2; exit 2; }

# The schedule belongs to whoever is at the keyboard, not to root:
# SUDO_USER answers even when the script itself runs as root.
CONSOLE_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
CONSOLE_UID=$(id -u "$CONSOLE_USER")
CONSOLE_GID=$(id -g "$CONSOLE_USER")
USER_CONTRACT_DIR=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
[ -z "$USER_CONTRACT_DIR" ] && USER_CONTRACT_DIR="/Users/$CONSOLE_USER"

SIGNED_DIR="$USER_CONTRACT_DIR/Library/Application Support/showup"
LOG_DIR="$USER_CONTRACT_DIR/Library/Logs/showup"

[ -f "$BUILD_DIR/showup" ] || die_step "no release build at $BUILD_DIR/showup - run make release first (make install-session does)"
[ -f "$BUILD_DIR/showup.stamp" ] || die_step "no build stamp at $BUILD_DIR/showup.stamp"

DAEMON_LABEL="com.showup.renew"
AGENT_LABEL="com.showup"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="$USER_CONTRACT_DIR/Library/LaunchAgents/$AGENT_LABEL.plist"

say "installing $CONSOLE_USER's schedule with app $APP at times $TIMES"

# --- root side ---

say "[1/6] copying the release binary and its stamp to /usr/local/bin"
mkdir -p /usr/local/bin || die_step "cannot create /usr/local/bin"
install -m 0755 "$BUILD_DIR/showup" /usr/local/bin/showup || die_step "cannot install the binary into /usr/local/bin"
install -m 0644 "$BUILD_DIR/showup.stamp" /usr/local/bin/showup.stamp || die_step "cannot install the build stamp"
say "      /usr/local/bin/showup and showup.stamp installed ($(cat /usr/local/bin/showup.stamp))"

say "[2/6] writing the renewal daemon plist"
mkdir -p "$LOG_DIR" || die_step "cannot create $LOG_DIR (the daemon's log ground)"
chown "$CONSOLE_USER" "$LOG_DIR" || die_step "cannot give $CONSOLE_USER their log ground"
cat > "$DAEMON_PLIST" <<EOF || die_step "cannot write $DAEMON_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$DAEMON_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/showup</string>
        <string>renew</string>
        <string>$SIGNED_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>0</integer>
        <key>Minute</key>
        <integer>5</integer>
    </dict>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/renew.log</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/renew.log</string>
</dict>
</plist>
EOF
chown root:wheel "$DAEMON_PLIST" || die_step "cannot give the daemon plist to root"
chmod 0644 "$DAEMON_PLIST" || die_step "cannot set the daemon plist's permissions"
say "      $DAEMON_PLIST written: program 'showup renew $SIGNED_DIR', daily at 00:05, telling its story in $LOG_DIR/renew.log"

say "[3/6] starting the renewal daemon once, so tonight's moments are armed now"
if launchctl bootout system/"$DAEMON_LABEL" 2>/dev/null; then
    say "      an older daemon was stopped first"
fi
launchctl bootstrap system "$DAEMON_PLIST" || die_step "cannot bootstrap the renewal daemon"
launchctl kickstart system/"$DAEMON_LABEL" || die_step "cannot run the first renewal"
say "      the daemon ran once (see its story in $LOG_DIR/renew.log)"

# --- the user side ---

say "[4/6] seeding the schedule contract (a dry-run, as $CONSOLE_USER, writes nothing but the contract)"
sudo -u "$CONSOLE_USER" /usr/local/bin/showup -a "$APP" -t "$TIMES" -n \
    || die_step "the contract seeding run failed"

say "[5/6] writing the user agent plist (program: bare 'showup', which serves the contract as it stands)"
sudo -u "$CONSOLE_USER" mkdir -p "$(dirname "$AGENT_PLIST")" \
    || die_step "cannot create $(dirname "$AGENT_PLIST")"
cat > /tmp/showup-agent.plist <<EOF || die_step "cannot write the agent plist staging file"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/showup</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartCalendarInterval</key>
    <array>
EOF
# Every moment the contract owes is a firing of its own, day at a time:
# launchd keeps the missed ones and fires them the next time the Mac is up.
for time in $(echo "$TIMES" | tr ',' ' '); do
    HOUR=$(echo "$time" | cut -d: -f1)
    HOUR=${HOUR#0}
    HOUR=$((10#$HOUR))
    MINUTE=$(echo "$time" | cut -d: -f2)
    MINUTE=${MINUTE:-0}
    MINUTE=$((10#$MINUTE))
    # 24:00 is the end of the day, which launchd has as the hour 0.
    [ "$HOUR" -eq 24 ] && HOUR=0
    cat >> /tmp/showup-agent.plist <<EOF || die_step "cannot extend the agent plist with the $time moment"
        <dict>
            <key>Hour</key>
            <integer>$HOUR</integer>
            <key>Minute</key>
            <integer>$MINUTE</integer>
        </dict>
EOF
done
cat >> /tmp/showup-agent.plist <<EOF || die_step "cannot finish the agent plist"
    </array>
</dict>
</plist>
EOF
chown "$CONSOLE_UID":"$CONSOLE_GID" /tmp/showup-agent.plist \
    || die_step "cannot give the staged agent plist to $CONSOLE_USER"
install -o "$CONSOLE_UID" -g "$CONSOLE_GID" -m 0644 /tmp/showup-agent.plist "$AGENT_PLIST" \
    || die_step "cannot install the agent plist"
rm -f /tmp/showup-agent.plist
say "      $AGENT_PLIST written: bare '/usr/local/bin/showup', at load and at $TIMES"

say "[6/6] starting the user agent"
if launchctl bootout gui/"$CONSOLE_UID"/"$AGENT_LABEL" 2>/dev/null; then
    say "      an older agent was stopped first"
fi
launchctl bootstrap gui/"$CONSOLE_UID" "$AGENT_PLIST" || die_step "cannot bootstrap the user agent"
say "      the agent started once at load (it will be at $LOG_DIR's newest file)"

# --- the receipt the README quotes ---

cat <<EOF

Install done. One password was asked for, this one's.
  contract     $SIGNED_DIR/schedule.txt ($APP at $TIMES)
  renewal      $DAEMON_PLIST, daily 00:05 and tonight's first pass already run
  night run    $AGENT_PLIST, started once; it stands and serves the contract
  everything   told in $LOG_DIR/

From here on, changing the schedule is a user act, no password:
  showup -a <app> -t <times>          (or the same with --dry-run)
The running night run and the next 00:05 renewal both follow the changed
contract without a restart or a password.

Uninstall, also with one password:  sudo Scripts/uninstall-session.sh

EOF
