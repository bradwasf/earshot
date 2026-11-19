import Foundation

/// Something the person recording put on the call's timeline: a typed note, a bookmark
/// ("Marked"), or a stretch that was taken off the record with Pause.
public struct CallMarker: Identifiable, Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A note typed during the call.
        case note
        /// A moment marked as important, without text.
        case mark
        /// Capture was paused from `start` to `end`: nothing in between was transcribed or saved.
        case pause
    }

    public let id: UUID
    public let kind: Kind
    /// Seconds since the call started.
    public let start: Double
    /// End of a pause; nil for notes and marks, and for a pause that is still going on.
    public var end: Double?
    /// The note's text (empty for marks and pauses).
    public var text: String

    public init(id: UUID = UUID(), kind: Kind, start: Double, end: Double? = nil, text: String = "") {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
    }

    /// A typed note as one clean line: no line breaks, no surrounding space, at most 1,000 characters.
    public static func cleanNote(_ text: String) -> String {
        let single = text.components(separatedBy: .newlines).joined(separator: " ")
        let collapsed = single.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(1000))
    }
}

/// A transcript in reading order: speaker turns with the user's notes, marks and pauses between them.
public enum TranscriptEntry: Sendable, Equatable {
    case turn(TranscriptTurn)
    case marker(CallMarker)
}

/// Mutes the stretches of the call that are paused. Shared between the session (which pauses and
/// resumes) and the per-channel audio routers (which run off the actor and must not wait on it).
///
/// Audio is gated by its position on the call timeline, not by when it happens to be processed,
/// so a buffer captured just before the pause is kept and one captured just after is silenced even
/// if the pipeline is a little behind. Silenced audio keeps flowing as zeros: the timeline, the VAD,
/// the echo canceller and the raw recording all stay in step, and timestamps after a resume are
/// still on the call clock.
public final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [(start: Double, end: Double?)] = []

    public init() {}

    public var isPaused: Bool {
        lock.withLock { spans.last.map { $0.end == nil } ?? false }
    }

    /// Starts muting at `time` (call seconds). Returns false if already paused.
    @discardableResult
    public func pause(at time: Double) -> Bool {
        lock.withLock {
            if let last = spans.last, last.end == nil { return false }
            spans.append((max(0, time), nil))
            return true
        }
    }

    /// Stops muting at `time` (call seconds). Returns false if not paused.
    @discardableResult
    public func resume(at time: Double) -> Bool {
        lock.withLock {
            guard let last = spans.last, last.end == nil else { return false }
            spans[spans.count - 1].end = max(last.start, time)
            return true
        }
    }

    /// True when `time` (call seconds) falls inside a paused stretch, ending `margin` seconds early.
    public func contains(_ time: Double, margin: Double = 0) -> Bool {
        lock.withLock { spans.contains { time >= $0.start && time < ($0.end ?? .infinity) - margin } }
    }

    /// The end of the finished pause that `time` falls in, if any (call seconds).
    public func resumeTime(covering time: Double) -> Double? {
        lock.withLock { spans.first { time >= $0.start && time < ($0.end ?? -.infinity) }?.end }
    }

    /// Replaces the samples of `samples` that fall inside a paused stretch with silence.
    /// - Parameter firstSample: the call-timeline index of `samples[0]`.
    public func silence(_ samples: inout [Float], firstSample: Int, sampleRate: Int = Audio.sampleRate) {
        let spans = lock.withLock { self.spans }
        guard !spans.isEmpty, !samples.isEmpty else { return }
        let rate = Double(sampleRate)
        let lastSample = firstSample + samples.count
        for span in spans {
            let from = max(firstSample, Int((span.start * rate).rounded()))
            let to = min(lastSample, span.end.map { Int(($0 * rate).rounded()) } ?? Int.max)
            guard to > from else { continue }
            for index in (from - firstSample)..<(to - firstSample) { samples[index] = 0 }
        }
    }
}

// MARK: - Markdown and prompt lines

extension TranscriptFormat {
    /// The transcript in reading order. Turns are split wherever a marker falls, so a note sits
    /// where it was taken rather than after a long paragraph.
    public static func entries(
        _ segments: [TranscriptSegment], markers: [CallMarker], remoteSpeakers: Int
    ) -> [TranscriptEntry] {
        let ordered = markers.sorted { $0.start < $1.start }
        let allTurns = turns(segments, remoteSpeakers: remoteSpeakers, breaks: ordered.map(\.start))
        var result: [TranscriptEntry] = []
        var next = 0
        for turn in allTurns {
            while next < ordered.count, ordered[next].start < turn.start {
                result.append(.marker(ordered[next]))
                next += 1
            }
            result.append(.turn(turn))
        }
        result += ordered[next...].map { .marker($0) }
        return result
    }

    /// `12:03`, or `03:12 – 04:40` for a finished pause.
    public static func markerTime(_ marker: CallMarker, alwaysHours: Bool = false) -> String {
        let start = timestamp(marker.start, alwaysHours: alwaysHours)
        guard marker.kind == .pause, let end = marker.end else { return start }
        return "\(start) – \(timestamp(end, alwaysHours: alwaysHours))"
    }

    /// The transcript.md line for a marker. Written as a blockquote so it reads as an aside in any
    /// Markdown viewer, and so that it can never be mistaken for a speaker turn (`**[…] Me:** …`),
    /// including by older versions of Earshot, which simply skip it.
    public static func markdownLine(_ marker: CallMarker, alwaysHours: Bool = false) -> String {
        let time = markerTime(marker, alwaysHours: alwaysHours)
        switch marker.kind {
        case .note: return "> **[\(time)] Note:** \(CallMarker.cleanNote(marker.text))"
        case .mark: return "> **[\(time)] Marked**"
        case .pause:
            return marker.end == nil
                ? "> **[\(time)] Paused** — off the record (still paused)"
                : "> **[\(time)] Paused** — off the record, nothing was transcribed"
        }
    }

    /// Parses a line written by `markdownLine`; nil for anything else.
    public static func parseMarkerLine(_ line: String) -> CallMarker? {
        guard line.hasPrefix("> **["), let close = line.range(of: "] ") else { return nil }
        let time = line[line.index(line.startIndex, offsetBy: 5)..<close.lowerBound]
        let rest = line[close.upperBound...]
        let times = time.components(separatedBy: "–").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = seconds(fromTimestamp: times[0]) else { return nil }
        if rest.hasPrefix("Note:** ") {
            let text = CallMarker.cleanNote(String(rest.dropFirst("Note:** ".count)))
            return CallMarker(kind: text.isEmpty ? .mark : .note, start: start, text: text)
        }
        if rest.hasPrefix("Marked**") { return CallMarker(kind: .mark, start: start) }
        if rest.hasPrefix("Paused**") {
            let end = times.count > 1 ? seconds(fromTimestamp: times[1]) : nil
            return CallMarker(kind: .pause, start: start, end: end)
        }
        return nil
    }

    /// `02:03` or `01:02:03` → seconds.
    public static func seconds(fromTimestamp text: String) -> Double? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1! })
    }

    static let notePrefix = "NOTE typed by Me during the call:"
    static let markText = "MARK: Me flagged this moment as important."
    static let pauseText = "PAUSED: recording was off; nothing said in this span was captured."

    /// The summarizer's line for a marker, e.g. `[12:03] NOTE typed by Me during the call: …`.
    public static func plainLine(_ marker: CallMarker) -> String {
        let time = markerTime(marker).replacingOccurrences(of: " – ", with: "–")
        switch marker.kind {
        case .note: return "[\(time)] \(notePrefix) \(CallMarker.cleanNote(marker.text))"
        case .mark: return "[\(time)] \(markText)"
        case .pause: return "[\(time)] \(pauseText)"
        }
    }

    /// True for a summarizer line produced by `plainLine` (as opposed to something someone said).
    public static func isMarkerLine(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        return rest.hasPrefix(notePrefix) || rest.hasPrefix(markText) || rest.hasPrefix(pauseText)
    }
}
