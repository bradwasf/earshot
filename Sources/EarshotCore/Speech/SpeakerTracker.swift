import FluidAudio
import Foundation

/// Tells remote speakers apart on the "Them" channel with NVIDIA's streaming Sortformer
/// (up to four speakers, ~1 s latency, runs far faster than real time on Apple Silicon).
///
/// The diarizer sees the whole system-audio stream, so frame `i` of its output is always
/// `i × 80 ms` into the call. A transcript segment asks "who was talking between t0 and t1?".
public actor SpeakerTracker {
    private let diarizer: SortformerDiarizer
    private let speakerCount: Int
    private let frameSeconds: Double

    /// Finalized per-frame probabilities, `speakerCount` values per frame.
    private var frames: [Float] = []
    /// Tentative (look-ahead) frames that follow the finalized ones.
    private var tentative: [Float] = []
    /// Sortformer slot → order of first appearance (1-based), so labels read "Them 1", "Them 2"…
    private var order: [Int: Int] = [:]

    public init?(models: SpeechModels) {
        guard let sortformer = models.sortformer else { return nil }
        let config = SortformerConfig.default
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: sortformer)
        self.diarizer = diarizer
        self.speakerCount = config.numSpeakers
        self.frameSeconds = Double(config.frameDurationSeconds)
    }

    public func process(_ samples: [Float]) {
        guard let update = try? diarizer.process(samples: samples, sourceSampleRate: Double(Audio.sampleRate))
        else { return }
        frames.append(contentsOf: update.chunkResult.finalizedPredictions)
        tentative = update.chunkResult.tentativePredictions
    }

    /// The dominant speaker (1-based, in order of first appearance) between two call times,
    /// or nil when the diarizer saw no confident speech there.
    public func speaker(from start: Double, to end: Double) -> Int? {
        let all = frames + tentative
        let frameCount = all.count / speakerCount
        let first = max(0, Int(start / frameSeconds))
        let last = min(frameCount, Int((end / frameSeconds).rounded(.up)))
        guard last > first else { return nil }

        var activity = [Float](repeating: 0, count: speakerCount)
        for frame in first..<last {
            for speaker in 0..<speakerCount {
                let probability = all[frame * speakerCount + speaker]
                if probability > 0.5 { activity[speaker] += probability }
            }
        }
        guard let best = activity.indices.max(by: { activity[$0] < activity[$1] }) else { return nil }
        // Require the speaker to be active for at least a quarter of the segment (min. 3 frames).
        guard activity[best] >= max(3, Float(last - first) * 0.25) else { return nil }
        if order[best] == nil { order[best] = order.count + 1 }
        return order[best]
    }
}
