import Foundation

/// One committed line of the transcript.
public struct TranscriptSegment: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let channel: Channel
    /// Remote speaker number from diarization (1-based); nil for "Me" or when unknown.
    public var speaker: Int?
    public var text: String
    /// Seconds since the call started.
    public let start: Double
    public let end: Double

    public init(id: UUID = UUID(), channel: Channel, speaker: Int? = nil, text: String, start: Double, end: Double) {
        self.id = id
        self.channel = channel
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One speaker's uninterrupted stretch of talk (several segments merged).
public struct TranscriptTurn: Identifiable, Sendable, Equatable {
    public let id: String
    public let channel: Channel
    public let speaker: Int?
    public let label: String
    public let start: Double
    public var end: Double
    public var text: String
}

public enum TranscriptFormat {
    /// `01:02:03` (or `02:03` under an hour).
    public static func timestamp(_ seconds: Double, alwaysHours: Bool = false) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 || alwaysHours { return String(format: "%02d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// "Me", "Them", or "Them 2" when more than one remote speaker was heard.
    public static func speakerLabel(_ segment: TranscriptSegment, remoteSpeakers: Int) -> String {
        switch segment.channel {
        case .me: return "Me"
        case .them:
            if remoteSpeakers > 1, let speaker = segment.speaker { return "Them \(speaker)" }
            return "Them"
        }
    }

    /// Consecutive segments from the same speaker are merged into one paragraph so the transcript
    /// reads as turns rather than sentence fragments.
    public static func turns(_ segments: [TranscriptSegment], remoteSpeakers: Int) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let label = speakerLabel(segment, remoteSpeakers: remoteSpeakers)
            if var last = turns.last, last.label == label, segment.start - last.end < 2.5,
                segment.start - last.start < 45
            {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(
                    TranscriptTurn(
                        id: segment.id.uuidString, channel: segment.channel, speaker: segment.speaker, label: label,
                        start: segment.start, end: segment.end, text: segment.text))
            }
        }
        return turns
    }

    public static func markdown(
        title: String, startedAt: Date, duration: Double, segments: [TranscriptSegment], remoteSpeakers: Int,
        inProgress: Bool
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
        let hours = duration >= 3600
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("- **Date:** \(dateFormatter.string(from: startedAt))")
        lines.append(
            "- **Duration:** \(timestamp(duration, alwaysHours: hours))\(inProgress ? " (recording in progress)" : "")"
        )
        let labels = remoteSpeakers > 1 ? "Me, " + (1...remoteSpeakers).map { "Them \($0)" }.joined(separator: ", ") : "Me, Them"
        lines.append("- **Speakers:** \(labels)")
        lines.append("- Transcribed on-device by Earshot. \"Me\" is the microphone; \"Them\" is system audio.")
        lines.append("")
        lines.append("---")
        lines.append("")
        let allTurns = turns(segments, remoteSpeakers: remoteSpeakers)
        if allTurns.isEmpty { lines.append("_No speech was detected._") }
        for turn in allTurns {
            lines.append("**[\(timestamp(turn.start, alwaysHours: hours))] \(turn.label):** \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain "[mm:ss] Speaker: text" lines for the summarizer prompt.
    public static func plainText(_ segments: [TranscriptSegment], remoteSpeakers: Int) -> [String] {
        turns(segments, remoteSpeakers: remoteSpeakers).map { "[\(timestamp($0.start))] \($0.label): \($0.text)" }
    }
}

/// Where a call lives on disk: ~/Earshot/Calls/<date>-<title>/
public struct CallFolder: Sendable {
    public private(set) var url: URL

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Earshot/Calls", isDirectory: true)
    }

    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { url.appendingPathComponent("summary.md") }

    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(60))
    }

    static func name(date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let slug = slug(title)
        return "\(formatter.string(from: date))-\(slug.isEmpty ? "call" : slug)"
    }

    /// Creates `<root>/<yyyy-MM-dd>-<title>` (adding the time, then a counter, if that already exists).
    public static func create(root: URL, date: Date, title: String) throws -> CallFolder {
        let url = uniqueURL(root: root, date: date, title: title, excluding: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CallFolder(url: url)
    }

    /// Renames the folder after the call gets its final title (e.g. from the summary).
    public mutating func rename(date: Date, title: String) {
        let root = url.deletingLastPathComponent()
        let target = Self.uniqueURL(root: root, date: date, title: title, excluding: url)
        guard target != url else { return }
        if (try? FileManager.default.moveItem(at: url, to: target)) != nil { url = target }
    }

    private static func uniqueURL(root: URL, date: Date, title: String, excluding current: URL?) -> URL {
        let base = name(date: date, title: title)
        let time = DateFormatter()
        time.dateFormat = "HHmm"
        var candidates = [base, "\(base)-\(time.string(from: date))"]
        candidates += (2...50).map { "\(base)-\(time.string(from: date))-\($0)" }
        for candidate in candidates {
            let url = root.appendingPathComponent(candidate, isDirectory: true)
            if url == current || !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return root.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
}
