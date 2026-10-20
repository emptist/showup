import CoreAudio
import CoreGraphics
import Foundation
import SystemConfiguration
import ShowupCore

extension Mac {
    // MARK: - The console session

    /// The uid of the person at the console.
    ///
    /// `SCDynamicStoreCopyConsoleUser` is the documented way to ask, and it
    /// answers identically as root and as a user - measured both, because showup
    /// runs as root and an API that only answers in one of the two is not
    /// usable here.
    ///
    /// showup is started after login and stopped before logout, so there is
    /// always a session. A zero would mean something has ended it.
    public static func consoleUID() -> Result<Int, ShowError> {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else {
            return .failure(.unavailable(what: "the console user", reason: "there is nobody logged in"))
        }
        guard uid != 0 else {
            return .failure(.unavailable(what: "the console user", reason: "the console is at the login window"))
        }
        _ = user  // the name is not needed; the uid is what launchctl wants
        return .success(Int(uid))
    }

    // MARK: - The idle counter

    /// How long the keyboard has been untouched, in whole seconds.
    ///
    /// Keys only, and deliberately: this is what stops the alarm, and a hand on
    /// the keyboard is what answers it. A trackpad twitch while nobody is there
    /// is not an answer.
    public static func keyboardIdleSeconds() -> Int? {
        secondsSinceLast(.keyDown)
    }

    /// How long the keyboard and mouse have been untouched, in whole seconds.
    ///
    /// `CGEventSource.secondsSinceLastEventType` is the documented counter. It
    /// replaces parsing `"HIDIdleTime"` out of an `ioreg` report and dividing by
    /// a billion, which is worth more than the line count: that parse once
    /// returned nanoseconds as seconds on the path where the field had no
    /// newline after it, and `ioreg` does not promise a final newline.
    ///
    /// Nil when the counter is not reading anything real, which is a different
    /// thing from zero: zero means the user is at the machine, and the alarm
    /// treats the two very differently.
    public static func idleSeconds() -> Int? {
        secondsSinceLast(CGEventType(rawValue: ~0)!)
    }

    private static func secondsSinceLast(_ eventType: CGEventType) -> Int? {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: eventType
        )
        guard seconds.isFinite, seconds >= 0, seconds < 86_400 else { return nil }
        return Int(seconds)
    }

    // MARK: - Speaker volume

    /// The default output device.
    private static func outputDevice() -> Result<AudioObjectID, ShowError> {
        var device = AudioObjectID(0)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let found = withUnsafeMutablePointer(to: &deviceAddress) { address in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), address, 0, nil, &deviceSize, &device
            )
        }
        guard found == noErr, device != 0 else {
            return .failure(.unavailable(what: "the output device", reason: "CoreAudio returned \(found)"))
        }
        return .success(device)
    }

    /// The output volume, 0 to 100, from the default output device.
    ///
    /// This was an `osascript` one-liner. The two agree - both read 31 on this
    /// machine - and this one does not need a scripting bridge to be resident
    /// with a GUI session.
    public static func speakerVolume() -> Result<Int, ShowError> {
        return switch outputDevice() {
        case .failure(let reason): .failure(reason)
        case .success(let device): volumeOn(device)
        }
    }

    /// Reads the volume property off a device.
    private static func volumeOn(_ device: AudioObjectID) -> Result<Int, ShowError> {
        var volume: Float32 = 0
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        let status = withUnsafeMutablePointer(to: &volumeAddress) { address in
            AudioObjectGetPropertyData(device, address, 0, nil, &volumeSize, &volume)
        }
        guard status == noErr else {
            return .failure(.unavailable(what: "the volume", reason: "CoreAudio returned \(status)"))
        }
        return .success(Int((volume * 100).rounded()))
    }

    /// Sets the output volume, 0 to 100, on the default output device.
    ///
    /// The write side of `speakerVolume()`: the same device, the same property,
    /// and the same element, so what is read back is what was written.
    public static func setSpeakerVolume(_ percent: Int) -> Result<Void, ShowError> {
        return switch outputDevice() {
        case .failure(let reason): .failure(reason)
        case .success(let device): setVolumeOn(device, to: percent)
        }
    }

    /// Writes the volume property on a device.
    private static func setVolumeOn(_ device: AudioObjectID, to percent: Int) -> Result<Void, ShowError> {
        var volume = Float32(min(max(percent, 0), 100)) / 100
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 0
        )
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        let status = withUnsafeMutablePointer(to: &volumeAddress) { address in
            AudioObjectSetPropertyData(device, address, 0, nil, volumeSize, &volume)
        }
        guard status == noErr else {
            return .failure(.unavailable(what: "the volume", reason: "CoreAudio returned \(status)"))
        }
        return .success(())
    }
}