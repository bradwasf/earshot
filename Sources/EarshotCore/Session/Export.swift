import Foundation

/// Turns a saved summary.md into text for other apps: Slack's message markup, rich text for the
/// clipboard, and the JSON body of a Slack incoming-webhook post.
public struct SummaryExport: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public let name: String
        /// Bullet text, still in Markdown ("**Me** — fix the bug").
        public var items: [String]
        public var prose: [String]
    }

    public var title: String
    /// "Tue 17 Nov 2026 · 04:47 · 02:02"
    public var detail: String?
    public var overview: String
    public var sections: [Section]

    /// Reads summary.md. Sections that hold nothing ("None recorded.") are dropped, and so is the
    /// footnote, which links to a file on this Mac.
    public init?(summaryMarkdown: String, title: String? = nil, detail: String? = nil) {
        var heading: String?
        var overview = ""
        var sections: [Section] = []
        var inOverview = false
        scan: for raw in summaryMarkdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" { break scan }
            if line.hasPrefix("# ") {
                if heading == nil { heading = String(line.dropFirst(2)) }
            } else if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inOverview = name.lowercased().contains("tl;dr")
                if !inOverview { sections.append(Section(name: name, items: [], prose: [])) }
            } else if inOverview {
                overview += (overview.isEmpty ? "" : " ") + line
            } else if !sections.isEmpty {
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    var item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) { item = String(item.dropFirst(box.count)) }
                    if !item.lowercased().hasPrefix("none recorded") { sections[sections.count - 1].items.append(item) }
                } else {
                    sections[sections.count - 1].prose.append(line)
                }
            }
        }
        sections.removeAll { $0.items.isEmpty && $0.prose.isEmpty }
        if overview.isEmpty && sections.isEmpty { return nil }

        var resolved = title ?? heading ?? "Call"
        if title == nil, resolved.hasSuffix(" — Summary") { resolved = String(resolved.dropLast(" — Summary".count)) }
        self.title = resolved
        self.detail = detail
        self.overview = overview
        self.sections = sections
    }

    public static let credit = "Transcribed and summarized on-device by Earshot"

    // MARK: Slack markup

    /// The summary in Slack's message markup (`*bold*`, `•` bullets), for pasting or posting.
    public var slackText: String {
        var blocks: [String] = [Self.slack("**\(title)**") + (detail.map { "\n_\(Self.escapeSlack($0))_" } ?? "")]
        if !overview.isEmpty { blocks.append(Self.slack(overview)) }
        blocks += sections.map(slackSection)
        return blocks.joined(separator: "\n\n")
    }

    private func slackSection(_ section: Section) -> String {
        (["*\(Self.escapeSlack(section.name))*"] + section.prose.map(Self.slack) + section.items.map { "• " + Self.slack($0) })
            .joined(separator: "\n")
    }

    /// JSON body for a Slack incoming webhook: Block Kit for layout plus a plain `text` fallback
    /// (shown in notifications). `blocks: false` gives the text-only form.
    public func slackPayload(blocks useBlocks: Bool = true) -> Data {
        var payload: [String: Any] = ["text": String(slackText.prefix(39_000))]
        if useBlocks {
            var blocks: [[String: Any]] = [
                ["type": "header", "text": ["type": "plain_text", "text": String(title.prefix(150)), "emoji": true]]
            ]
            if let detail, !detail.isEmpty { blocks.append(Self.context(Self.escapeSlack(detail))) }
            if !overview.isEmpty { blocks += Self.sectionBlocks(Self.slack(overview)) }
            for section in sections { blocks += Self.sectionBlocks(slackSection(section)) }
            blocks.append(Self.context(Self.credit))
            // Slack accepts at most 50 blocks per message.
            payload["blocks"] = Array(blocks.prefix(50))
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    private static func context(_ text: String) -> [String: Any] {
        ["type": "context", "elements": [["type": "mrkdwn", "text": String(text.prefix(2900))]]]
    }

    /// A section block holds at most 3,000 characters; longer text is split on line boundaries.
    private static func sectionBlocks(_ text: String) -> [[String: Any]] {
        split(text, limit: 2900).map { ["type": "section", "text": ["type": "mrkdwn", "text": $0]] }
    }

    static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            var line = Substring(line)
            while line.count > limit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(String(line.prefix(limit)))
                line = line.dropFirst(limit)
            }
            if current.count + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: Rich text and Markdown

    public enum HTMLStyle: Sendable {
        /// Bold lines instead of headings: Slack's composer keeps bold and lists but not headings.
        case slack
        /// Real headings, for documents, notes and mail.
        case document
    }

    /// The summary as an HTML fragment for the clipboard.
    public func html(_ style: HTMLStyle) -> String {
        var parts: [String] = []
        switch style {
        case .slack:
            parts.append("<p><b>\(Self.html(title))</b>" + (detail.map { "<br><i>\(Self.escapeHTML($0))</i>" } ?? "") + "</p>")
        case .document:
            parts.append("<h1>\(Self.html(title))</h1>")
            if let detail { parts.append("<p><i>\(Self.escapeHTML(detail))</i></p>") }
        }
        if !overview.isEmpty { parts.append("<p>\(Self.html(overview))</p>") }
        for section in sections {
            let name = Self.escapeHTML(section.name)
            parts.append(style == .slack ? "<p><b>\(name)</b></p>" : "<h2>\(name)</h2>")
            parts += section.prose.map { "<p>\(Self.html($0))</p>" }
            if !section.items.isEmpty {
                parts.append("<ul>" + section.items.map { "<li>\(Self.html($0))</li>" }.joined() + "</ul>")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// The summary as portable Markdown (no local file links).
    public var markdown: String {
        var blocks: [String] = ["# \(title)" + (detail.map { "\n\n_\($0)_" } ?? "")]
        if !overview.isEmpty { blocks.append(overview) }
        for section in sections {
            blocks.append((["## \(section.name)"] + section.prose + section.items.map { "- \($0)" }).joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: Inline Markdown

    private enum Target { case slack, html }

    static func slack(_ markdown: String) -> String { inline(markdown, .slack) }
    static func html(_ markdown: String) -> String { inline(markdown, .html) }

    static func escapeSlack(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeHTML(_ text: String) -> String {
        escapeSlack(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Converts the inline Markdown the summarizer writes (bold, italics, code, links).
    private static func inline(_ markdown: String, _ target: Target) -> String {
        var text = target == .slack ? escapeSlack(markdown) : escapeHTML(markdown)
        // Links: web links survive, links to local files keep only their text.
        text = replace(text, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { groups in
            let (label, url) = (groups[1], groups[2])
            guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else { return label }
            return target == .slack ? "<\(url)|\(label)>" : "<a href=\"\(url)\">\(label)</a>"
        }
        // Bold first (held in placeholders so its asterisks are not read as italics).
        text = replace(text, #"\*\*(.+?)\*\*"#) { "\u{1}\($0[1])\u{2}" }
        text = replace(text, #"(?<![\*\w])\*(?!\s)([^\*]+?)(?<!\s)\*(?![\*\w])"#) {
            target == .slack ? "_\($0[1])_" : "<i>\($0[1])</i>"
        }
        if target == .html {
            text = replace(text, #"(?<![\w])_(?!\s)([^_]+?)(?<!\s)_(?![\w])"#) { "<i>\($0[1])</i>" }
            text = replace(text, #"`([^`]+)`"#) { "<code>\($0[1])</code>" }
        }
        return text.replacingOccurrences(of: "\u{1}", with: target == .slack ? "*" : "<b>")
            .replacingOccurrences(of: "\u{2}", with: target == .slack ? "*" : "</b>")
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}

/// Posts to a Slack incoming webhook. This is the only code path in Earshot that sends anything
/// off the Mac, and it runs only when the user chooses "Send to Slack".
public enum SlackWebhook {
    public enum Failure: Error, LocalizedError, Equatable {
        case invalidURL
        case rejected(status: Int, body: String)
        case unreachable(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "That is not a Slack webhook URL. It should start with https://hooks.slack.com/"
            case .rejected(let status, let body):
                switch body {
                case "no_service", "invalid_token", "no_team":
                    return "Slack no longer accepts this webhook (it was removed or revoked). Create a new one and paste it in Settings."
                case "channel_not_found", "channel_is_archived":
                    return "The channel this webhook posts to was deleted or archived."
                case "action_prohibited", "posting_to_general_channel_denied":
                    return "This Slack workspace does not allow the webhook to post there."
                default:
                    return "Slack rejected the message (\(status)\(body.isEmpty ? "" : ": \(body)"))."
                }
            case .unreachable(let detail):
                return "Could not reach Slack: \(detail)"
            }
        }
    }

    /// Accepts only https URLs on Slack's webhook hosts, so a mistyped address cannot send a
    /// summary somewhere else.
    public static func validated(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
            ["hooks.slack.com", "hooks.slack-gov.com"].contains(host), url.path.hasPrefix("/services/")
        else { return nil }
        return url
    }

    /// Posts the summary. If Slack refuses the Block Kit layout, the plain-text form is sent instead.
    public static func send(_ export: SummaryExport, to url: URL, session: URLSession = .shared) async throws {
        do {
            try await post(export.slackPayload(), to: url, session: session)
        } catch Failure.rejected(let status, let body) where status == 400 && body.contains("invalid_blocks") {
            try await post(export.slackPayload(blocks: false), to: url, session: session)
        }
    }

    public static func sendText(_ text: String, to url: URL, session: URLSession = .shared) async throws {
        let body = (try? JSONSerialization.data(withJSONObject: ["text": text])) ?? Data()
        try await post(body, to: url, session: session)
    }

    static func post(_ body: Data, to url: URL, session: URLSession) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let text = String(data: data.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.rejected(status: status, body: text)
        }
    }
}
