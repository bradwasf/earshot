import XCTest

@testable import EarshotCore

final class TimelineAlignerTests: XCTestCase {
    func testPadsLateStartAndKeepsSteadyStream() {
        var aligner = TimelineAligner(origin: 100)
        // First buffer arrives 0.5 s after the call started: 8000 samples of silence are inserted.
        let first = aligner.align([Float](repeating: 1, count: 160), hostSeconds: 100.5)
        XCTAssertEqual(first.count, 8000 + 160)
        XCTAssertEqual(first[7999], 0)
        XCTAssertEqual(first[8000], 1)
        // The next buffer is on time: passed through untouched.
        let second = aligner.align([Float](repeating: 1, count: 160), hostSeconds: 100.51)
        XCTAssertEqual(second.count, 160)
        XCTAssertEqual(aligner.position, 8320)
    }

    func testDropsAudioFromBeforeTheCallAndFillsGaps() {
        var aligner = TimelineAligner(origin: 10)
        // Captured entirely before the call started: dropped.
        XCTAssertTrue(aligner.align([Float](repeating: 1, count: 160), hostSeconds: 9.5).isEmpty)
        // Straddles the start: only the part after the origin is kept.
        XCTAssertEqual(aligner.align([Float](repeating: 1, count: 320), hostSeconds: 9.99).count, 160)
        // A one-second dropout is filled with silence so the timeline stays true.
        let afterGap = aligner.align([Float](repeating: 1, count: 160), hostSeconds: 11.01)
        XCTAssertEqual(aligner.position, Int(1.02 * 16000))
        XCTAssertEqual(afterGap.last, 1)
        XCTAssertEqual(afterGap.first, 0)
    }
}

final class TranscriptFormatTests: XCTestCase {
    private let segments = [
        TranscriptSegment(channel: .them, speaker: 1, text: "Hello there.", start: 1, end: 2),
        TranscriptSegment(channel: .them, speaker: 1, text: "Shall we start?", start: 2.5, end: 4),
        TranscriptSegment(channel: .me, text: "Yes.", start: 5, end: 5.5),
        TranscriptSegment(channel: .them, speaker: 2, text: "I am here too.", start: 3700, end: 3702),
    ]

    func testMergesConsecutiveLinesFromOneSpeaker() {
        let turns = TranscriptFormat.turns(segments, remoteSpeakers: 2)
        XCTAssertEqual(turns.map(\.label), ["Them 1", "Me", "Them 2"])
        XCTAssertEqual(turns[0].text, "Hello there. Shall we start?")
    }

    func testSingleRemoteSpeakerIsJustThem() {
        XCTAssertEqual(TranscriptFormat.speakerLabel(segments[0], remoteSpeakers: 1), "Them")
        XCTAssertEqual(TranscriptFormat.speakerLabel(segments[2], remoteSpeakers: 3), "Me")
    }

    func testMarkdownAndTimestamps() {
        XCTAssertEqual(TranscriptFormat.timestamp(65), "01:05")
        XCTAssertEqual(TranscriptFormat.timestamp(3700), "01:01:40")
        let markdown = TranscriptFormat.markdown(
            title: "Sync", startedAt: Date(timeIntervalSince1970: 0), duration: 3702, segments: segments,
            remoteSpeakers: 2, inProgress: false)
        XCTAssertTrue(markdown.hasPrefix("# Sync\n"))
        XCTAssertTrue(markdown.contains("**[00:00:05] Me:** Yes."))
        XCTAssertTrue(markdown.contains("**[01:01:40] Them 2:** I am here too."))
    }

    func testFolderNames() {
        XCTAssertEqual(CallFolder.slug("Weekly Sync: Q4 / Roadmap!"), "weekly-sync-q4-roadmap")
        XCTAssertEqual(CallFolder.slug("Café déjà vu"), "cafe-deja-vu")
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour) = (2026, 11, 17, 9)
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(CallFolder.name(date: date, title: "Weekly sync"), "2026-11-17-weekly-sync")
        XCTAssertEqual(CallFolder.name(date: date, title: "???"), "2026-11-17-call")
    }

    func testFolderCreationAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let first = try CallFolder.create(root: root, date: date, title: "Standup")
        let second = try CallFolder.create(root: root, date: date, title: "Standup")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(second.url.lastPathComponent.hasPrefix(first.url.lastPathComponent))
    }
}

final class SummarizerTests: XCTestCase {
    func testChunksOnLineBoundaries() {
        let lines = (0..<100).map { "[00:\(String(format: "%02d", $0 % 60))] Me: " + String(repeating: "word ", count: 20) }
        let chunks = Summarizer.chunk(lines, limit: 1000)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1000 })
        XCTAssertEqual(chunks.flatMap { $0.components(separatedBy: "\n") }, lines)
        XCTAssertEqual(Summarizer.chunk(["short"], limit: 1000), ["short"])
        XCTAssertTrue(Summarizer.chunk([], limit: 1000).isEmpty)
    }

    func testSplitsTitleFromBody() {
        let (title, body) = Summarizer.splitTitle("**Title:** \"Launch Date Review\"\n\nSome preamble\n## TL;DR\nText")
        XCTAssertEqual(title, "Launch Date Review")
        XCTAssertEqual(body, "## TL;DR\nText")
        XCTAssertEqual(Summarizer.splitTitle("## Open questions\n- - None recorded.").1, "## Open questions\n- None recorded.")
    }

    func testParsesAndMergesSections() {
        let reply = """
            ## Decisions
            - Ship on the 10th.
            ## Action Items
            * [ ] **Me** — fix the bug by Wednesday.
            ## Open questions
            - None recorded.
            ## Key points
            - Two bugs block the launch.
            - Two bugs block the launch.
            """
        let sections = Summarizer.parseSections(reply)
        XCTAssertEqual(sections[0].count, 2)
        XCTAssertEqual(sections[1], ["- Ship on the 10th."])
        XCTAssertEqual(sections[2], ["- [ ] **Me** — fix the bug by Wednesday."])
        XCTAssertTrue(sections[3].isEmpty)
        XCTAssertEqual(Summarizer.deduplicated(sections[0]).count, 1)
    }

    func testDetectsIncompleteOrLoopingReplies() {
        let good = "## Key points\n- A fact that matters here.\n## Decisions\n- None recorded.\n## Action items\n- None recorded.\n## Open questions\n- None recorded."
        XCTAssertTrue(Summarizer.isComplete(good))
        XCTAssertFalse(Summarizer.isComplete("## Key points\n- Only one section was written."))
        let loop = good + String(repeating: "\n- The same long bullet again and again.", count: 10)
        XCTAssertFalse(Summarizer.isComplete(loop))
    }

    func testOverviewKeepsOnlyTheSummaryLine() {
        let overview = Summarizer.parseOverview("Title: Planning Sync\nTL;DR: We planned the quarter.\n- stray bullet\nMore rambling.")
        XCTAssertEqual(overview.title, "Planning Sync")
        XCTAssertEqual(overview.tldr, "We planned the quarter.")
    }

    func testContextWindowScalesWithPrompt() {
        XCTAssertEqual(Summarizer.contextTokens(for: "short", output: 500), 4096)
        XCTAssertGreaterThan(Summarizer.contextTokens(for: String(repeating: "x", count: 30_000), output: 1500), 10_000)
        XCTAssertLessThanOrEqual(Summarizer.contextTokens(for: String(repeating: "x", count: 500_000), output: 1500), 32_768)
    }

    func testStripsThinkingBlocks() {
        XCTAssertEqual(OllamaClient.stripThinking("<think>hmm</think>\n## TL;DR\nDone"), "## TL;DR\nDone")
    }
}

final class CallLibraryTests: XCTestCase {
    func testReadsBackWhatTheSessionWrites() {
        let segments = [
            TranscriptSegment(channel: .them, speaker: 2, text: "Hi: all.", start: 3, end: 4),
            TranscriptSegment(channel: .me, text: "Hello.", start: 6, end: 7),
        ]
        let markdown = TranscriptFormat.markdown(
            title: "Design review", startedAt: Date(), duration: 125, segments: segments, remoteSpeakers: 2,
            inProgress: false)
        let parsed = CallLibrary.parseTranscript(markdown)
        XCTAssertEqual(parsed.title, "Design review")
        XCTAssertEqual(parsed.duration, "02:05")
        XCTAssertEqual(parsed.turns.map(\.label), ["Them 2", "Me"])
        XCTAssertEqual(parsed.turns[0].speaker, 2)
        XCTAssertEqual(parsed.turns[0].channel, .them)
        XCTAssertEqual(parsed.turns[0].time, "00:03")
        XCTAssertEqual(parsed.turns[0].text, "Hi: all.")
        XCTAssertEqual(parsed.turns[1].channel, .me)
    }

    func testOverviewComesFromTheTldrSection() {
        let summary = "# Call — Summary\n\n## TL;DR\nWe moved the launch.\nTo the 10th.\n\n## Key points\n- A"
        XCTAssertEqual(CallLibrary.overview(of: summary), "We moved the launch. To the 10th.")
        XCTAssertNil(CallLibrary.overview(of: "# Call — Summary\n\n_The summary could not be generated._"))
    }
}

final class CallDetectorTests: XCTestCase {
    private let zoom = CallApp.match(bundleID: "us.zoom.xos")!
    private let slack = CallApp.match(bundleID: "com.tinyspeck.slackmacgap.helper")!

    func testMatchesAppsAndTheirHelpers() {
        XCTAssertEqual(zoom.callName, "Zoom call")
        XCTAssertEqual(slack.callName, "Slack huddle")
        XCTAssertEqual(CallApp.match(bundleID: "com.microsoft.teams2.modulehost")?.id, "teams")
        XCTAssertEqual(CallApp.match(bundleID: "com.apple.avconferenced")?.id, "facetime")
        XCTAssertNil(CallApp.match(bundleID: "com.apple.Safari"))
        XCTAssertNil(CallApp.match(bundleID: "local.earshot.app"))
    }

    func testJoinNeedsSustainedMicrophoneUse() {
        var detector = CallDetector(joinDelay: 2, endDelay: 6)
        XCTAssertEqual(detector.update(using: [zoom], now: 0), [])
        XCTAssertEqual(detector.update(using: [zoom], now: 1), [])
        XCTAssertEqual(detector.update(using: [zoom], now: 2), [.joined(zoom)])
        // Reported once per call, not on every sample.
        XCTAssertEqual(detector.update(using: [zoom], now: 4), [])
        XCTAssertEqual(detector.active, [zoom])
    }

    func testShortBlipIsNotACall() {
        var detector = CallDetector(joinDelay: 2, endDelay: 6)
        XCTAssertEqual(detector.update(using: [slack], now: 0), [])
        XCTAssertEqual(detector.update(using: [], now: 1), [])
        XCTAssertEqual(detector.update(using: [], now: 8), [])
        // The earlier blip does not count toward the next call's two seconds.
        XCTAssertEqual(detector.update(using: [slack], now: 9), [])
        XCTAssertEqual(detector.update(using: [slack], now: 11), [.joined(slack)])
    }

    func testEndNeedsSustainedSilenceAndCallsAreIndependent() {
        var detector = CallDetector(joinDelay: 2, endDelay: 6)
        _ = detector.update(using: [zoom], now: 0)
        XCTAssertEqual(detector.update(using: [zoom, slack], now: 2), [.joined(zoom)])
        XCTAssertEqual(detector.update(using: [zoom, slack], now: 4), [.joined(slack)])
        // A brief reconnect does not end the call.
        XCTAssertEqual(detector.update(using: [slack], now: 6), [])
        XCTAssertEqual(detector.update(using: [zoom, slack], now: 8), [])
        XCTAssertEqual(detector.update(using: [slack], now: 10), [])
        XCTAssertEqual(detector.update(using: [slack], now: 14), [.ended(zoom)])
        XCTAssertEqual(detector.active, [slack])
        // Joining again later is a new call.
        _ = detector.update(using: [zoom, slack], now: 20)
        XCTAssertEqual(detector.update(using: [zoom, slack], now: 22), [.joined(zoom)])
    }

    func testFindsTheAppThatOwnsAHelperProcess() {
        XCTAssertNil(MicrophoneActivity.owningAppBundleID(executablePath: "/usr/libexec/audiomxd"))
        XCTAssertEqual(
            MicrophoneActivity.owningAppBundleID(executablePath: "/System/Applications/FaceTime.app/Contents/MacOS/FaceTime"),
            "com.apple.FaceTime")
        // Reading live state must not crash and never reports this process.
        XCTAssertFalse(MicrophoneActivity.bundleIDsCapturingAudio().contains(Bundle.main.bundleIdentifier ?? "-"))
    }
}

final class SummaryExportTests: XCTestCase {
    private let summary = """
        # Launch Review — Summary

        ## TL;DR
        The launch moved to **December 10th**. Budget is <fine> & agreed.

        ## Key points
        - Budget spent is $42,000 of $60,000.
        - See the [plan](https://example.com/plan?a=1&b=2) and *watch* the `flag`.

        ## Decisions
        - None recorded.

        ## Action items
        - [ ] **Them 2** — Update the press release by Friday.
        - [ ] **Me** — Tell leadership.

        ## Open questions
        - None recorded.

        ---
        _Summarized on-device with `qwen3.5:4b-mlx` via Ollama in 8 s. Full transcript: [transcript.md](transcript.md)_
        """

    func testParsesAndDropsEmptySectionsAndFootnote() throws {
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: summary, detail: "Tue 17 Nov 2026 · 02:02"))
        XCTAssertEqual(export.title, "Launch Review")
        XCTAssertEqual(export.sections.map(\.name), ["Key points", "Action items"])
        XCTAssertEqual(export.sections[1].items, ["**Them 2** — Update the press release by Friday.", "**Me** — Tell leadership."])
        XCTAssertFalse(export.slackText.contains("transcript.md"))
        XCTAssertNil(SummaryExport(summaryMarkdown: "# X — Summary\n\n_The summary could not be generated: offline_\n"))
    }

    func testSlackMarkup() throws {
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: summary, detail: "Tue 17 Nov 2026 · 02:02"))
        XCTAssertEqual(
            export.slackText,
            """
            *Launch Review*
            _Tue 17 Nov 2026 · 02:02_

            The launch moved to *December 10th*. Budget is &lt;fine&gt; &amp; agreed.

            *Key points*
            • Budget spent is $42,000 of $60,000.
            • See the <https://example.com/plan?a=1&amp;b=2|plan> and _watch_ the `flag`.

            *Action items*
            • *Them 2* — Update the press release by Friday.
            • *Me* — Tell leadership.
            """)
    }

    func testHTMLAndMarkdown() throws {
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: summary))
        let slack = export.html(.slack)
        XCTAssertTrue(slack.hasPrefix("<p><b>Launch Review</b></p>"))
        XCTAssertTrue(slack.contains("<p>The launch moved to <b>December 10th</b>. Budget is &lt;fine&gt; &amp; agreed.</p>"))
        XCTAssertTrue(slack.contains("<p><b>Action items</b></p>\n<ul><li><b>Them 2</b> — Update the press release by Friday.</li>"))
        XCTAssertTrue(slack.contains("<a href=\"https://example.com/plan?a=1&amp;b=2\">plan</a> and <i>watch</i> the <code>flag</code>"))
        XCTAssertFalse(slack.contains("<h2>"))
        XCTAssertTrue(export.html(.document).contains("<h1>Launch Review</h1>"))
        XCTAssertTrue(export.html(.document).contains("<h2>Key points</h2>"))
        XCTAssertTrue(export.markdown.hasPrefix("# Launch Review\n\nThe launch moved to **December 10th**."))
        XCTAssertTrue(export.markdown.contains("## Action items\n- **Them 2** — Update the press release by Friday.\n- **Me** — Tell leadership.\n"))
    }

    func testWebhookPayloadRespectsSlackLimits() throws {
        let long = "## TL;DR\nShort.\n\n## Key points\n" + (0..<200).map { "- Point \($0) " + String(repeating: "x", count: 60) }.joined(separator: "\n")
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: long, title: String(repeating: "T", count: 300)))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: export.slackPayload()) as? [String: Any])
        let blocks = try XCTUnwrap(payload["blocks"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(blocks.count, 50)
        XCTAssertEqual(blocks.first?["type"] as? String, "header")
        XCTAssertEqual(((blocks.first?["text"] as? [String: Any])?["text"] as? String)?.count, 150)
        let sections = blocks.filter { $0["type"] as? String == "section" }
        XCTAssertGreaterThan(sections.count, 2)
        for section in sections {
            let text = try XCTUnwrap((section["text"] as? [String: Any])?["text"] as? String)
            XCTAssertLessThanOrEqual(text.count, 3000)
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertNotNil(payload["text"] as? String)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: export.slackPayload(blocks: false)) as? [String: Any])
        XCTAssertNil(plain["blocks"])
        XCTAssertEqual(SummaryExport.split("aaaa\nbbbb\ncccc", limit: 9), ["aaaa\nbbbb", "cccc"])
        XCTAssertEqual(SummaryExport.split(String(repeating: "z", count: 25), limit: 10).map(\.count), [10, 10, 5])
    }

    func testOnlySlackWebhookURLsAreAccepted() {
        XCTAssertNotNil(SlackWebhook.validated("  https://hooks.slack.com/services/T000/B000/abc123\n"))
        XCTAssertNil(SlackWebhook.validated("http://hooks.slack.com/services/T000/B000/abc123"))
        XCTAssertNil(SlackWebhook.validated("https://hooks.slack.com.evil.example/services/T000/B000/abc"))
        XCTAssertNil(SlackWebhook.validated("https://example.com/services/T000/B000/abc"))
        XCTAssertNil(SlackWebhook.validated("https://hooks.slack.com/"))
        XCTAssertNil(SlackWebhook.validated(""))
    }
}

/// Answers webhook posts in-process, so the send path is tested without the network.
final class StubSlack: URLProtocol {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var respond: ([String: Any]) -> (Int, String) = { _ in (200, "ok") }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.bodies.append(body)
        let (status, text) = Self.respond(body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class SlackWebhookTests: XCTestCase {
    private let url = URL(string: "https://hooks.slack.com/services/T000/B000/abc123")!
    private var session: URLSession!
    private let export = SummaryExport(summaryMarkdown: "## TL;DR\nWe shipped.\n\n## Decisions\n- Ship it.", title: "Sync")!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSlack.self]
        session = URLSession(configuration: configuration)
        StubSlack.bodies = []
        StubSlack.respond = { _ in (200, "ok") }
    }

    func testPostsBlocksAsJSON() async throws {
        try await SlackWebhook.send(export, to: url, session: session)
        XCTAssertEqual(StubSlack.bodies.count, 1)
        XCTAssertNotNil(StubSlack.bodies[0]["blocks"])
        XCTAssertEqual(StubSlack.bodies[0]["text"] as? String, "*Sync*\n\nWe shipped.\n\n*Decisions*\n• Ship it.")
    }

    func testFallsBackToPlainTextWhenBlocksAreRefused() async throws {
        StubSlack.respond = { body in body["blocks"] == nil ? (200, "ok") : (400, "invalid_blocks") }
        try await SlackWebhook.send(export, to: url, session: session)
        XCTAssertEqual(StubSlack.bodies.count, 2)
        XCTAssertNil(StubSlack.bodies[1]["blocks"])
    }

    func testReportsARevokedWebhook() async {
        StubSlack.respond = { _ in (404, "no_service") }
        do {
            try await SlackWebhook.send(export, to: url, session: session)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SlackWebhook.Failure, .rejected(status: 404, body: "no_service"))
            XCTAssertTrue(error.localizedDescription.contains("removed or revoked"))
        }
    }
}

final class CallLibraryEditingTests: XCTestCase {
    private func makeCall(root: URL, name: String, title: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# \(title)\n\n- **Duration:** 02:02\n\n---\n\n**[00:02] Them:** We picked the kiwi option.\n"
            .write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "# \(title) — Summary\n\n## TL;DR\nFruit was chosen.\n"
            .write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        return folder
    }

    func testRenameRewritesHeadingsAndFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeCall(root: root, name: "2026-11-17-zoom-call", title: "Zoom call")
        _ = try makeCall(root: root, name: "2026-11-17-fruit-sync", title: "Fruit sync")

        let renamed = try CallLibrary.rename(folder: folder, to: "  Fruit Sync \n")
        // The plain name is taken by another call, so a counter is added.
        XCTAssertEqual(renamed.lastPathComponent, "2026-11-17-fruit-sync-2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(CallLibrary.load(folder: renamed)?.title, "Fruit Sync")
        XCTAssertEqual(CallLibrary.load(folder: renamed)?.turns.count, 1)
        XCTAssertTrue(try XCTUnwrap(CallLibrary.summary(folder: renamed)).hasPrefix("# Fruit Sync — Summary\n"))
        // An empty title changes nothing; the same title keeps the folder where it is.
        XCTAssertEqual(try CallLibrary.rename(folder: renamed, to: "   "), renamed)
        XCTAssertEqual(try CallLibrary.rename(folder: renamed, to: "Fruit sync 2"), renamed)
    }

    func testSearchCoversTitleSummaryAndTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeCall(root: root, name: "2026-11-17-budget", title: "Budget review")
        let call = try XCTUnwrap(CallLibrary.list(root: root).first)
        XCTAssertTrue(call.matches("budget"))
        XCTAssertTrue(call.matches("KIWI option"))
        XCTAssertTrue(call.matches("fruit budget"))
        XCTAssertTrue(call.matches("  "))
        XCTAssertFalse(call.matches("budget mango"))
    }
}
