import Foundation

extension TranscriptFormat {
    /// Seconds for a transcript timestamp ("02:03" or "01:02:03"); nil if it is not one.
    public static func seconds(_ timestamp: String) -> Double? {
        let parts = timestamp.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return Double(total)
    }
}

/// One speaker's share of the talking in a saved call.
public struct TalkShare: Sendable, Equatable, Identifiable {
    public var id: String { label }
    /// Earshot's label ("Me", "Them 2"), which decides the colour.
    public let label: String
    /// What the transcript calls the speaker (a name, if one was given).
    public let name: String
    public let channel: Channel
    public let speaker: Int?
    public let seconds: Double
    /// 0…1 of all talk in the call.
    public let fraction: Double
}

/// Estimates who talked how much from the saved turns, which carry only start times: a turn
/// runs until the next one starts, but no longer than its words could take to say (so long
/// pauses do not count as talk); the last turn ends with the call.
public enum TalkTime {
    /// Slow speech is about 1.5 words a second; a turn gets that, plus a little slack.
    static func cap(words: Int) -> Double { 2 + Double(words) / 1.5 }

    public static func shares(_ turns: [SavedTurn], duration: Double?) -> [TalkShare] {
        let timed = turns.compactMap { turn in TranscriptFormat.seconds(turn.time).map { (turn, $0) } }
            .sorted { $0.1 < $1.1 }
        var seconds: [String: Double] = [:]
        var first: [String: SavedTurn] = [:]
        for (index, (turn, start)) in timed.enumerated() {
            let key = turn.originalLabel.isEmpty ? turn.label : turn.originalLabel
            let words = turn.text.split(whereSeparator: \.isWhitespace).count
            var end = start + cap(words: words)
            if index + 1 < timed.count {
                end = min(end, timed[index + 1].1)
            } else if let duration, duration > start {
                end = min(end, duration)
            }
            seconds[key, default: 0] += max(0, end - start)
            if first[key] == nil { first[key] = turn }
        }
        let total = seconds.values.reduce(0, +)
        guard total > 0 else { return [] }
        return seconds.keys.sorted(by: SpeakerNames.labelOrder).map { key in
            let turn = first[key]!
            return TalkShare(
                label: key, name: turn.label, channel: turn.channel, speaker: turn.speaker, seconds: seconds[key]!,
                fraction: seconds[key]! / total)
        }
    }

    /// Whole percentages that add up to 100 (largest remainder), in the order given.
    public static func percentages(_ shares: [TalkShare]) -> [Int] {
        guard !shares.isEmpty else { return [] }
        let exact = shares.map { $0.fraction * 100 }
        var rounded = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { exact[$0] - Double(rounded[$0]) > exact[$1] - Double(rounded[$1]) }
        for index in order.prefix(max(0, 100 - rounded.reduce(0, +))) { rounded[index] += 1 }
        return rounded
    }
}

/// Find-in-call matching: case- and diacritic-insensitive.
public enum TextSearch {
    /// A match in block `block`, as character offsets into that block's text.
    public struct Match: Sendable, Equatable {
        public let block: Int
        public let range: Range<Int>
    }

    /// Every occurrence of `query` in `blocks`, in reading order. When the whole phrase occurs
    /// nowhere, each of its words is matched instead (the home screen's search matches calls that
    /// contain all the words anywhere, so a call opened from there still shows why it matched).
    public static func matches(_ query: String, in blocks: [String]) -> [Match] {
        let phrase = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !phrase.isEmpty else { return [] }
        let found = occurrences(of: [phrase], in: blocks)
        let words = Array(Set(phrase.split(separator: " ").map(String.init)))
        if !found.isEmpty || words.count < 2 { return found }
        return occurrences(of: words, in: blocks)
    }

    private static func occurrences(of needles: [String], in blocks: [String]) -> [Match] {
        var result: [Match] = []
        for (index, text) in blocks.enumerated() {
            var ranges: [Range<Int>] = []
            for needle in needles {
                var searchFrom = text.startIndex
                while searchFrom < text.endIndex,
                    let found = text.range(
                        of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        range: searchFrom..<text.endIndex)
                {
                    let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                    let upper = text.distance(from: text.startIndex, to: found.upperBound)
                    if upper > lower { ranges.append(lower..<upper) }
                    searchFrom = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
                }
            }
            // Words may overlap ("an" inside "plan"); keep the earliest, longest, non-overlapping ones.
            var last = -1
            for range in ranges.sorted(by: { ($0.lowerBound, -$0.count) < ($1.lowerBound, -$1.count) })
            where range.lowerBound >= last {
                result.append(Match(block: index, range: range))
                last = range.upperBound
            }
        }
        return result
    }
}
