import Foundation

/// One entry of a summary's "Action items" section.
public struct ActionItem: Sendable, Equatable, Hashable {
    /// Zero-based line number in summary.md (a hint: the file may have changed since).
    public let line: Int
    public var done: Bool
    /// The item as written, without bullet and checkbox ("**Me** — Fix the bug by Friday.").
    public let text: String
    /// "Me", "Them 2", "Priya"… when the item starts with a bold owner.
    public let owner: String?
    /// The task without the owner, first letter capitalised ("Fix the bug by Friday.").
    public let task: String

    public init(line: Int, done: Bool, text: String) {
        self.line = line
        self.done = done
        self.text = text
        (owner, task) = ActionItems.split(text)
    }

    /// True when the owner is "Me", the person who recorded the call.
    public var isMine: Bool { isMine(names: [:]) }

    /// True when the owner is the person who recorded the call: "Me", or the name "Me" was given
    /// in this call (`names` is the transcript's speaker-name header, label → name), since naming
    /// a speaker rewrites `**Me**` in summary.md to `**Sam**`.
    public func isMine(names: [String: String]) -> Bool {
        guard let owner else { return false }
        return SpeakerNames.label(of: owner, names: names) == "Me"
    }
}

/// Reads and edits the action items of summary.md, which are a Markdown task list
/// (`- [ ] **Owner** — task`, `- [x] …` once done). Older summaries wrote plain bullets
/// (`- **Owner** — task`); those read as open items and gain a checkbox when first ticked.
public enum ActionItems {
    public enum Failure: Error, LocalizedError, Equatable {
        case notFound

        public var errorDescription: String? {
            "The action item is no longer in summary.md (it may have been edited or regenerated)."
        }
    }

    // MARK: Reading

    public static func isActionHeading(_ name: String) -> Bool { name.lowercased().contains("action") }

    /// A bullet line split into its checkbox state (nil when it has no checkbox) and text.
    /// Returns nil for lines that are not bullets.
    public static func bullet(_ line: String) -> (done: Bool?, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        return checkbox(String(trimmed.dropFirst(2)))
    }

    /// Bullet text with an optional leading checkbox ("[x] Ship it") split into state and text.
    public static func checkbox(_ text: String) -> (done: Bool?, text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        for (box, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(box) {
            let rest = text.dropFirst(box.count)
            if rest.isEmpty || rest.first == " " { return (done, rest.trimmingCharacters(in: .whitespaces)) }
        }
        return (nil, text)
    }

    static func isPlaceholder(_ text: String) -> Bool { text.lowercased().hasPrefix("none recorded") }

    /// "**Me** — fix the bug" → ("Me", "Fix the bug"). Items without a bold owner keep all their text.
    public static func split(_ text: String) -> (owner: String?, task: String) {
        guard text.hasPrefix("**"), let close = text.dropFirst(2).range(of: "**") else { return (nil, text) }
        let owner = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var task = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        for dash in ["—", "–", "-", ":"] where task.hasPrefix(dash) {
            task = String(task.dropFirst(dash.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !owner.isEmpty else { return (nil, text) }
        return (owner, task.prefix(1).uppercased() + task.dropFirst())
    }

    /// Every action item in summary.md, in order. "None recorded." placeholders are skipped.
    public static func parse(_ summary: String) -> [ActionItem] {
        var items: [ActionItem] = []
        forEachActionBullet(in: summary.components(separatedBy: "\n")) { index, done, text in
            items.append(ActionItem(line: index, done: done ?? false, text: text))
        }
        return items
    }

    /// Calls `body` for every bullet under an "Action items" heading, before the footnote rule.
    private static func forEachActionBullet(in lines: [String], _ body: (Int, Bool?, String) -> Void) {
        var inActions = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { return }
            if line.hasPrefix("#") {
                inActions = line.hasPrefix("## ") && isActionHeading(String(line.dropFirst(3)))
            } else if inActions, let bullet = bullet(raw), !isPlaceholder(bullet.text) {
                body(index, bullet.done, bullet.text)
            }
        }
    }

    // MARK: Ticking

    /// Ticks or unticks one item, changing only its line. Returns nil when the item is gone.
    public static func setting(_ done: Bool, for item: ActionItem, in summary: String) -> String? {
        var lines = summary.components(separatedBy: "\n")
        var candidates: [Int] = []
        forEachActionBullet(in: lines) { index, _, text in
            if text == item.text { candidates.append(index) }
        }
        // The line the item was read from, or else the nearest line holding the same text.
        guard let index = candidates.contains(item.line)
            ? item.line : candidates.min(by: { abs($0 - item.line) < abs($1 - item.line) })
        else { return nil }
        lines[index] = rewrite(lines[index], done: done)
        return lines.joined(separator: "\n")
    }

    /// Re-reads summary.md, ticks or unticks the item and writes the file back. Returns the new text.
    @discardableResult
    public static func setDone(_ done: Bool, for item: ActionItem, folder: URL) throws -> String {
        let url = folder.appendingPathComponent("summary.md")
        let summary = try String(contentsOf: url, encoding: .utf8)
        guard let updated = setting(done, for: item, in: summary) else { throw Failure.notFound }
        if updated != summary { try updated.write(to: url, atomically: true, encoding: .utf8) }
        return updated
    }

    /// "  - **Me** — x" → "  - [x] **Me** — x", keeping indentation and the bullet character.
    static func rewrite(_ line: String, done: Bool) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        let marker = rest.prefix(2)
        return indent + marker + (done ? "[x] " : "[ ] ") + checkbox(String(rest.dropFirst(2))).text
    }

    // MARK: Writing summaries

    /// Gives every action item a checkbox ("- [ ] …") and strips one from placeholders.
    public static func normalized(_ summary: String) -> String {
        var lines = summary.components(separatedBy: "\n")
        var inActions = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            if line.hasPrefix("#") {
                inActions = line.hasPrefix("## ") && isActionHeading(String(line.dropFirst(3)))
            } else if inActions, let bullet = bullet(raw) {
                if isPlaceholder(bullet.text) {
                    if bullet.done != nil { lines[index] = "- " + bullet.text }
                } else if bullet.done == nil {
                    lines[index] = rewrite(raw, done: false)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the user's ticks when a summary is rewritten: items of `new` whose task matches a
    /// ticked item of `old` are ticked, and ticked items the new summary left out are appended
    /// to its action items, so finished work is never lost.
    public static func carryingOver(from old: String, into new: String) -> String {
        let ticked = parse(old).filter(\.done)
        guard !ticked.isEmpty else { return new }
        var remaining = ticked
        var lines = new.components(separatedBy: "\n")
        for item in parse(new) where !item.done {
            if let match = remaining.firstIndex(where: { key($0) == key(item) }) {
                lines[item.line] = rewrite(lines[item.line], done: true)
                remaining.remove(at: match)
            }
        }
        // Ticked items that the new summary already has as done are not missing either.
        for item in parse(new) where item.done {
            if let match = remaining.firstIndex(where: { key($0) == key(item) }) { remaining.remove(at: match) }
        }
        guard !remaining.isEmpty else { return lines.joined(separator: "\n") }

        let extra = remaining.map { "- [x] \($0.text)" }
        if let heading = sectionRange(lines) {
            // Replace a "None recorded." placeholder, otherwise add after the last bullet.
            let placeholder = heading.dropFirst().first { index in
                bullet(lines[index]).map { isPlaceholder($0.text) } ?? false
            }
            if let placeholder {
                lines.replaceSubrange(placeholder...placeholder, with: extra)
            } else {
                let lastBullet = heading.last { bullet(lines[$0]) != nil } ?? heading.lowerBound
                lines.insert(contentsOf: extra, at: lastBullet + 1)
            }
        } else {
            let section = ["## Action items"] + extra + [""]
            let rule = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces) == "---" }
            if let rule {
                lines.insert(contentsOf: section, at: rule)
            } else {
                if lines.last?.isEmpty == false { lines.append("") }
                lines += section
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Lines from the "## Action items" heading to the end of that section.
    private static func sectionRange(_ lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { line in
            line.hasPrefix("## ") && isActionHeading(String(line.dropFirst(3)))
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#") || trimmed == "---"
        } ?? lines.count
        return start..<end
    }

    /// Items match on their task, ignoring case, punctuation and formatting, so a renamed owner
    /// or a reworded dash still counts as the same item.
    static func key(_ item: ActionItem) -> String {
        let task = item.task.lowercased().filter { $0.isLetter || $0.isNumber }
        return task.isEmpty ? item.text.lowercased().filter { $0.isLetter || $0.isNumber } : task
    }
}
