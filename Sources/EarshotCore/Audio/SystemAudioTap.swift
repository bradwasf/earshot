import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac is playing (Zoom, Meet, Teams, FaceTime…) with a Core Audio
/// process tap — no virtual audio device and no change to the user's output routing.
///
/// Requires macOS 14.4+ and the "System Audio Recording Only" privacy permission
/// (`NSAudioCaptureUsageDescription`). The tap is global and stereo; it is hosted in a private,
/// tap-only aggregate device that we read with an IOProc.
public final class SystemTapSource: CaptureSource {
    public let label = "system-tap"

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var reader: IOProcReader?
    private var handler: AudioChunkHandler?
    private var observer: AnyObject?
    private let lock = NSLock()
    private var lastOutputDeviceID: AudioDeviceID = kAudioObjectUnknown

    // Watchdog for the "tap delivers all-zero buffers" failure mode reported on recent macOS
    // releases (https://developer.apple.com/forums/thread/825780): if something is playing but
    // we only see digital silence, rebuild the tap.
    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "earshot.tap.watchdog")
    private var lastNonZero = HostClock.now
    private var lastRebuild = HostClock.now

    /// True once any non-silent audio has been captured (confirms the permission is granted).
    public private(set) var hasCapturedSignal = false

    public init() {}

    public func start(handler: @escaping AudioChunkHandler) throws {
        self.handler = handler
        try build()
        observer = AudioDevices.observeDefaultDeviceChanges { [weak self] in
            self?.outputDeviceMayHaveChanged()
        }
        let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler { [weak self] in self?.checkForStuckTap() }
        watchdog.resume()
        self.watchdog = watchdog
    }

    public func stop() {
        observer = nil
        watchdog?.cancel()
        watchdog = nil
        lock.withLock { teardown() }
    }

    deinit { stop() }

    // MARK: Build / teardown

    private func build() throws {
        try lock.withLock {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.excludedProcesses())
            description.uuid = UUID()
            description.name = "Earshot"
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tap = AudioObjectID(kAudioObjectUnknown)
            var status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr, tap != kAudioObjectUnknown else {
                throw AudioError.coreAudio("Creating the system audio tap", status)
            }
            tapID = tap

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Earshot-Tap",
                kAudioAggregateDeviceUIDKey: "earshot-tap-\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]
            var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
            guard status == noErr, aggregateDevice != kAudioObjectUnknown else {
                teardown()
                throw AudioError.coreAudio("Creating the tap aggregate device", status)
            }
            aggregateID = aggregateDevice

            let format: AudioStreamBasicDescription
            do {
                format = try HAL.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            } catch {
                teardown()
                throw error
            }

            do {
                let reader = try IOProcReader(deviceID: aggregateDevice, format: format, label: label)
                try reader.start { [weak self] samples, hostSeconds in
                    self?.deliver(samples, hostSeconds)
                }
                self.reader = reader
            } catch {
                teardown()
                throw error
            }
            lastOutputDeviceID = AudioDevices.defaultOutput()?.id ?? kAudioObjectUnknown
            lastNonZero = HostClock.now
            lastRebuild = HostClock.now
        }
    }

    /// Caller must hold `lock`.
    private func teardown() {
        reader?.stop()
        reader = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func rebuild() {
        lock.withLock { teardown() }
        try? build()
    }

    private func deliver(_ samples: [Float], _ hostSeconds: Double) {
        if samples.contains(where: { $0 != 0 }) {
            lastNonZero = HostClock.now
            hasCapturedSignal = true
        }
        handler?(samples, hostSeconds)
    }

    // MARK: Recovery

    private func outputDeviceMayHaveChanged() {
        guard let current = AudioDevices.defaultOutput()?.id, current != lastOutputDeviceID else { return }
        // The tap's format follows the output device (e.g. AirPods switching to 24 kHz), so rebuild.
        rebuild()
    }

    private func checkForStuckTap() {
        let now = HostClock.now
        guard now - lastNonZero > 10, now - lastRebuild > 30, Self.anotherProcessIsPlayingAudio() else { return }
        rebuild()
    }

    /// Processes left out of the tap. Normally none; the end-to-end test sets
    /// `EARSHOT_TAP_EXCLUDE_PIDS=<pid>,<pid>` so a helper can play "my voice" through the
    /// speakers (heard by the microphone only) while the remote side is played normally.
    private static func excludedProcesses() -> [AudioObjectID] {
        guard let list = ProcessInfo.processInfo.environment["EARSHOT_TAP_EXCLUDE_PIDS"] else { return [] }
        return list.split(separator: ",").compactMap { item -> AudioObjectID? in
            guard var pid = pid_t(item.trimmingCharacters(in: .whitespaces)) else { return nil }
            var address = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size,
                &object)
            return status == noErr && object != kAudioObjectUnknown ? object : nil
        }
    }

    /// True if any process other than ours currently has an active output stream.
    private static func anotherProcessIsPlayingAudio() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ownPID = getpid()
        for process in HAL.array(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
            let pid = (try? HAL.value(process, kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0
            guard pid != ownPID else { continue }
            let running = (try? HAL.value(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            if running != 0 { return true }
        }
        return false
    }
}
