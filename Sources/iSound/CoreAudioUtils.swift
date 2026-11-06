import CoreAudio
import Foundation

/// Small helpers for reading Core Audio object properties.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size (plain value) property.
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       initial: T) -> T? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? value : nil
    }

    static func getIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>? = nil
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown))
        return (id == nil || id == AudioDeviceID(kAudioObjectUnknown)) ? nil : id
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? { getString(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ object: AudioObjectID) -> String? { getString(object, kAudioObjectPropertyName) }

    static func inputStreamCount(_ device: AudioDeviceID) -> Int {
        getIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
    }
}

struct CAError: LocalizedError {
    let message: String
    init(_ what: String, _ status: OSStatus) { message = "\(what) failed (\(status))" }
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reads and nudges an output device's hardware volume in decibels.
enum DeviceVolume {
    /// Volume elements that can be set: the main element, or else the individual channels.
    static func elements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        func settable(_ el: AudioObjectPropertyElement) -> Bool {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                  mScope: kAudioObjectPropertyScopeOutput, mElement: el)
            var ok: DarwinBoolean = false
            return AudioObjectHasProperty(device, &addr)
                && AudioObjectIsPropertySettable(device, &addr, &ok) == noErr && ok.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    static func decibels(_ device: AudioDeviceID, _ el: AudioObjectPropertyElement) -> Float32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: el)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func range(_ device: AudioDeviceID, _ el: AudioObjectPropertyElement) -> AudioValueRange? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: el)
        var value = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setDecibels(_ device: AudioDeviceID, _ el: AudioObjectPropertyElement, _ db: Float32) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: el)
        var value = db
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Shifts the device volume by `delta` dB (clamped to its range). Returns the shift actually applied.
    @discardableResult
    static func shift(_ device: AudioDeviceID, by delta: Float32) -> Float32 {
        let els = elements(device)
        guard !els.isEmpty, delta != 0 else { return 0 }
        var applied: Float32 = 0
        for el in els {
            guard let now = decibels(device, el), let r = range(device, el) else { continue }
            let target = min(max(now + delta, Float32(r.mMinimum)), Float32(r.mMaximum))
            setDecibels(device, el, target)
            applied = (decibels(device, el) ?? target) - now
        }
        return applied
    }

    /// Loudest channel's level in dB.
    static func currentDB(_ device: AudioDeviceID) -> Float32? {
        elements(device).compactMap { decibels(device, $0) }.max()
    }

    static func maxDB(_ device: AudioDeviceID) -> Float32? {
        elements(device).first.flatMap { range(device, $0) }.map { Float32($0.mMaximum) }
    }

    /// Converts between the volume slider position (0…1) and dB using the device's own curve.
    static func convert(_ device: AudioDeviceID, _ value: Float32, toScalar: Bool) -> Float32? {
        guard let el = elements(device).first else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: toScalar ? kAudioDevicePropertyVolumeDecibelsToScalar : kAudioDevicePropertyVolumeScalarToDecibels,
            mScope: kAudioObjectPropertyScopeOutput, mElement: el)
        var v = value
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    /// Sets every channel to `db` (clamped). Returns the resulting level.
    @discardableResult
    static func setDB(_ device: AudioDeviceID, _ db: Float32) -> Float32? {
        for el in elements(device) {
            guard let r = range(device, el) else { continue }
            setDecibels(device, el, min(max(db, Float32(r.mMinimum)), Float32(r.mMaximum)))
        }
        return currentDB(device)
    }

    static func device(withUID uid: String) -> AudioDeviceID? {
        CA.getIDs(CA.system, kAudioHardwarePropertyDevices).first { CA.deviceUID($0) == uid }
    }
}
