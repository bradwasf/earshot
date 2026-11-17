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
