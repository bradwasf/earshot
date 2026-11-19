import Foundation

extension SummaryExport {
    /// The "Action items" section, if the summary has any.
    public var actionItems: Section? { sections.first { $0.isActionItems && !$0.items.isEmpty } }

    /// Just the checklist, as a Markdown task list under the call's title.
    public var actionItemsMarkdown: String? {
        guard let section = actionItems else { return nil }
        return (["**\(title)** — \(section.name)", ""] + Self.markdownItems(section)).joined(separator: "\n") + "\n"
    }

    /// Just the checklist, as HTML for the clipboard: ☐ open, ☑ and struck through when done.
    public var actionItemsHTML: String? {
        guard let section = actionItems else { return nil }
        let items = section.entries.map { entry in
            entry.done ? "<li>☑ <s>\(Self.html(entry.text))</s></li>" : "<li>☐ \(Self.html(entry.text))</li>"
        }
        return "<p><b>\(Self.html(title))</b> — \(Self.escapeHTML(section.name))</p>\n"
            + "<ul style=\"list-style: none\">" + items.joined() + "</ul>"
    }
}

/// Whole-call exports that combine the summary with the transcript.
public enum CallExport {
    public typealias Line = (time: String, label: String, text: String)

    /// A transcript entry: a speaker's turn, or one of the user's notes, marks or pauses
    /// (already written out, as Markdown and as plain text).
    public enum Entry: Equatable {
        case turn(time: String, label: String, text: String)
        case aside(markdown: String, plain: String)

        var plain: String {
            switch self {
            case .turn(let time, let label, let text): return "[\(time)] \(label): \(text)"
            case .aside(_, let plain): return plain
            }
        }

        var markdown: String {
            switch self {
            case .turn(let time, let label, let text): return "**[\(time)] \(label):** \(text)"
            case .aside(let markdown, _): return markdown
            }
        }
    }

    /// The transcript as plain text: title, detail, then `[00:12] Them 2: …` per line.
    public static func transcriptText(title: String, detail: String?, lines: [Line]) -> String {
        transcriptText(title: title, detail: detail, entries: lines.map { .turn(time: $0.time, label: $0.label, text: $0.text) })
    }

    public static func transcriptText(title: String, detail: String?, entries: [Entry]) -> String {
        var head = [title]
        if let detail, !detail.isEmpty { head.append(detail) }
        return (head + [""] + entries.map(\.plain)).joined(separator: "\n") + "\n"
    }

    /// One self-contained Markdown file: the summary (without links to files on this Mac),
    /// then the full transcript. Calls without a usable summary get the transcript alone.
    public static func markdown(summary: SummaryExport?, title: String, detail: String?, lines: [Line]) -> String {
        markdown(
            summary: summary, title: title, detail: detail,
            entries: lines.map { .turn(time: $0.time, label: $0.label, text: $0.text) })
    }

    public static func markdown(summary: SummaryExport?, title: String, detail: String?, entries: [Entry]) -> String {
        var blocks: [String]
        if let summary {
            blocks = [summary.markdown.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            blocks = ["# \(title)"]
            if let detail, !detail.isEmpty { blocks.append("_\(detail)_") }
        }
        if !entries.isEmpty {
            blocks.append("## Transcript")
            blocks.append(entries.map(\.markdown).joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// A file name for the call: its title without characters Finder or other systems reject.
    public static func fileName(_ title: String, extension ext: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
        let base = String((cleaned.isEmpty ? "Call" : cleaned).prefix(120))
        return "\(base).\(ext)"
    }
}
