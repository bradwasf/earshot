import AVFoundation
import Foundation

public enum SystemAudioChoice: Sendable, Equatable {
    /// Core Audio process tap (default; no virtual device needed).
    case tap
    /// Record an input device that carries system audio, e.g. "BlackHole 2ch".
    case device(uid: String)
    /// Microphone only.
    case none
}

public struct SessionConfig: Sendable {
    public var title: String
    /// True when the user did not type a title, so the summary may rename the call.
    public var titleIsPlaceholder: Bool
    public var root: URL
    public var systemAudio: SystemAudioChoice
    public var captureMicrophone: Bool
    /// nil follows the system default input device.
    public var microphoneUID: String?
    /// Save audio.m4a (left = Me, right = Them) next to the transcript. Off by default.
    public var saveAudio: Bool
    /// Drop "Me" lines that merely repeat what the far end just said (speaker bleed).
    public var echoTextGuard: Bool

    public init(
        title: String, titleIsPlaceholder: Bool = false, root: URL = CallFolder.defaultRoot,
        systemAudio: SystemAudioChoice = .tap, captureMicrophone: Bool = true, microphoneUID: String? = nil,
        saveAudio: Bool = false, echoTextGuard: Bool = true
    ) {
        self.title = title
        self.titleIsPlaceholder = titleIsPlaceholder
        self.root = root
        self.systemAudio = systemAudio
        self.captureMicrophone = captureMicrophone
        self.microphoneUID = microphoneUID
        self.saveAudio = saveAudio
        self.echoTextGuard = echoTextGuard
    }
}

public enum SessionEvent: Sendable {
    /// A new committed transcript line.
    case segment(TranscriptSegment)
    /// Live, unstable text for a channel (nil clears it).
    case partial(Channel, text: String?, start: Double)
    /// Input level (RMS, 0…1) for the meters.
    case level(Channel, Float)
    case warning(String)
}

/// How far the live transcript ran behind real time.
public struct LatencyStats: Sendable, Codable {
    public var count = 0
    public var mean = 0.0
    public var p50 = 0.0
    public var p95 = 0.0
    public var max = 0.0

    init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        count = sorted.count
        mean = sorted.reduce(0, +) / Double(sorted.count)
        p50 = sorted[sorted.count / 2]
        p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        max = sorted[sorted.count - 1]
    }
}

public struct SessionMetrics: Sendable, Codable {
    /// Delay from a word being spoken to it first appearing on screen (as live text).
    public var wordLatency: [String: LatencyStats] = [:]
    /// Delay from the end of an utterance to its committed line.
    public var commitLatency: [String: LatencyStats] = [:]
    /// ASR speed: seconds of audio decoded per second of compute.
    public var asrRealTimeFactor: [String: Double] = [:]
    public var echoLinesDropped = 0
}

public struct CallResult: Sendable {
    public var folder: CallFolder
    public let title: String
    public let titleIsPlaceholder: Bool
    public let startedAt: Date
    public let duration: Double
    public let segments: [TranscriptSegment]
    public let remoteSpeakers: Int
    public let metrics: SessionMetrics
}

/// One recorded call: capture → align → (echo-cancel) → VAD → ASR → transcript on disk.
public actor CallSession {
    private let config: SessionConfig
    private let models: SpeechModels
    private let onEvent: @Sendable (SessionEvent) -> Void

    private var microphone: CaptureSource?
    private var system: CaptureSource?
    private var tasks: [Task<Void, Never>] = []
    private var continuations: [() -> Void] = []
    private var transcribers: [Channel: ChannelTranscriber] = [:]
    private var tracker: SpeakerTracker?
    private var writer: StereoAudioWriter?

    private var folder: CallFolder?
    private var startedAt = Date()
    private var origin = 0.0
    private var running = false

    private var segments: [TranscriptSegment] = []
    private var remoteSpeakers = 0
    private var lastSave = 0.0
    private var saveScheduled = false

    // Echo guard state.
    private var themWords: [WordStamp] = []
    private var themPartialWords: [WordStamp] = []
    private var themPartialEnd = 0.0
    private var themSpeaking = false
    private var pendingMe: [(segment: TranscriptSegment, words: [WordStamp], heldSince: Double)] = []
    private var echoDropped = 0

    // Latency bookkeeping.
    private var seenUntil: [Channel: Double] = [:]
    private var wordLatencies: [Channel: [Double]] = [:]
    private var commitLatencies: [Channel: [Double]] = [:]

    public init(
        config: SessionConfig,
        models: SpeechModels,
        microphone: CaptureSource? = nil,
        system: CaptureSource? = nil,
        onEvent: @escaping @Sendable (SessionEvent) -> Void
    ) {
        self.config = config
        self.models = models
        self.onEvent = onEvent
        self.microphone = microphone
        self.system = system
    }

    public var folderURL: URL? { folder?.url }

    // MARK: - Start

    public func start() async throws {
        guard !running else { return }
        startedAt = Date()
        folder = try CallFolder.create(root: config.root, date: startedAt, title: config.title)

        // Default live sources unless the caller injected its own (tests feed files).
        if microphone == nil && config.captureMicrophone {
            microphone = DeviceInputSource(uid: config.microphoneUID, label: "microphone")
        }
        if system == nil {
            switch config.systemAudio {
            case .tap: system = SystemTapSource()
            case .device(let uid): system = DeviceInputSource(uid: uid, label: "system-device")
            case .none: system = nil
            }
        }

        if system != nil { transcribers[.them] = try await makeTranscriber(.them) }
        if microphone != nil { transcribers[.me] = try await makeTranscriber(.me) }
        tracker = system != nil ? SpeakerTracker(models: models) : nil
        let echoCanceller: EchoCanceller? =
            (system != nil && microphone != nil) ? await EchoCanceller(models: models) : nil
        if config.saveAudio, let folder {
            writer = StereoAudioWriter(
                url: folder.url.appendingPathComponent("audio.m4a"), hasMe: microphone != nil, hasThem: system != nil)
        }

        typealias Raw = (samples: [Float], host: Double)
        let onEvent = self.onEvent
        let writer = self.writer

        // 1. Open the devices. Audio queues up in the raw streams until the routers start.
        //    The microphone goes first: opening the system tap can block on the macOS
        //    "record system audio" prompt the first time, and nothing must be lost meanwhile.
        var feeds: [(channel: Channel, stream: AsyncStream<Raw>)] = []
        var failures: [String] = []
        func open(_ channel: Channel, _ source: CaptureSource) -> Bool {
            let (stream, continuation) = AsyncStream<Raw>.makeStream(bufferingPolicy: .unbounded)
            do {
                try source.start { samples, host in continuation.yield((samples, host)) }
            } catch {
                failures.append("\(channel == .me ? "Microphone" : "System audio"): \(error.localizedDescription)")
                return false
            }
            continuations.append { continuation.finish() }
            feeds.append((channel, stream))
            return true
        }
        if let source = microphone, !open(.me, source) { microphone = nil }
        if let source = system, !open(.them, source) { system = nil }
        for failure in failures { onEvent(.warning(failure)) }
        guard !feeds.isEmpty else { throw AudioError.deviceNotFound(failures.joined(separator: " · ")) }

        // 2. The call starts now: sample 0 of both channels is this instant.
        origin = HostClock.now
        running = true
        save(force: true)
        let origin = self.origin
        let echo = (system != nil && microphone != nil) ? echoCanceller : nil

        // 3. Per channel: raw stream → router (align, meter, fan out) → ASR stream → transcriber.
        for (channel, rawStream) in feeds {
            let (asrStream, asrContinuation) = AsyncStream<Raw>.makeStream(bufferingPolicy: .unbounded)
            let (diarStream, diarContinuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
            let tracker = channel == .them ? self.tracker : nil
            let transcriber = transcribers[channel]

            tasks.append(
                Task.detached(priority: .userInitiated) {
                    var aligner = TimelineAligner(origin: origin)
                    var lastLevel = 0.0
                    for await raw in rawStream {
                        if raw.host - lastLevel > 0.08 {
                            lastLevel = raw.host
                            onEvent(.level(channel, Self.rms(raw.samples)))
                        }
                        let aligned = aligner.align(raw.samples, hostSeconds: raw.host)
                        guard !aligned.isEmpty else { continue }
                        writer?.append(aligned, channel: channel)
                        switch channel {
                        case .them:
                            await echo?.pushReference(aligned)
                            if tracker != nil { diarContinuation.yield(aligned) }
                            asrContinuation.yield((aligned, raw.host))
                        case .me:
                            if let echo {
                                let behind = HostClock.now - raw.host
                                let cleaned = await echo.process(mic: aligned, bypass: behind > 2)
                                if !cleaned.isEmpty { asrContinuation.yield((cleaned, raw.host)) }
                            } else {
                                asrContinuation.yield((aligned, raw.host))
                            }
                        }
                    }
                    if channel == .me, let echo {
                        let tail = await echo.flush()
                        if !tail.isEmpty { asrContinuation.yield((tail, HostClock.now)) }
                    }
                    asrContinuation.finish()
                    diarContinuation.finish()
                })

            tasks.append(
                Task.detached(priority: .userInitiated) {
                    for await raw in asrStream {
                        await transcriber?.process(raw.samples, arrival: raw.host)
                    }
                    await transcriber?.finish()
                })

            tasks.append(
                Task.detached(priority: .utility) {
                    for await samples in diarStream { await tracker?.process(samples) }
                })
        }

        // Releases held "Me" lines even if the far end goes quiet.
        housekeeping = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self?.releasePendingMe(force: false)
                }
            }
    }

    private func makeTranscriber(_ channel: Channel) async throws -> ChannelTranscriber {
        let (events, continuation) = AsyncStream<ChannelEvent>.makeStream(bufferingPolicy: .unbounded)
        let transcriber = try await ChannelTranscriber(channel: channel, models: models) { event in
            continuation.yield(event)
        }
        eventContinuations.append { continuation.finish() }
        eventTasks.append(
            Task { [weak self] in
                for await event in events { await self?.handle(event, channel: channel) }
            })
        return transcriber
    }

    private var eventContinuations: [() -> Void] = []
    private var eventTasks: [Task<Void, Never>] = []
    private var housekeeping: Task<Void, Never>?
    /// Seconds of committed speech per diarized remote speaker.
    private var speakerTime: [Int: Double] = [:]

    // MARK: - Stop

    public func stop() async -> CallResult? {
        guard running, var folder else { return nil }
        running = false
        microphone?.stop()
        system?.stop()
        let duration = HostClock.now - origin

        // Drain: raw streams → routers → transcribers (final decode) → event handlers.
        continuations.forEach { $0() }
        housekeeping?.cancel()
        for task in tasks { await task.value }
        eventContinuations.forEach { $0() }
        for task in eventTasks { await task.value }
        releasePendingMe(force: true)
        writer?.finish()

        var metrics = SessionMetrics()
        for channel in Channel.allCases {
            if let values = wordLatencies[channel] { metrics.wordLatency[channel.rawValue] = LatencyStats(values) }
            if let values = commitLatencies[channel] { metrics.commitLatency[channel.rawValue] = LatencyStats(values) }
            if let transcriber = transcribers[channel] {
                let compute = await transcriber.decodeSeconds
                let audio = await transcriber.decodedAudioSeconds
                if compute > 0 { metrics.asrRealTimeFactor[channel.rawValue] = audio / compute }
            }
        }
        metrics.echoLinesDropped = echoDropped

        self.folder = folder
        save(force: true, finalDuration: duration)
        folder = self.folder ?? folder
        return CallResult(
            folder: folder, title: config.title, titleIsPlaceholder: config.titleIsPlaceholder, startedAt: startedAt,
            duration: duration, segments: segments.sorted { $0.start < $1.start }, remoteSpeakers: remoteSpeakers,
            metrics: metrics)
    }

    // MARK: - Transcript events

    private func handle(_ event: ChannelEvent, channel: Channel) async {
        let now = HostClock.now - origin
        switch event {
        case .partial(let text, let start, let end, let words):
            recordWordLatency(words, channel: channel, now: now)
            if channel == .them {
                themSpeaking = true
                themPartialWords = words
                themPartialEnd = end
                releasePendingMe(force: false)
            } else if config.echoTextGuard, isEcho(words) {
                onEvent(.partial(channel, text: nil, start: start))
                return
            }
            onEvent(.partial(channel, text: text, start: start))

        case .final(let text, let start, let end, let words, let openEnded):
            recordWordLatency(words, channel: channel, now: now)
            commitLatencies[channel, default: []].append(max(0, now - end))
            var segment = TranscriptSegment(channel: channel, text: text, start: start, end: end)
            if channel == .them {
                segment.speaker = await tracker?.speaker(from: start, to: end)
                if let speaker = segment.speaker {
                    // A voice counts as a separate participant once it has spoken for a few seconds,
                    // so one mislabelled fragment does not turn "Them" into "Them 1 / Them 2".
                    speakerTime[speaker, default: 0] += end - start
                    remoteSpeakers = speakerTime.values.filter { $0 >= 3 }.count
                }
                themWords.append(contentsOf: words)
                themWords.removeAll { $0.end < end - 120 }
                themPartialWords = []
                themPartialEnd = end
                themSpeaking = openEnded
                if !openEnded { onEvent(.partial(channel, text: nil, start: start)) }
                commit(segment)
                releasePendingMe(force: false)
            } else {
                if !openEnded { onEvent(.partial(channel, text: nil, start: start)) }
                if config.echoTextGuard && system != nil {
                    pendingMe.append((segment, words, now))
                    releasePendingMe(force: false)
                } else {
                    commit(segment)
                }
            }

        case .cleared:
            if channel == .them {
                themSpeaking = false
                themPartialWords = []
                releasePendingMe(force: false)
            }
            onEvent(.partial(channel, text: nil, start: 0))
        }
    }

    private func commit(_ segment: TranscriptSegment) {
        segments.append(segment)
        onEvent(.segment(segment))
        save(force: false)
    }

    /// A "Me" line is echo when its words are (almost) all words the far end said at the same time.
    private func isEcho(_ words: [WordStamp]) -> Bool {
        guard let first = words.first, let last = words.last else { return false }
        let window = (first.start - 1.0)...(last.end + 0.75)
        var far: [String: Int] = [:]
        for word in themWords + themPartialWords where word.end >= window.lowerBound && word.start <= window.upperBound {
            far[Self.normalize(word.word), default: 0] += 1
        }
        guard !far.isEmpty else { return false }
        var matched = 0
        var counted = 0
        for word in words {
            let key = Self.normalize(word.word)
            guard !key.isEmpty else { continue }
            counted += 1
            if let available = far[key], available > 0 {
                far[key] = available - 1
                matched += 1
            }
        }
        guard counted > 0 else { return false }
        return counted <= 3 ? matched == counted : Double(matched) / Double(counted) >= 0.6
    }

    /// Held "Me" lines are judged once the far-end transcript has caught up with them.
    private func releasePendingMe(force: Bool) {
        guard !pendingMe.isEmpty else { return }
        let now = HostClock.now - origin
        var keep: [(segment: TranscriptSegment, words: [WordStamp], heldSince: Double)] = []
        for item in pendingMe {
            if isEcho(item.words) {
                echoDropped += 1
                continue
            }
            let farEndCaughtUp = !themSpeaking || themPartialEnd >= item.segment.end
            if force || farEndCaughtUp || now - item.heldSince > 2.0 {
                commit(item.segment)
            } else {
                keep.append(item)
            }
        }
        pendingMe = keep
    }

    private func recordWordLatency(_ words: [WordStamp], channel: Channel, now: Double) {
        let seen = seenUntil[channel] ?? 0
        var newest = seen
        for word in words where word.end > seen + 0.05 {
            wordLatencies[channel, default: []].append(max(0, now - word.end))
            newest = max(newest, word.end)
        }
        seenUntil[channel] = newest
    }

    // MARK: - Saving

    /// Rewrites transcript.md (atomically). Called after every committed line, at most every 2 s.
    private func save(force: Bool, finalDuration: Double? = nil) {
        guard let folder else { return }
        let now = HostClock.now
        if !force && now - lastSave < 2 {
            if !saveScheduled {
                saveScheduled = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.scheduledSave()
                }
            }
            return
        }
        lastSave = now
        let ordered = segments.sorted { $0.start < $1.start }
        let markdown = TranscriptFormat.markdown(
            title: config.title, startedAt: startedAt, duration: finalDuration ?? (now - origin), segments: ordered,
            remoteSpeakers: remoteSpeakers, inProgress: finalDuration == nil)
        try? markdown.write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
    }

    private func scheduledSave() {
        saveScheduled = false
        if running { save(force: true) }
    }

    // MARK: - Helpers

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Optional raw audio

/// Writes audio.m4a: left = Me, right = Them, both on the call timeline (AAC, 16 kHz).
final class StereoAudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var queues: [Channel: [Float]] = [.me: [], .them: []]
    private let hasMe: Bool
    private let hasThem: Bool

    init?(url: URL, hasMe: Bool, hasThem: Bool) {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(Audio.sampleRate), channels: 2, interleaved: false)
        else { return nil }
        self.format = format
        self.hasMe = hasMe
        self.hasThem = hasThem
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Audio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 48_000,
        ]
        guard
            let file = try? AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return nil }
        self.file = file
    }

    func append(_ samples: [Float], channel: Channel) {
        lock.withLock {
            queues[channel, default: []].append(contentsOf: samples)
            flush(final: false)
        }
    }

    func finish() {
        lock.withLock {
            flush(final: true)
            file = nil  // closes the file
        }
    }

    private func flush(final: Bool) {
        let me = queues[.me] ?? []
        let them = queues[.them] ?? []
        var count: Int
        if final || !hasMe || !hasThem {
            count = max(me.count, them.count)
        } else {
            count = min(me.count, them.count)
            // If one side has stalled for over two seconds, stop waiting for it.
            if max(me.count, them.count) - count > Audio.sampleRate * 2 { count = max(me.count, them.count) - Audio.sampleRate }
        }
        guard count > 0, let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for (index, queue) in [me, them].enumerated() {
            let destination = buffer.floatChannelData![index]
            for frame in 0..<count { destination[frame] = frame < queue.count ? queue[frame] : 0 }
        }
        try? file.write(from: buffer)
        queues[.me] = Array(me.dropFirst(count))
        queues[.them] = Array(them.dropFirst(count))
    }
}

// MARK: - Summary

public enum CallSummary {
    /// Writes summary.md for a finished call and renames untitled calls after the summary's title.
    public static func write(
        for result: inout CallResult, model: String, progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SummaryResult {
        let lines = TranscriptFormat.plainText(result.segments, remoteSpeakers: result.remoteSpeakers)
        var summary = try await Summarizer(model: model).summarize(title: result.title, lines: lines, progress: progress)

        if result.titleIsPlaceholder, let title = summary.suggestedTitle, !title.isEmpty {
            summary = SummaryResult(
                markdown: summary.markdown.replacingOccurrences(
                    of: "# \(result.title) — Summary", with: "# \(title) — Summary"),
                suggestedTitle: title, model: summary.model, seconds: summary.seconds, chunks: summary.chunks)
            // Re-title the transcript and the folder to match.
            let transcript = TranscriptFormat.markdown(
                title: title, startedAt: result.startedAt, duration: result.duration, segments: result.segments,
                remoteSpeakers: result.remoteSpeakers, inProgress: false)
            try? transcript.write(to: result.folder.transcriptURL, atomically: true, encoding: .utf8)
            result.folder.rename(date: result.startedAt, title: title)
        }
        try summary.markdown.write(to: result.folder.summaryURL, atomically: true, encoding: .utf8)
        return summary
    }

    /// Re-summarizes a saved call from its transcript.md (used by "Regenerate Summary" and the CLI).
    public static func regenerate(
        folder: URL, model: String, progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SummaryResult {
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        var title = folder.lastPathComponent
        var lines: [String] = []
        for line in transcript.components(separatedBy: "\n") {
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2))
            } else if line.hasPrefix("**["), let close = line.range(of: ":** ") {
                // "**[00:12] Them 2:** text" → "[00:12] Them 2: text"
                let head = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
                lines.append("\(head): \(line[close.upperBound...])")
            }
        }
        let summary = try await Summarizer(model: model).summarize(title: title, lines: lines, progress: progress)
        try summary.markdown.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        return summary
    }

    public static func writeFailure(folder: URL, title: String, error: Error) {
        let text = """
            # \(title) — Summary

            _The summary could not be generated: \(error.localizedDescription)_

            The transcript is saved in [transcript.md](transcript.md). Open Earshot and choose **Regenerate Summary**, \
            or run `earshot-cli summarize "\(folder.path)"`.

            """
        try? text.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }
}
