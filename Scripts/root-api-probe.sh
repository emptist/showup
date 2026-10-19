#!/bin/bash
#
# Which macOS APIs work when showup is root?
#
# showup runs as root, and several of the APIs it might use are bound to the
# window server rather than to the kernel. A migration that works as you and
# returns nonsense as root is worse than the shell it replaced, so this is
# measured rather than assumed.
#
# Compile as yourself, then run it both ways and compare:
#
#     ./Scripts/root-api-probe.sh          # as you
#     sudo ./Scripts/root-api-probe.sh      # as root, which is how showup runs
#
# Compiling under sudo fails - root has no Swift toolchain - so the binary is
# built first and only the run is escalated.

set -euo pipefail

BINARY=/tmp/showup_root_api_probe
SOURCE=/tmp/showup_root_api_probe.swift

cat > "$SOURCE" <<'SWIFT'
import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration
import CoreGraphics
import CoreAudio
import AudioToolbox

func report(_ label: String, _ value: String) {
    print("\(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value)")
}

report("running as", "\(getuid())\(getuid() == 0 ? " (root)" : " (user)")")

// Console user: replacement for `sh -c "echo ... | scutil"` and a regex.
var uid: uid_t = 0
var gid: gid_t = 0
if let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) {
    report("SCDynamicStoreCopyConsole", "\(user) uid=\(uid) gid=\(gid)")
} else {
    report("SCDynamicStoreCopyConsole", "nil  <-- breaks the surfacing path")
}

// Idle counter: replacement for parsing HIDIdleTime out of ioreg.
let idle = CGEventSource.secondsSinceLastEventType(
    .combinedSessionState, eventType: CGEventType(rawValue: ~0)!
)
report("CGEventSource idle", String(format: "%.2fs%@", idle, idle > 86_400 ? "  <-- not a real counter" : ""))

// Volume: replacement for osascript.
var device = AudioObjectID(0)
var deviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
let found = AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &device
)
if found == noErr, device != 0 {
    var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: 0
    )
    var volume: Float32 = 0
    var volumeSize = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &volume)
    report("CoreAudio volume", status == noErr ? "\(Int(volume * 100))" : "status \(status)")
} else {
    report("CoreAudio volume", "no output device, status \(found)")
}

// RTC wakes still armed. showup asks for one every pass and has never cancelled
// any of them.
if let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue(),
    let all = (events as? [[String: Any]]) {
    let fromPmset = all.filter { ($0["scheduledby"] as? String) == "pmset" }
    report("RTC wakes armed", "\(fromPmset.count) from pmset, \(all.count) total")
    for event in fromPmset {
        report("  armed", "\(event["time"] ?? "?")")
    }
} else {
    report("RTC wakes armed", "could not be read")
}
SWIFT

if [[ ! -x "$BINARY" || "$SOURCE" -nt "$BINARY" ]]; then
    echo "building the probe..."
    swiftc -O "$SOURCE" -o "$BINARY"
fi

"$BINARY"