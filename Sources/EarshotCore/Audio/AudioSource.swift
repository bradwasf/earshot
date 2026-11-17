import AVFoundation
import CoreAudio
import Foundation

/// The two sides of a call. Each side is captured, transcribed and labelled separately.
public enum Channel: String, Codable, Sendable, CaseIterable {
    /// Your microphone.
    case me
    /// System audio: everyone else on the call.
    case them
}

public enum Audio {
    /// Everything downstream of capture (VAD, ASR, diarization, echo cancellation) runs at 16 kHz mono.
    public static let sampleRate = 16_000
}

/// Monotonic host clock in seconds (mach_absolute_time based), shared by every capture source.
public enum HostClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    public static var now: Double { seconds(mach_absolute_time()) }

    public static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * secondsPerTick
    }
}

/// Receives 16 kHz mono samples plus the host-clock time of the first sample.
public typealias AudioChunkHandler = @Sendable (_ samples: [Float], _ hostSeconds: Double) -> Void

/// A stream of 16 kHz mono audio: the system tap, a microphone, BlackHole, or a file (tests).
public protocol CaptureSource: AnyObject {
    var label: String { get }
    func start(handler: @escaping AudioChunkHandler) throws
    func stop()
}

// MARK: - Sample conversion

/// Streaming mono resampler to 16 kHz.
final class MonoResampler {
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let ratio: Double

    init(sourceRate: Double) throws {
        guard
            let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(Audio.sampleRate), channels: 1,
                interleaved: false)
        else { throw AudioError.unsupportedFormat("sample rate \(sourceRate)") }
        self.inFormat = inFormat
        self.outFormat = outFormat
        self.ratio = Double(Audio.sampleRate) / sourceRate
        if sourceRate == Double(Audio.sampleRate) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw AudioError.unsupportedFormat("cannot resample from \(sourceRate) Hz")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            self.converter = converter
        }
    }

    func process(_ input: [Float]) -> [Float] {
        guard let converter, !input.isEmpty else { return input }
        guard
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)),
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(input.count) * ratio) + 64)
        else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: input.count)
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, outBuffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }
}

enum SampleMixing {
    /// Averages the first `maxChannels` channels of a Float32 HAL buffer list into mono.
    /// Handles both interleaved (one buffer, N channels) and non-interleaved (N buffers) layouts.
    static func mono(_ list: UnsafePointer<AudioBufferList>, maxChannels: Int = 2) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var channels: [(pointer: UnsafePointer<Float>, stride: Int)] = []
        var frames = Int.max
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, let data = buffer.mData else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            frames = min(frames, bufferFrames)
            let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            for channel in 0..<channelCount where channels.count < maxChannels {
                channels.append((base + channel, channelCount))
            }
            if channels.count >= maxChannels { break }
        }
        guard !channels.isEmpty, frames != Int.max, frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        let gain = 1 / Float(channels.count)
        for (pointer, stride) in channels {
            for frame in 0..<frames {
                out[frame] += pointer[frame * stride] * gain
            }
        }
        return out
    }
}

// MARK: - HAL IOProc reader

/// Runs an IOProc on a Core Audio device and delivers its input as 16 kHz mono.
/// Used for microphones, BlackHole, and the private aggregate device that hosts the system tap.
final class IOProcReader {
    private let deviceID: AudioObjectID
    private let resampler: MonoResampler
    private let queue: DispatchQueue
    private var procID: AudioDeviceIOProcID?
    private var running = false

    init(deviceID: AudioObjectID, format: AudioStreamBasicDescription, label: String) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32
        else {
            throw AudioError.unsupportedFormat("\(label): expected 32-bit float PCM")
        }
        self.deviceID = deviceID
        self.resampler = try MonoResampler(sourceRate: format.mSampleRate)
        self.queue = DispatchQueue(label: "earshot.capture.\(label)", qos: .userInteractive)
    }

    func start(handler: @escaping AudioChunkHandler) throws {
        let resampler = self.resampler
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) {
            _, inputData, inputTime, _, _ in
            let mono = SampleMixing.mono(inputData)
            guard !mono.isEmpty else { return }
            let hostSeconds =
                inputTime.pointee.mFlags.contains(.hostTimeValid) && inputTime.pointee.mHostTime != 0
                ? HostClock.seconds(inputTime.pointee.mHostTime)
                : HostClock.now - Double(mono.count) / 48_000
            let samples = resampler.process(mono)
            if !samples.isEmpty { handler(samples, hostSeconds) }
        }
        guard status == noErr, let procID else { throw AudioError.coreAudio("Creating IOProc", status) }
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            throw AudioError.coreAudio("Starting device", status)
        }
        running = true
    }

    func stop() {
        guard let procID else { return }
        if running { AudioDeviceStop(deviceID, procID) }
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        running = false
    }

    deinit { stop() }
}

// MARK: - Input device (microphone or BlackHole)

/// Captures a physical or virtual input device. `uid == nil` follows the system default input.
public final class DeviceInputSource: CaptureSource {
    public let label: String
    private let uid: String?
    private var reader: IOProcReader?
    private var handler: AudioChunkHandler?
    private var observer: AnyObject?
    private let lock = NSLock()

    public init(uid: String?, label: String) {
        self.uid = uid
        self.label = label
    }

    public func start(handler: @escaping AudioChunkHandler) throws {
        self.handler = handler
        try open()
        if uid == nil {
            // Follow the default input when it changes mid-call (AirPods connect, dock unplugged…).
            observer = AudioDevices.observeDefaultDeviceChanges { [weak self] in
                self?.reopen()
            }
        }
    }

    private func open() throws {
        let device: AudioDeviceInfo?
        if let uid { device = AudioDevices.device(uid: uid) } else { device = AudioDevices.defaultInput() }
        guard let device, device.inputChannels > 0 else {
            throw AudioError.deviceNotFound(uid ?? "default input")
        }
        let format = try HAL.value(
            device.id, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput,
            initial: AudioStreamBasicDescription())
        let reader = try IOProcReader(deviceID: device.id, format: format, label: label)
        guard let handler else { return }
        try reader.start(handler: handler)
        lock.withLock { self.reader = reader }
        currentDeviceID = device.id
    }

    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown

    private func reopen() {
        guard let now = AudioDevices.defaultInput(), now.id != currentDeviceID else { return }
        lock.withLock {
            reader?.stop()
            reader = nil
        }
        try? open()
    }

    public func stop() {
        observer = nil
        lock.withLock {
            reader?.stop()
            reader = nil
        }
    }
}

// MARK: - File playback (tests and the simulated end-to-end run)

/// Plays an audio file into the pipeline at real-time pace, as if it were a live device.
/// After the file ends it keeps delivering silence so the stream stays continuous.
public final class FileAudioSource: CaptureSource {
    public let label: String
    public let duration: Double
    private let samples: [Float]
    private let startDelay: Double
    private let speed: Double
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue

    /// - Parameters:
    ///   - samples: 16 kHz mono audio.
    ///   - startDelay: seconds of leading silence before the file starts.
    public init(samples: [Float], label: String, startDelay: Double = 0, speed: Double = 1) {
        self.samples = samples
        self.label = label
        self.startDelay = startDelay
        self.speed = speed
        self.duration = startDelay + Double(samples.count) / Double(Audio.sampleRate)
        self.queue = DispatchQueue(label: "earshot.file.\(label)", qos: .userInteractive)
    }

    public func start(handler: @escaping AudioChunkHandler) throws {
        let begin = HostClock.now
        var delivered = 0  // samples of stream delivered so far (including leading silence)
        let leading = Int(startDelay * Double(Audio.sampleRate))
        let samples = self.samples
        let speed = self.speed
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler {
            let target = Int((HostClock.now - begin) * speed * Double(Audio.sampleRate))
            guard target > delivered else { return }
            var chunk = [Float](repeating: 0, count: target - delivered)
            let fileStart = delivered - leading
            for index in 0..<chunk.count {
                let fileIndex = fileStart + index
                if fileIndex >= 0 && fileIndex < samples.count { chunk[index] = samples[fileIndex] }
            }
            let hostSeconds = begin + Double(delivered) / Double(Audio.sampleRate) / speed
            delivered = target
            handler(chunk, hostSeconds)
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
