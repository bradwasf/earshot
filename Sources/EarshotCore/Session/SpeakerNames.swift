import Foundation

/// Names the user gave to a saved call's speakers ("Them 1" → "Priya", "Me" → "Sam").
///
/// transcript.md keeps one header line that maps Earshot's own labels to the names,
///
///     - **Speaker names:** Me = Sam, Them 1 = Priya
///
/// and every turn line carries the name instead of the label (`**[00:12] Priya:** …`), so the
/// files read naturally wherever they are sent. The header is what lets Earshot read each turn's
/// channel and remote-speaker number back, rename again, or revert to the label. summary.md has
/// no header: the old name is replaced by the new one as a whole word.
public enum SpeakerNames {
    public static let headerPrefix = "- **Speaker names:** "
    /// Longest name accepted (characters).
    public static let maxLength = 40

    public enum Failure: Error, LocalizedError, Equatable {
        /// The name is another speaker's label ("Them 2", "Me").
        case reservedLabel(String)
        /// Another speaker in this call already has that name.
        case duplicate(name: String, label: String)
        case unknownSpeaker(String)
        case noTranscript

        public var errorDescription: String? {
            switch self {
            case .reservedLabel(let name): return "“\(name)” is a speaker label Earshot uses. Choose another name."
            case .duplicate(let name, let label): return "\(label) is already called “\(name)”."
            case .unknownSpeaker(let label): return "This call has no speaker called “\(label)”."
            case .noTranscript: return "The call's transcript.md could not be read."
            }
        }
    }

    /// True for the labels Earshot itself writes: "Me", "Them", "Them 1", "Them 2"…
    public static func isLabel(_ text: String) -> Bool {
        if text == "Me" || text == "Them" { return true }
        guard text.hasPrefix("Them ") else { return false }
        let number = text.dropFirst(5)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// Channel and remote-speaker number for one of Earshot's labels.
    public static func identity(of label: String) -> (channel: Channel, speaker: Int?) {
        if label == "Me" { return (.me, nil) }
        return (.them, Int(label.split(separator: " ").last ?? ""))
    }

    /// Makes typed text safe for a turn line: one line, no Markdown emphasis, trimmed and capped.
    public static func clean(_ name: String) -> String {
        let flattened = name.replacingOccurrences(of: "*", with: "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flattened.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Header

    /// Reads `- **Speaker names:** Them 1 = Priya, Them 2 = Raj` (label → name). Names may hold
    /// commas and "=" signs; only ", <label> = " starts the next entry.
    public static func parseHeader(_ line: String) -> [String: String] {
        guard line.hasPrefix(headerPrefix) else { return [:] }
        let body = String(line.dropFirst(headerPrefix.count))
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|, )(Me|Them(?: \d+)?) = "#) else { return [:] }
        let source = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: source.length))
        var names: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let label = source.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            guard end >= start else { continue }
            let name = source.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != label { names[label] = name }
        }
        return names
    }

    /// The header line for `names` (label → name), Me first, then remote speakers by number;
    /// nil when nobody is named.
    public static func header(_ names: [String: String]) -> String? {
        let entries = names.filter { isLabel($0.key) && !$0.value.isEmpty && $0.value != $0.key }
        guard !entries.isEmpty else { return nil }
        return headerPrefix + entries.keys.sorted(by: labelOrder).map { "\($0) = \(entries[$0]!)" }.joined(separator: ", ")
    }

    /// "Me" < "Them" < "Them 1" < "Them 2" < "Them 10".
    public static func labelOrder(_ a: String, _ b: String) -> Bool {
        func rank(_ label: String) -> (Int, Int) {
            if label == "Me" { return (0, 0) }
            if label == "Them" { return (1, 0) }
            return (2, Int(label.split(separator: " ").last ?? "") ?? Int.max)
        }
        return rank(a) < rank(b)
    }

    // MARK: Validation

    /// The name to store for `label` after the user typed `typed`, given the call's current names
    /// (label → name). Returns nil to clear the name (empty text, or the label itself).
    public static func validate(_ typed: String, for label: String, names: [String: String]) throws -> String? {
        let name = clean(typed)
        if name.isEmpty || name == label { return nil }
        let folded = fold(name)
        if isLabel(name) || ["me", "them"].contains(folded) || isLabel(capitalizedLabel(name)) {
            throw Failure.reservedLabel(name)
        }
        if let other = names.first(where: { $0.key != label && fold($0.value) == folded }) {
            throw Failure.duplicate(name: other.value, label: other.key)
        }
        return name
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// "them 2" → "Them 2", so labels typed in any case count as labels.
    private static func capitalizedLabel(_ text: String) -> String {
        let lower = text.lowercased()
        if lower == "me" { return "Me" }
        if lower.hasPrefix("them") { return "Them" + text.dropFirst(4) }
        return text
    }

    // MARK: Rewriting the files

    /// Splits `**[00:12] Them 2:** text` into its parts; nil for any other line.
    static func turnLine(_ line: String) -> (time: String, label: String, rest: Substring)? {
        guard line.hasPrefix("**["), let timeEnd = line.range(of: "] "), let labelEnd = line.range(of: ":** "),
            timeEnd.upperBound <= labelEnd.lowerBound
        else { return nil }
        let time = String(line[line.index(line.startIndex, offsetBy: 3)..<timeEnd.lowerBound])
        return (time, String(line[timeEnd.upperBound..<labelEnd.lowerBound]), line[labelEnd.upperBound...])
    }

    /// transcript.md with `label` renamed to `name` (nil reverts to the label): the header line is
    /// rewritten and every turn by that speaker carries the new name. Other lines are untouched.
    /// Also returns the name the speaker had before and has now (the label when unnamed), and the
    /// other speakers' names.
    public static func renameInTranscript(_ text: String, label: String, to name: String?) throws -> (
        text: String, previous: String, current: String, others: [String]
    ) {
        var lines = text.components(separatedBy: "\n")
        var names: [String: String] = [:]
        var headerIndex: Int?
        for (index, line) in lines.enumerated() where line.hasPrefix(headerPrefix) {
            names = parseHeader(line)
            headerIndex = index
            break
        }
        let byName = Dictionary(names.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let speaks = lines.contains { line in
            guard let turn = turnLine(line) else { return false }
            return (byName[turn.label] ?? turn.label) == label
        }
        guard isLabel(label), speaks || names[label] != nil else { throw Failure.unknownSpeaker(label) }

        let previous = names[label] ?? label
        let stored = try validate(name ?? "", for: label, names: names)
        names[label] = stored
        let display = stored ?? label

        for index in lines.indices {
            guard let turn = turnLine(lines[index]), (byName[turn.label] ?? turn.label) == label else { continue }
            lines[index] = "**[\(turn.time)] \(display):** \(turn.rest)"
        }

        let header = Self.header(names)
        if let headerIndex {
            if let header { lines[headerIndex] = header } else { lines.remove(at: headerIndex) }
        } else if let header {
            // After "- **Speakers:**" (or the last header bullet before the first rule).
            let rule = lines.firstIndex(of: "---") ?? lines.count
            let anchor =
                lines[..<rule].firstIndex { $0.hasPrefix("- **Speakers:** ") }
                ?? lines[..<rule].lastIndex { $0.hasPrefix("- **") }
                ?? lines[..<rule].firstIndex { $0.hasPrefix("# ") }
            lines.insert(header, at: anchor.map { $0 + 1 } ?? 0)
        }
        let others = names.filter { $0.key != label }.map(\.value)
        return (lines.joined(separator: "\n"), previous, display, others)
    }

    /// summary.md with every whole-word `old` replaced by `new`. The heading (the call's title) and
    /// the footnote after the closing rule are left alone. "Them" never matches inside "Them 2",
    /// and "Them 1" never inside "Them 12"; names in `keeping` that contain `old` ("Priya S" when
    /// renaming "Priya") are left as they are.
    public static func renameInSummary(_ text: String, from old: String, to new: String, keeping: [String] = [])
        -> String
    {
        guard !old.isEmpty, old != new else { return text }
        let protected = keeping.filter { $0 != old && $0.contains(old) }.sorted { $0.count > $1.count }
        var pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: old) + #"(?![\p{L}\p{N}_])"#
        // A bare label must not be the start of a numbered one.
        if isLabel(old) { pattern += #"(?! \d)"# }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let template = NSRegularExpression.escapedTemplate(for: new)
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix("# ") { continue }
            var masked = line
            for (number, name) in protected.enumerated() {
                masked = masked.replacingOccurrences(of: name, with: "\u{E000}\(number)\u{E001}")
            }
            var replaced = regex.stringByReplacingMatches(
                in: masked, range: NSRange(location: 0, length: (masked as NSString).length), withTemplate: template)
            for (number, name) in protected.enumerated() {
                replaced = replaced.replacingOccurrences(of: "\u{E000}\(number)\u{E001}", with: name)
            }
            lines[index] = replaced
        }
        return lines.joined(separator: "\n")
    }

    /// Renames a speaker in a saved call: transcript.md (header and turns) and summary.md.
    /// `name` nil or empty reverts to Earshot's label. Returns the name now shown for the speaker.
    @discardableResult
    public static func rename(folder: URL, label: String, to name: String?) throws -> String {
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw Failure.noTranscript
        }
        let renamed = try renameInTranscript(transcript, label: label, to: name)
        guard renamed.text != transcript else { return renamed.current }
        try renamed.text.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let summaryURL = folder.appendingPathComponent("summary.md")
        if renamed.previous != renamed.current, let summary = try? String(contentsOf: summaryURL, encoding: .utf8) {
            let updated = renameInSummary(
                summary, from: renamed.previous, to: renamed.current, keeping: renamed.others)
            if updated != summary { try updated.write(to: summaryURL, atomically: true, encoding: .utf8) }
        }
        return renamed.current
    }
}
