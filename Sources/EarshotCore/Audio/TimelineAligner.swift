import Foundation

/// Places one capture stream on the call's shared sample timeline.
///
/// Microphone and system audio come from different devices with different clocks. Each buffer
/// carries the host time of its first sample, so sample index N of *every* channel means
/// "N / 16000 seconds after the call started". Small jitter is ignored; real gaps, overlaps and
/// accumulated clock drift are corrected by inserting silence or dropping samples.
struct TimelineAligner {
    private let origin: Double
    private let tolerance: Int
    private(set) var position = 0

    /// - Parameter origin: host-clock seconds of the start of the call.
    init(origin: Double, toleranceSeconds: Double = 0.04) {
        self.origin = origin
        self.tolerance = Int(toleranceSeconds * Double(Audio.sampleRate))
    }

    mutating func align(_ samples: [Float], hostSeconds: Double) -> [Float] {
        let expected = Int(((hostSeconds - origin) * Double(Audio.sampleRate)).rounded())
        let delta = expected - position
        var output: [Float]
        if position == 0 || abs(delta) > tolerance {
            if delta > 0 {
                // We are missing audio (late start, dropped buffers, slow clock): pad with silence.
                // Cap the pad so a bogus timestamp cannot allocate minutes of zeros.
                output = [Float](repeating: 0, count: min(delta, Audio.sampleRate * 30)) + samples
            } else if -delta < samples.count {
                // Overlap (fast clock or audio from before the call started): drop the excess.
                output = Array(samples[(-delta)...])
            } else {
                output = []
            }
        } else {
            output = samples
        }
        position += output.count
        return output
    }
}
