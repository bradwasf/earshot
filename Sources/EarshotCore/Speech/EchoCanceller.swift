import FluidAudio
import Foundation

/// Removes the far end (system audio) from the microphone when you are on speakers, so the other
/// side's words are not transcribed a second time under "Me".
///
/// Wraps LocalVQE (a streaming DeepVQE-style neural AEC). It needs the microphone and the
/// reference to cover the same time span, which `TimelineAligner` guarantees.
actor EchoCanceller {
    private let stream: LocalVqeStream
    private var mic: [Float] = []
    private var reference: [Float] = []
    /// Reference samples we substituted with silence because the system stream was late.
    private var referenceDebt = 0
    private var bypassed = false
    private static let maxWait = Audio.sampleRate / 2

    init?(models: SpeechModels) async {
        guard let manager = models.echoCanceller, let stream = try? await manager.makeStream() else { return nil }
        self.stream = stream
    }

    func pushReference(_ samples: [Float]) {
        var samples = samples
        if referenceDebt > 0 {
            let drop = min(referenceDebt, samples.count)
            samples.removeFirst(drop)
            referenceDebt -= drop
        }
        reference.append(contentsOf: samples)
        // Never let an idle microphone make the reference queue grow without bound.
        let excess = reference.count - mic.count - Audio.sampleRate * 5
        if excess > 0 && mic.isEmpty { reference.removeFirst(excess) }
    }

    /// Returns cleaned microphone audio (possibly empty while waiting for the reference).
    /// - Parameter bypass: pass the microphone through untouched. Used when the pipeline has
    ///   fallen behind real time (CPU starvation), so echo cancellation never adds to a backlog.
    func process(mic samples: [Float], bypass: Bool = false) async -> [Float] {
        mic.append(contentsOf: samples)
        if mic.count - reference.count > Self.maxWait {
            // The system stream has stalled; assume silence rather than hold the microphone back.
            let pad = mic.count - reference.count
            reference.append(contentsOf: [Float](repeating: 0, count: pad))
            referenceDebt += pad
        }
        let count = min(mic.count, reference.count)
        guard count > 0 else { return [] }
        let micSlice = Array(mic[..<count])
        let referenceSlice = Array(reference[..<count])
        mic.removeFirst(count)
        reference.removeFirst(count)
        if bypass {
            if !bypassed {
                bypassed = true
                try? await stream.reset()
            }
            return micSlice
        }
        bypassed = false
        do {
            return try await stream.enhance(mic: micSlice, reference: referenceSlice)
        } catch {
            return micSlice
        }
    }

    func flush() async -> [Float] {
        (try? await stream.flush()) ?? []
    }
}
