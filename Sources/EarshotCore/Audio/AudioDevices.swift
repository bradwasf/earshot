import CoreAudio
import Foundation

/// A Core Audio device as shown in the pickers.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public var isBlackHole: Bool { name.localizedCaseInsensitiveContains("BlackHole") }
}

public enum AudioError: Error, LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    case deviceNotFound(String)
    case microphoneDenied

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let what, let status):
            return "\(what) failed (OSStatus \(status))"
        case .unsupportedFormat(let what):
            return "Unsupported audio format: \(what)"
        case .deviceNotFound(let what):
            return "Audio device not found: \(what)"
        case .microphoneDenied:
            return "Microphone access is denied. Enable it in System Settings › Privacy & Security › Microphone."
        }
    }
}

/// Thin typed wrappers over the Core Audio HAL property API.
enum HAL {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { throw AudioError.coreAudio("Reading property \(selector)", status) }
        return result
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result)
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type
    ) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

public enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func all() -> [AudioDeviceInfo] {
        HAL.array(system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self).compactMap(info(for:))
    }

    /// Devices that can be recorded from (microphones, BlackHole, aggregate inputs).
    public static func inputs() -> [AudioDeviceInfo] {
        all().filter { $0.inputChannels > 0 && !$0.name.hasPrefix("Earshot-Tap") }
    }

    public static func info(for id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = HAL.string(id, kAudioObjectPropertyName) ?? uid
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: name,
            inputChannels: HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    public static func defaultInput() -> AudioDeviceInfo? {
        guard
            let id = try? HAL.value(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0)),
            id != kAudioObjectUnknown
        else { return nil }
        return info(for: id)
    }

    public static func defaultOutput() -> AudioDeviceInfo? {
        guard
            let id = try? HAL.value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0)),
            id != kAudioObjectUnknown
        else { return nil }
        return info(for: id)
    }

    public static func device(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    /// The BlackHole loopback driver's input side, if the driver is installed.
    public static func blackHole() -> AudioDeviceInfo? {
        inputs().first { $0.isBlackHole }
    }

    /// Calls `handler` whenever the default input or output device changes.
    /// Returns a token; keep it alive for as long as you want callbacks.
    public static func observeDefaultDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        DefaultDeviceObserver(handler: handler)
    }
}

private final class DefaultDeviceObserver {
    private let block: AudioObjectPropertyListenerBlock
    private let queue = DispatchQueue(label: "earshot.device-observer")
    private let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]

    init(handler: @escaping @Sendable () -> Void) {
        block = { _, _ in handler() }
        for selector in selectors {
            var addr = HAL.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
    }

    deinit {
        for selector in selectors {
            var addr = HAL.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
    }
}
