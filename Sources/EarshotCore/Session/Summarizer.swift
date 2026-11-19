import Foundation

public struct SummaryResult: Sendable {
    /// The full contents of summary.md.
    public let markdown: String
    /// A short title proposed by the model (used to name untitled calls).
    public let suggestedTitle: String?
    public let model: String
    public let seconds: Double
    public let chunks: Int
}

public enum SummaryError: Error, LocalizedError {
    case ollamaUnreachable
    case modelUnavailable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .ollamaUnreachable:
            return "Ollama is not running at http://127.0.0.1:11434. Start it with `ollama serve` (or open the Ollama app) and choose Regenerate Summary."
        case .modelUnavailable(let model):
            return "The Ollama model \"\(model)\" is not installed and could not be pulled. Run `ollama pull \(model)`."
        case .badResponse(let detail):
            return "Ollama returned an unexpected response: \(detail)"
        }
    }
}

/// Talks to the local Ollama server only (loopback). No text ever leaves the machine.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)
    }

    public func isRunning() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Starts `ollama serve` if the server is not up (Ollama is installed but may not be running).
    public func ensureRunning() async -> Bool {
        if await isRunning() { return true }
        let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await isRunning() { return true }
        }
        return false
    }

    public func installedModels() async -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        guard let (data, _) = try? await session.data(from: baseURL.appendingPathComponent("api/tags")),
            let tags = try? JSONDecoder().decode(Tags.self, from: data)
        else { return [] }
        return tags.models.map(\.name)
    }

    /// Pulls a model through the local Ollama daemon (the only network use, and only on request).
    public func pull(_ model: String, progress: @escaping @Sendable (String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, _) = try await session.bytes(for: request)
        for try await line in bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let error = object["error"] as? String { throw SummaryError.badResponse(error) }
            if let status = object["status"] as? String {
                if let total = object["total"] as? Double, let completed = object["completed"] as? Double, total > 0 {
                    progress("Pulling \(model): \(Int(completed / total * 100))%")
                } else {
                    progress("Pulling \(model): \(status)")
                }
            }
        }
    }

    public struct ChatStats: Sendable {
        public var promptTokens = 0
        public var outputTokens = 0
        public var promptSeconds = 0.0
        public var outputSeconds = 0.0
    }

    /// One non-thinking chat completion, streamed so the caller can show progress.
    public func chat(
        model: String, system: String, user: String, contextTokens: Int, maxOutputTokens: Int,
        temperature: Double = 0.1, repeatPenalty: Double = 1.1,
        onToken: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (text: String, stats: ChatStats) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "think": false,
            "keep_alive": "2m",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": [
                "temperature": temperature,
                "top_p": 0.9,
                "presence_penalty": 0,
                "repeat_penalty": repeatPenalty,
                "num_ctx": contextTokens,
                "num_predict": maxOutputTokens,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw SummaryError.modelUnavailable(model)
        }
        var text = ""
        var stats = ChatStats()
        var tokens = 0
        for try await line in bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let error = object["error"] as? String { throw SummaryError.badResponse(error) }
            if let message = object["message"] as? [String: Any], let content = message["content"] as? String,
                !content.isEmpty
            {
                text += content
                tokens += 1
                onToken?(tokens)
            }
            if object["done"] as? Bool == true {
                stats.promptTokens = object["prompt_eval_count"] as? Int ?? 0
                stats.outputTokens = object["eval_count"] as? Int ?? 0
                stats.promptSeconds = Double(object["prompt_eval_duration"] as? Int ?? 0) / 1e9
                stats.outputSeconds = Double(object["eval_duration"] as? Int ?? 0) / 1e9
            }
        }
        return (Self.stripThinking(text), stats)
    }

    /// Some models emit <think>…</think> even with thinking disabled; never let it into the summary.
    static func stripThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"), let close = result.range(of: "</think>"),
            open.lowerBound < close.lowerBound
        {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Turns a transcript into summary.md with a local LLM. Long calls are summarized map-reduce
/// style: notes per chunk first, then one final pass over the notes.
public struct Summarizer: Sendable {
    public static let defaultModel = "qwen3.5:4b-mlx"

    public let client: OllamaClient
    public let model: String
    /// Transcript characters per chunk (~4 characters per token, so ~3k tokens, about ten minutes
    /// of conversation). Small local models attribute owners far more reliably on short chunks.
    public var chunkCharacters = 12_000
    /// The user's own guidance for every summary ("Write in Spanish", "Use the names Priya and Raj
    /// for Them 1 and Them 2"). Added to each prompt below the required format, which stays authoritative.
    public var extraInstructions = ""

    public init(
        model: String = Summarizer.defaultModel, client: OllamaClient = OllamaClient(), extraInstructions: String = ""
    ) {
        self.model = model
        self.client = client
        self.extraInstructions = extraInstructions
    }

    private static let tldrSection = """
        ## TL;DR
        Two or three sentences: what the call was about and how it ended.
        """

    private static let keyPointsSection = """
        ## Key points
        - The important facts, numbers, arguments and context, one per bullet. At most eight bullets, no repeats.
        """

    private static let outcomeSections = """
        ## Decisions
        - Each decision that was actually made. Write "- None recorded." if there were none.

        ## Action items
        - [ ] **Owner** — task (deadline if one was stated). List every task someone agreed to do. The owner is whoever took the task: read the speaker label at the start of the line where they commit to it ("[12:01] Them 2: I will…" is owned by Them 2, "[12:05] Me: I will…" is owned by Me). If that person said their name, write the name instead of the label. Use **Unassigned** only if nobody took the task. Write "- None recorded." if there were none.

        ## Open questions
        - Anything left unresolved or needing follow-up. Write "- None recorded." if there were none.
        """

    private static let system = """
        You write accurate, concise meeting notes from call transcripts.
        The transcript was produced by speech recognition, so expect small errors and ignore filler.
        "Me" is the person who recorded the call; "Them" (or "Them 1", "Them 2", …) are the other participants.
        Only state what is supported by the transcript. Never invent names, dates, numbers, owners or decisions.
        Write in the language of the transcript. Output Markdown only, with no preamble and no closing remarks.
        """

    public func summarize(
        title: String, lines: [String], progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SummaryResult {
        let began = Date()
        guard await client.ensureRunning() else { throw SummaryError.ollamaUnreachable }
        if !(await client.installedModels()).contains(where: { $0 == model || $0 == "\(model):latest" }) {
            progress("Pulling \(model)…")
            do { try await client.pull(model, progress: progress) } catch {
                throw SummaryError.modelUnavailable(model)
            }
        }

        let chunks = Self.chunk(lines, limit: chunkCharacters)
        // Notes, marks and pauses alone are not a conversation to summarize.
        guard lines.contains(where: { !$0.isEmpty && !TranscriptFormat.isMarkerLine($0) }) else {
            return SummaryResult(
                markdown: "# \(title) — Summary\n\n_No speech was transcribed, so there is nothing to summarize._\n",
                suggestedTitle: nil, model: model, seconds: 0, chunks: 0)
        }

        let body: String
        let suggested: String?
        if chunks.count == 1 {
            progress("Summarizing…")
            let prompt = Self.singlePassPrompt(transcript: chunks[0], extraInstructions: extraInstructions)
            let context = Self.contextTokens(for: prompt, output: 1500)
            var reply = try await client.chat(
                model: model, system: Self.system, user: prompt, contextTokens: context, maxOutputTokens: 1500
            ) { tokens in
                if tokens % 40 == 0 { progress("Summarizing… (\(tokens) tokens)") }
            }
            if !Self.isComplete(reply.text) {
                // Small models occasionally loop on one bullet and run out of tokens: try once more.
                progress("Summarizing… (second attempt)")
                reply = try await client.chat(
                    model: model, system: Self.system, user: prompt, contextTokens: context, maxOutputTokens: 1500,
                    temperature: 0.4, repeatPenalty: 1.2)
            }
            (suggested, body) = Self.splitTitle(reply.text)
        } else {
            // Map: every chunk produces the four list sections in their final form.
            // Reduce: the lists are concatenated in code, so no decision or action item can be
            // dropped by a second model pass; the model only writes the title and the TL;DR.
            var merged = [[String]](repeating: [], count: Self.listHeadings.count)
            for (index, chunk) in chunks.enumerated() {
                progress("Summarizing part \(index + 1) of \(chunks.count)…")
                let prompt = Self.chunkPrompt(
                    transcript: chunk, part: index + 1, of: chunks.count, extraInstructions: extraInstructions)
                let context = Self.contextTokens(for: prompt, output: 1200)
                var reply = try await client.chat(
                    model: model, system: Self.system, user: prompt, contextTokens: context, maxOutputTokens: 1200)
                if !Self.isComplete(reply.text) {
                    reply = try await client.chat(
                        model: model, system: Self.system, user: prompt, contextTokens: context,
                        maxOutputTokens: 1200, temperature: 0.4, repeatPenalty: 1.2)
                }
                if let dump = ProcessInfo.processInfo.environment["EARSHOT_DEBUG_SUMMARY_DIR"] {
                    try? reply.text.write(toFile: "\(dump)/part-\(index + 1).md", atomically: true, encoding: .utf8)
                }
                let parsed = Self.parseSections(reply.text)
                for section in merged.indices { merged[section] += parsed[section] }
            }
            let lists = zip(Self.listHeadings, merged).map { heading, bullets -> String in
                let unique = Self.deduplicated(bullets)
                return "## \(heading)\n" + (unique.isEmpty ? "- None recorded." : unique.joined(separator: "\n"))
            }.joined(separator: "\n\n")

            progress("Writing the overview…")
            let prompt = Self.overviewPrompt(notes: lists, extraInstructions: extraInstructions)
            let reply = try await client.chat(
                model: model, system: Self.system, user: prompt,
                contextTokens: Self.contextTokens(for: prompt, output: 300), maxOutputTokens: 300)
            let overview = Self.parseOverview(reply.text)
            suggested = overview.title
            body = "## TL;DR\n\(overview.tldr)\n\n\(lists)"
        }

        guard body.contains("##") else { throw SummaryError.badResponse("the model did not produce the summary sections") }
        let seconds = Date().timeIntervalSince(began)
        let heading = "# \(title) — Summary"
        let footer =
            "\n\n---\n_Summarized on-device with `\(model)` via Ollama in \(Int(seconds.rounded())) s. Full transcript: [transcript.md](transcript.md)_\n"
        return SummaryResult(
            markdown: heading + "\n\n" + body + footer, suggestedTitle: suggested, model: model, seconds: seconds,
            chunks: chunks.count)
    }

    static let listHeadings = ["Key points", "Decisions", "Action items", "Open questions"]

    // MARK: - Prompts

    static func singlePassPrompt(transcript: String, extraInstructions: String = "") -> String {
        """
        Write the meeting notes for the call below.

        Start with a single line `Title: <a specific 3-7 word title for this call>`, then output exactly these \
        five sections, in this order, following the instruction under each heading:

        \(tldrSection)

        \(keyPointsSection)

        \(outcomeSections)
        \(markerGuidance(for: transcript))\(instructionBlock(extraInstructions, labels: "`Title:` line and every heading"))
        Transcript:
        \(transcript)
        """
    }

    static func chunkPrompt(transcript: String, part: Int, of parts: Int, extraInstructions: String = "") -> String {
        """
        This is part \(part) of \(parts) of a long call transcript. Write the meeting notes for \
        this part only, without mentioning that it is a part or where it starts or ends. Output exactly \
        these four sections, in this order, following the instruction under each heading:

        \(outcomeSections)

        \(keyPointsSection)
        \(markerGuidance(for: transcript))\(instructionBlock(extraInstructions, labels: "heading"))
        Transcript part \(part):
        \(transcript)
        """
    }

    static func overviewPrompt(notes: String, extraInstructions: String = "") -> String {
        """
        Below are the complete notes of one call. Output exactly two lines and nothing else:
        Title: <a specific 3-7 word title for this call>
        TL;DR: <two or three sentences: what the call was about and how it ended>
        \(instructionBlock(extraInstructions, labels: "`Title:` and `TL;DR:` label"))
        \(notes)
        """
    }

    /// Explains the user's notes, marks and pauses, when the transcript has any.
    static func markerGuidance(for transcript: String) -> String {
        let lines = transcript.components(separatedBy: "\n").filter(TranscriptFormat.isMarkerLine)
        guard !lines.isEmpty else { return "" }
        var rules: [String] = []
        if lines.contains(where: { $0.contains(TranscriptFormat.notePrefix) || $0.contains(TranscriptFormat.markText) }) {
            rules.append(
                """
                Lines with NOTE or MARK were added by Me, the person who recorded the call, while it was going on. \
                They show what Me considers important: make sure the moments they point to (what was being said \
                at that time) are reflected in the key points, decisions or action items. A NOTE may itself state \
                a task or a decision; treat it as Me's own words. Do not mention the NOTE or MARK labels themselves.
                """)
        }
        if lines.contains(where: { $0.contains(TranscriptFormat.pauseText) }) {
            rules.append(
                """
                Lines with PAUSED mark a stretch where recording was switched off. Nothing said then was \
                captured: do not guess what happened in that gap.
                """)
        }
        return "\n" + rules.joined(separator: "\n") + "\n"
    }

    /// The user's extra instructions, fenced and subordinate to the required format.
    static func instructionBlock(_ text: String, labels: String) -> String {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !trimmed.isEmpty else { return "" }
        return """

            Additional instructions from the user, between the markers below. Follow them for language, focus, \
            style and names, but they never change the required format: keep the \(labels) exactly as given \
            above (in English), and the same sections in the same order.
            <<<
            \(trimmed)
            >>>

            """
    }

    /// A reply is usable when every list section is present and it did not degenerate into a loop.
    static func isComplete(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard ["key point", "decision", "action item", "open question"].allSatisfy({ lowered.contains("## " + $0) })
        else { return false }
        let bullets = text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") && $0.count > 20 }
        return Set(bullets).count >= bullets.count - 2
    }

    /// Bullets of each list section, in `listHeadings` order.
    static func parseSections(_ text: String) -> [[String]] {
        var sections = [[String]](repeating: [], count: listHeadings.count)
        var current: Int?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.lowercased()
                if heading.contains("key point") { current = 0 }
                else if heading.contains("decision") { current = 1 }
                else if heading.contains("action") { current = 2 }
                else if heading.contains("question") { current = 3 }
                else { current = nil }
            } else if let current, line.hasPrefix("- ") || line.hasPrefix("* ") {
                let bullet = "- " + line.dropFirst(2)
                if !bullet.lowercased().contains("none recorded") { sections[current].append(bullet) }
            }
        }
        return sections
    }

    static func deduplicated(_ bullets: [String]) -> [String] {
        var seen = Set<String>()
        return bullets.filter { seen.insert($0.lowercased().filter { $0.isLetter || $0.isNumber }).inserted }
    }

    static func parseOverview(_ text: String) -> (title: String?, tldr: String) {
        var title: String?
        var tldr: String?
        var fallback: String?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowered = line.lowercased()
            if lowered.hasPrefix("title:") {
                let value = line.dropFirst("title:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
                if !value.isEmpty && title == nil { title = String(value.prefix(80)) }
            } else if lowered.hasPrefix("tl;dr:") {
                if tldr == nil { tldr = line.dropFirst("tl;dr:".count).trimmingCharacters(in: .whitespaces) }
            } else if fallback == nil, !line.hasPrefix("-") {
                fallback = line
            }
        }
        // Keep the overview to a few sentences even if the model rambled on the same line.
        var result = tldr ?? fallback ?? ""
        if result.count > 700, let cut = result.prefix(700).lastIndex(of: ".") { result = String(result[...cut]) }
        return (title, result.isEmpty ? "See the sections below." : result)
    }

    /// Splits the transcript on line boundaries into chunks of at most `limit` characters.
    static func chunk(_ lines: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines where !line.isEmpty {
            if !current.isEmpty && current.count + line.count + 1 > limit {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Ollama's default context (4k) silently truncates long prompts, so size it to the prompt.
    static func contextTokens(for prompt: String, output: Int) -> Int {
        let estimate = (prompt.count + system.count) / 3 + output + 256
        return min(max(4096, (estimate + 1023) / 1024 * 1024), 32_768)
    }

    static func splitTitle(_ text: String) -> (String?, String) {
        var lines = text.components(separatedBy: "\n")
        var title: String?
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first {
            let cleaned = first.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.lowercased().hasPrefix("title:") {
                let value = cleaned.dropFirst("title:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
                if !value.isEmpty { title = String(value.prefix(80)) }
                lines.removeFirst()
            }
        }
        if let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) { lines.removeFirst(start) }
        // Tidy a common small-model slip: a doubled bullet marker ("- - None recorded.").
        lines = lines.map { $0.hasPrefix("- - ") ? String($0.dropFirst(2)) : $0 }
        return (title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
