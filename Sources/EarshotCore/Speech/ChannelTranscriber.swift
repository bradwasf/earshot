import FluidAudio
import Foundation

/// A word with times in seconds since the start of the call.
public struct WordStamp: Sendable, Codable, Equatable {
    public let word: String
    public let start: Double
    public let end: Double
}

public struct TranscriberConfig: Sendable {
    /// How often the in-progress utterance is re-decoded to refresh the live (grey) text.
    public var partialInterval: Double = 0.6
    /// Silence needed to close an utterance.
    public var minSilence: Double = 0.5
    /// Once an utterance is this long, finished sentences are committed while speech continues.
    public var commitAfter: Double = 5.0
    /// Hard cap; Parakeet's window is 15 s, so we always cut before that.
    public var maxUtterance: Double = 13.0
    /// Don't commit a sentence until this much audio follows it (the tail of a partial is unstable).
    public var commitGuard: Double = 1.2

    public init() {}
}

public enum ChannelEvent: Sendable {
    /// Unstable text for the utterance in progress; replaced by the next partial or final.
    case partial(text: String, start: Double, end: Double, words: [WordStamp])
    /// Committed text. `openEnded` is true when the speaker is still talking (sentence commit).
    case final(text: String, start: Double, end: Double, words: [WordStamp], openEnded: Bool)
    /// The utterance ended without producing text (noise, cough…); clear any partial.
    case cleared
}

/// One side of the call: continuous 16 kHz audio in, VAD-gated transcript events out.
///
/// Design: Silero VAD finds utterances. While someone is talking, the growing utterance is
/// re-decoded by Parakeet every `partialInterval` seconds — the model runs >100× real time, so a
/// full re-decode is cheaper and more accurate than a small cache-aware streaming model. Finished
/// sentences are committed as soon as they are safely in the past; the rest stays "partial".
public actor ChannelTranscriber {
    private let channel: Channel
    private let asr: AsrManager
    private let vad: VadManager
    private let config: TranscriberConfig
    private let emit: @Sendable (ChannelEvent) -> Void
    private let decoderLayers: Int
    private let segmentation: VadSegmentationConfig

    private static let rate = Audio.sampleRate
    private static let vadChunk = VadManager.chunkSize

    // Audio buffer: `buffer[0]` is absolute sample `bufferStart` of the stream.
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var total = 0

    private var vadState: VadStreamState
    private var vadCursor = 0

    private var speaking = false
    private var utteranceStart = 0
    private var lastPartialEnd = 0
    private var hasPartial = false

    /// Total seconds of ASR compute and audio decoded, for the real-time-factor report.
    public private(set) var decodeSeconds = 0.0
    public private(set) var decodedAudioSeconds = 0.0
    public private(set) var decodeCount = 0

    public init(
        channel: Channel,
        models: SpeechModels,
        config: TranscriberConfig = TranscriberConfig(),
        emit: @escaping @Sendable (ChannelEvent) -> Void
    ) async throws {
        self.channel = channel
        self.asr = try await models.makeAsrManager()
        self.vad = models.vad
        self.config = config
        self.emit = emit
        self.decoderLayers = await asr.decoderLayerCount
        self.vadState = await models.vad.makeStreamState()
        self.segmentation = VadSegmentationConfig(
            minSpeechDuration: 0.15,
            minSilenceDuration: config.minSilence,
            speechPadding: 0.1
        )
    }

    /// Feed the next slice of the stream. `arrival` is the host-clock time the audio was captured.
    public func process(_ samples: [Float], arrival: Double) async {
        buffer.append(contentsOf: samples)
        total += samples.count

        while total - vadCursor >= Self.vadChunk {
            let offset = vadCursor - bufferStart
            let chunk = Array(buffer[offset..<offset + Self.vadChunk])
            guard
                let result = try? await vad.processStreamingChunk(chunk, state: vadState, config: segmentation)
            else {
                vadCursor += Self.vadChunk
                continue
            }
            vadState = result.state
            vadCursor += Self.vadChunk

            guard let event = result.event else { continue }
            switch event.kind {
            case .speechStart:
                guard !speaking else { break }
                speaking = true
                utteranceStart = min(max(event.sampleIndex, bufferStart), vadCursor)
                lastPartialEnd = utteranceStart
                hasPartial = false
            case .speechEnd:
                guard speaking else { break }
                let end = min(max(event.sampleIndex, utteranceStart), total)
                await closeUtterance(at: end)
                speaking = false
            }
        }

        if speaking {
            // Refresh the live text, unless we are behind real time and need to catch up.
            let dueSamples = Int(config.partialInterval * Double(Self.rate))
            let behind = HostClock.now - arrival
            if total - lastPartialEnd >= dueSamples && behind < 1.5 {
                await refreshPartial()
            }
        } else {
            // Keep one second of pre-roll so a speech start can reach back before the VAD fired.
            let keepFrom = max(bufferStart, vadCursor - Self.rate)
            if keepFrom > bufferStart {
                buffer.removeFirst(keepFrom - bufferStart)
                bufferStart = keepFrom
            }
        }
    }

    /// End of call: transcribe whatever is still in flight.
    public func finish() async {
        if speaking {
            await closeUtterance(at: total)
            speaking = false
        }
    }

    // MARK: - Decoding

    private func refreshPartial() async {
        let end = total
        lastPartialEnd = end
        guard let (text, words) = await decode(from: utteranceStart, to: end) else { return }

        let duration = Double(end - utteranceStart) / Double(Self.rate)
        if duration >= config.commitAfter, let cut = commitPoint(words: words, duration: duration) {
            // Commit the finished sentence(s); keep decoding the remainder as a new utterance.
            let head = Array(words[...cut.index])
            let tail = Array(words[(cut.index + 1)...])
            let base = seconds(utteranceStart)
            emit(
                .final(
                    text: head.map(\.word).joined(separator: " "),
                    start: base,
                    end: base + cut.time,
                    words: stamps(head, base: base),
                    openEnded: true
                ))
            utteranceStart += Int(cut.time * Double(Self.rate))
            trimBuffer(to: utteranceStart)
            let newBase = seconds(utteranceStart)
            let shifted = tail.map {
                WordStamp(word: $0.word, start: base + $0.startTime, end: base + $0.endTime)
            }
            if shifted.isEmpty {
                hasPartial = false
                emit(.cleared)
            } else {
                hasPartial = true
                emit(
                    .partial(
                        text: shifted.map(\.word).joined(separator: " "), start: newBase, end: seconds(end),
                        words: shifted))
            }
            return
        }

        if duration >= config.maxUtterance && words.isEmpty {
            // Thirteen seconds of "speech" with no words is noise or music: skip ahead.
            utteranceStart = max(utteranceStart, end - Self.rate)
            trimBuffer(to: utteranceStart)
            hasPartial = false
            emit(.cleared)
            return
        }

        if duration >= config.maxUtterance + 1 {
            // No usable cut point was found: commit everything rather than outgrow the model window.
            let base = seconds(utteranceStart)
            if !text.isEmpty {
                emit(
                    .final(
                        text: text, start: base, end: seconds(end), words: stamps(words, base: base),
                        openEnded: true))
            } else {
                emit(.cleared)
            }
            utteranceStart = end
            trimBuffer(to: utteranceStart)
            hasPartial = false
            return
        }

        guard !text.isEmpty else { return }
        hasPartial = true
        let base = seconds(utteranceStart)
        emit(.partial(text: text, start: base, end: seconds(end), words: stamps(words, base: base)))
    }

    private func closeUtterance(at end: Int) async {
        defer {
            utteranceStart = end
            hasPartial = false
        }
        let length = end - utteranceStart
        guard length >= Self.rate / 5, let (text, words) = await decode(from: utteranceStart, to: end),
            !text.isEmpty
        else {
            emit(.cleared)
            return
        }
        let base = seconds(utteranceStart)
        emit(.final(text: text, start: base, end: seconds(end), words: stamps(words, base: base), openEnded: false))
    }

    private func decode(from start: Int, to end: Int) async -> (String, [WordTiming])? {
        let lower = max(start, bufferStart) - bufferStart
        let upper = min(end, total) - bufferStart
        guard upper > lower else { return nil }
        var audio = Array(buffer[lower..<upper])
        let seconds = Double(audio.count) / Double(Self.rate)
        // Parakeet needs at least one second of audio; pad short utterances with silence.
        let minimum = Self.rate + Self.rate / 10
        if audio.count < minimum { audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count)) }

        let began = HostClock.now
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        guard let result = try? await asr.transcribe(audio, decoderState: &state) else { return nil }
        decodeSeconds += HostClock.now - began
        decodedAudioSeconds += seconds
        decodeCount += 1

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = result.tokenTimings.map(buildWordTimings(from:)) ?? []
        return (text, words)
    }

    /// Where to cut a long utterance: after the last finished sentence that is safely in the past,
    /// or — past the hard cap — at the longest pause.
    private func commitPoint(words: [WordTiming], duration: Double) -> (index: Int, time: Double)? {
        guard words.count >= 2 else { return nil }
        let limit = duration - config.commitGuard

        func cut(after index: Int) -> (index: Int, time: Double) {
            (index, (words[index].endTime + words[index + 1].startTime) / 2)
        }

        for index in stride(from: words.count - 2, through: 0, by: -1) {
            guard words[index + 1].startTime <= limit else { continue }
            if let last = words[index].word.last, ".?!".contains(last), words[index].endTime >= 1.5 {
                return cut(after: index)
            }
        }

        guard duration >= config.maxUtterance else { return nil }
        var best: (index: Int, gap: Double)?
        for index in 0..<(words.count - 1) {
            guard words[index].endTime >= duration * 0.35, words[index + 1].startTime <= limit else { continue }
            let gap = words[index + 1].startTime - words[index].endTime
            if best == nil || gap > best!.gap { best = (index, gap) }
        }
        if let best { return cut(after: best.index) }
        // No usable pause: cut at the last word boundary before the guard.
        if let index = (0..<(words.count - 1)).last(where: { words[$0 + 1].startTime <= limit }) {
            return cut(after: index)
        }
        return nil
    }

    // MARK: - Helpers

    private func trimBuffer(to absolute: Int) {
        let keepFrom = min(absolute, vadCursor)
        guard keepFrom > bufferStart else { return }
        buffer.removeFirst(keepFrom - bufferStart)
        bufferStart = keepFrom
    }

    private func seconds(_ sample: Int) -> Double { Double(sample) / Double(Self.rate) }

    private func stamps(_ words: [WordTiming], base: Double) -> [WordStamp] {
        words.map { WordStamp(word: $0.word, start: base + $0.startTime, end: base + $0.endTime) }
    }
}
