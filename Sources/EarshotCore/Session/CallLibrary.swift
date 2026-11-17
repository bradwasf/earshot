import Foundation

/// A call that was saved earlier, as listed on the home screen.
public struct SavedCall: Identifiable, Sendable, Equatable {
    public var id: URL { folder }
    public let folder: URL
    public let title: String
    public let date: Date
    /// "02:05" or "01:02:03", as written in transcript.md.
    public let duration: String?
    /// The TL;DR of summary.md, if a summary exists.
    public let overview: String?
}

/// One turn of a saved transcript.
public struct SavedTurn: Identifiable, Sendable, Equatable {
    public let id: Int
    public let time: String
    public let label: String
    public let channel: Channel
    public let speaker: Int?
    public let text: String
}

/// Reads calls back from ~/Earshot/Calls. The Markdown files are the only storage.
public enum CallLibrary {
    /// Saved calls, newest first.
    public static func list(root: URL) -> [SavedCall] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        guard
            let folders = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return folders.compactMap { folder -> SavedCall? in
            guard let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                let transcript = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
            else { return nil }
            let parsed = parseTranscript(transcript)
            return SavedCall(
                folder: folder,
                title: parsed.title ?? folder.lastPathComponent,
                date: values.creationDate ?? .distantPast,
                duration: parsed.duration,
                overview: summary(folder: folder).flatMap(overview(of:)))
        }
        .sorted { $0.date > $1.date }
    }

    public static func load(folder: URL) -> (title: String, duration: String?, turns: [SavedTurn])? {
        guard let transcript = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        else { return nil }
        let parsed = parseTranscript(transcript)
        return (parsed.title ?? folder.lastPathComponent, parsed.duration, parsed.turns)
    }

    public static func summary(folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
    }

    static func parseTranscript(_ text: String) -> (title: String?, duration: String?, turns: [SavedTurn]) {
        var title: String?
        var duration: String?
        var turns: [SavedTurn] = []
        for line in text.components(separatedBy: "\n") {
            if title == nil, line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- **Duration:** ") {
                duration = line.dropFirst("- **Duration:** ".count).split(separator: " ").first.map(String.init)
            } else if line.hasPrefix("**["), let timeEnd = line.range(of: "] "), let labelEnd = line.range(of: ":** ") {
                // **[00:12] Them 2:** text
                let time = String(line[line.index(line.startIndex, offsetBy: 3)..<timeEnd.lowerBound])
                guard timeEnd.upperBound <= labelEnd.lowerBound else { continue }
                let label = String(line[timeEnd.upperBound..<labelEnd.lowerBound])
                let isMe = label == "Me"
                let speaker = isMe ? nil : Int(label.split(separator: " ").last ?? "")
                turns.append(
                    SavedTurn(
                        id: turns.count, time: time, label: label, channel: isMe ? .me : .them, speaker: speaker,
                        text: String(line[labelEnd.upperBound...])))
            }
        }
        return (title, duration, turns)
    }

    /// The text under "## TL;DR" (nil for summaries that failed or have no such section).
    static func overview(of summary: String) -> String? {
        var collecting = false
        var lines: [String] = []
        for line in summary.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if collecting { break }
                collecting = line.lowercased().contains("tl;dr")
            } else if collecting, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        let text = lines.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
