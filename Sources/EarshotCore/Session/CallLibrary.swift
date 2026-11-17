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
    /// Lowercased title, summary and transcript, for searching.
    public let searchText: String

    /// True when every word of `query` appears somewhere in the call.
    public func matches(_ query: String) -> Bool {
        query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { searchText.contains($0) }
    }
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
            let title = parsed.title ?? folder.lastPathComponent
            let summary = summary(folder: folder)
            return SavedCall(
                folder: folder,
                title: title,
                date: values.creationDate ?? .distantPast,
                duration: parsed.duration,
                overview: summary.flatMap(overview(of:)),
                searchText: ([title, summary ?? ""] + parsed.turns.map(\.text)).joined(separator: "\n").lowercased())
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

    /// Gives a saved call a new title: rewrites the headings of transcript.md and summary.md and
    /// renames the folder to match. Returns the folder's new location.
    @discardableResult
    public static func rename(folder: URL, to newTitle: String) throws -> URL {
        let title = newTitle.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return folder }
        for (file, suffix) in [("transcript.md", ""), ("summary.md", " — Summary")] {
            let url = folder.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { continue }
            lines[index] = "# \(title)\(suffix)"
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        // Keep the folder's date prefix ("2026-11-17-") and replace the rest with the new title.
        let name = folder.lastPathComponent
        let prefix = name.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression).map { String(name[$0]) } ?? ""
        let slug = CallFolder.slug(title)
        let base = prefix + (slug.isEmpty ? "call" : slug)
        guard base != name else { return folder }
        let root = folder.deletingLastPathComponent()
        var target = root.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = root.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.moveItem(at: folder, to: target)
        return target
    }

    /// Moves a saved call to the Trash (it can be put back from there).
    public static func trash(folder: URL) throws {
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
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
