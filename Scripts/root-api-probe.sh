#!/bin/bash
#
# Which macOS APIs work when showup is root?
#
# showup runs as root, and several of the APIs it might use are bound to the
# window server rather than to the kernel. A migration that works as you and
# returns nonsense as root is worse than the shell it replaced, so this is
# measured rather than assumed.
#
# Run it as root, which is how showup actually runs:
#
#     sudo ./Scripts/root-api-probe.sh
#
# Then run it again without sudo and compare the two columns.

exec swift /dev/stdin "$@" <<'SWIFT'
import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration
import CoreGraphics
import CoreAudio
import AudioToolbox

func report(_ label: String, _ value: String) {
    print(String(format: "%-26@ %@", label as NSString, value as NSString))
}

report("running as", "\(getuid()) \(getuid() == 0 ? "(root)" : "(user)")")

// --- console user: replacement for `sh -c "echo ... | scutil"` ---
var uid: uid_t = 0
var gid: gid_t = 0
if let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) {
    report("SCDynamicStoreCopyConsoleUser", "\(user) uid=\(uid) gid=\(gid)")
} else {
    report("SCDynamicStoreCopyConsoleUser", "nil  <-- would break the surfacing path")
}

// --- idle counter: replacement for parsing HIDIdleTime out of ioreg ---
let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
report("CGEventSource idle", String(format: "%.2fs", idle))
if idle > 86_400 { report("  ^", "implausible: no window server session, this counter is not real") }

// --- volume: replacement for osascript ---
var device = AudioObjectID(0)
var deviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
let found = AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &device)
if found == noErr, device != 0 {
    var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: 0)
    var volume: Float32 = 0
    var volumeSize = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &volume)
    report("CoreAudio volume", status == noErr ? "\(Int(volume * 100))" : "status \(status)")
} else {
    report("CoreAudio volume", "no output device, status \(found)")
}

// --- what the alarm would actually check against ---
// --- scheduled RTC wakes: are any left armed? ---
if let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() {
    let all = (events as? [[String: Any]]) ?? []
    let pmset = all.filter { ($0["scheduledby"] as? String) == "pmset" }
    report("RTC wakes armed", "\(pmset.count) from pmset, \(all.count) in total")
    for event in pmset {
        report("  armed", "\(event["time"] ?? "?")")
    }
} else {
    report("RTC wakes armed", "could not be read")
}
SWIFT