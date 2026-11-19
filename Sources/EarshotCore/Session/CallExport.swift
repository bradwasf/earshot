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

    /// The transcript as plain text: title, detail, then `[00:12] Them 2: …` per line.
    public static func transcriptText(title: String, detail: String?, lines: [Line]) -> String {
        var head = [title]
        if let detail, !detail.isEmpty { head.append(detail) }
        return (head + [""] + lines.map { "[\($0.time)] \($0.label): \($0.text)" }).joined(separator: "\n") + "\n"
    }

    /// One self-contained Markdown file: the summary (without links to files on this Mac),
    /// then the full transcript. Calls without a usable summary get the transcript alone.
    public static func markdown(summary: SummaryExport?, title: String, detail: String?, lines: [Line]) -> String {
        var blocks: [String]
        if let summary {
            blocks = [summary.markdown.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            blocks = ["# \(title)"]
            if let detail, !detail.isEmpty { blocks.append("_\(detail)_") }
        }
        if !lines.isEmpty {
            blocks.append("## Transcript")
            blocks.append(lines.map { "**[\($0.time)] \($0.label):** \($0.text)" }.joined(separator: "\n\n"))
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
