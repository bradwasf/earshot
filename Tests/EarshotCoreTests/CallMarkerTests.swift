import XCTest

@testable import EarshotCore

final class PauseGateTests: XCTestCase {
    func testSilencesOnlyThePausedStretchOnTheCallTimeline() {
        let gate = PauseGate()
        XCTAssertFalse(gate.isPaused)
        XCTAssertTrue(gate.pause(at: 1.0))
        XCTAssertFalse(gate.pause(at: 1.5), "already paused")
        XCTAssertTrue(gate.isPaused)

        // A buffer from 0.5 s to 1.5 s (rate 10 for readability): the second half is silenced.
        var samples = [Float](repeating: 1, count: 10)
        gate.silence(&samples, firstSample: 5, sampleRate: 10)
        XCTAssertEqual(samples, [1, 1, 1, 1, 1, 0, 0, 0, 0, 0])

        XCTAssertTrue(gate.resume(at: 2.0))
        XCTAssertFalse(gate.resume(at: 2.5), "not paused")
        XCTAssertFalse(gate.isPaused)

        // 1.5 s – 2.5 s: silenced up to the resume, kept after it.
        samples = [Float](repeating: 1, count: 10)
        gate.silence(&samples, firstSample: 15, sampleRate: 10)
        XCTAssertEqual(samples, [0, 0, 0, 0, 0, 1, 1, 1, 1, 1])

        // Before and after the pause nothing changes; the sample count never does.
        samples = [Float](repeating: 1, count: 4)
        gate.silence(&samples, firstSample: 0, sampleRate: 10)
        XCTAssertEqual(samples, [1, 1, 1, 1])
        gate.silence(&samples, firstSample: 30, sampleRate: 10)
        XCTAssertEqual(samples, [1, 1, 1, 1])
    }

    func testContainsWithMarginKeepsSpeechRightAtTheResume() {
        let gate = PauseGate()
        gate.pause(at: 10)
        XCTAssertTrue(gate.contains(500), "an open pause runs on")
        gate.resume(at: 20)
        XCTAssertFalse(gate.contains(9.9))
        XCTAssertTrue(gate.contains(10))
        XCTAssertTrue(gate.contains(19.9))
        XCTAssertFalse(gate.contains(19.9, margin: 0.5))
        XCTAssertFalse(gate.contains(20))
        XCTAssertEqual(gate.resumeTime(covering: 19.7), 20)
        XCTAssertNil(gate.resumeTime(covering: 20))
        gate.pause(at: 30)
        XCTAssertNil(gate.resumeTime(covering: 31), "still paused")
    }
}

final class CallMarkerFormatTests: XCTestCase {
    private let segments = [
        TranscriptSegment(channel: .them, text: "We should talk about pricing.", start: 3, end: 5),
        TranscriptSegment(channel: .them, text: "It went up last month.", start: 6, end: 8),
        TranscriptSegment(channel: .me, text: "Okay.", start: 30, end: 31),
    ]
    private let markers = [
        CallMarker(kind: .note, start: 5.5, text: "Ask Priya\nabout the  discount"),
        CallMarker(kind: .mark, start: 12),
        CallMarker(kind: .pause, start: 14, end: 28),
    ]

    func testNotesSplitTurnsAndSitWhereTheyWereTaken() {
        let entries = TranscriptFormat.entries(segments, markers: markers, remoteSpeakers: 1)
        let kinds = entries.map { entry -> String in
            switch entry {
            case .turn(let turn): return "\(turn.label)@\(Int(turn.start))"
            case .marker(let marker): return "\(marker.kind.rawValue)@\(Int(marker.start))"
            }
        }
        // Without the note, the two "Them" lines would merge into one turn.
        XCTAssertEqual(kinds, ["Them@3", "note@5", "Them@6", "mark@12", "pause@14", "Me@30"])
        XCTAssertEqual(TranscriptFormat.turns(segments, remoteSpeakers: 1).count, 2)
    }

    func testMarkdownRoundTripAndOlderReadersSkipMarkers() {
        let markdown = TranscriptFormat.markdown(
            title: "Pricing", startedAt: Date(), duration: 40, segments: segments, remoteSpeakers: 1,
            inProgress: false, markers: markers)
        XCTAssertTrue(markdown.contains("> **[00:05] Note:** Ask Priya about the discount"))
        XCTAssertTrue(markdown.contains("> **[00:12] Marked**"))
        XCTAssertTrue(markdown.contains("> **[00:14 – 00:28] Paused** — off the record, nothing was transcribed"))
        // Older versions of Earshot only read lines that start with "**[" as speech.
        let legacySpeech = markdown.components(separatedBy: "\n").filter { $0.hasPrefix("**[") }
        XCTAssertEqual(legacySpeech.count, 3)

        let parsed = CallLibrary.parseTranscript(markdown)
        XCTAssertEqual(parsed.turns.map(\.label), ["Them", "Them", "Me"])
        XCTAssertEqual(parsed.markers.map(\.marker.kind), [.note, .mark, .pause])
        XCTAssertEqual(parsed.markers.map(\.afterTurns), [1, 2, 2])
        XCTAssertEqual(parsed.markers[0].marker.text, "Ask Priya about the discount")
        XCTAssertEqual(parsed.markers[0].marker.start, 5)
        XCTAssertEqual(parsed.markers[2].marker.start, 14)
        XCTAssertEqual(parsed.markers[2].marker.end, 28)
    }

    func testOpenPauseAndNotesOnlyTranscript() {
        let open = [CallMarker(kind: .pause, start: 3725), CallMarker(kind: .note, start: 3700, text: "Decide on Q3")]
        let markdown = TranscriptFormat.markdown(
            title: "Long", startedAt: Date(), duration: 3800, segments: [], remoteSpeakers: 0, inProgress: true,
            markers: open)
        XCTAssertTrue(markdown.contains("_No speech was detected._"))
        XCTAssertTrue(markdown.contains("> **[01:01:40] Note:** Decide on Q3"))
        XCTAssertTrue(markdown.contains("> **[01:02:05] Paused** — off the record (still paused)"))
        let parsed = CallLibrary.parseTranscript(markdown)
        XCTAssertTrue(parsed.turns.isEmpty)
        XCTAssertEqual(parsed.markers.map(\.marker.kind), [.note, .pause])
        XCTAssertEqual(parsed.markers[1].marker.start, 3725)
        XCTAssertNil(parsed.markers[1].marker.end)
    }

    func testOlderTranscriptsHaveNoMarkers() {
        let old = "# Old call\n\n- **Duration:** 01:00\n\n---\n\n**[00:02] Them:** Hello.\n\n> Just a quote\n"
        let parsed = CallLibrary.parseTranscript(old)
        XCTAssertEqual(parsed.turns.count, 1)
        XCTAssertTrue(parsed.markers.isEmpty)
        XCTAssertNil(TranscriptFormat.parseMarkerLine("> **[xx] Note:** nope"))
    }

    func testSummaryLinesCarryNotesAndPauses() {
        let lines = TranscriptFormat.plainText(segments, remoteSpeakers: 1, markers: markers)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[1], "[00:05] NOTE typed by Me during the call: Ask Priya about the discount")
        XCTAssertEqual(lines[3], "[00:12] MARK: Me flagged this moment as important.")
        XCTAssertEqual(lines[4], "[00:14–00:28] PAUSED: recording was off; nothing said in this span was captured.")
        XCTAssertEqual(lines.filter(TranscriptFormat.isMarkerLine).count, 3)
        XCTAssertFalse(TranscriptFormat.isMarkerLine("[00:03] Them: NOTE typed by Me during the call: sneaky"))
    }

    func testCleansNotes() {
        XCTAssertEqual(CallMarker.cleanNote("  one\n two\t three  "), "one two three")
        XCTAssertEqual(CallMarker.cleanNote(String(repeating: "a", count: 2000)).count, 1000)
    }
}

final class SummaryPromptTests: XCTestCase {
    private let transcript = "[00:03] Them: We picked the kiwi option."

    func testExtraInstructionsReachEveryPrompt() {
        let extra = "Write in Spanish.\nUse the names Priya and Raj for Them 1 and Them 2."
        let prompts = [
            Summarizer.singlePassPrompt(transcript: transcript, extraInstructions: extra),
            Summarizer.chunkPrompt(transcript: transcript, part: 1, of: 2, extraInstructions: extra),
            Summarizer.overviewPrompt(notes: "## Key points\n- Kiwi", extraInstructions: extra),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("<<<\n\(extra)\n>>>"))
            XCTAssertTrue(prompt.contains("never change the required format"))
        }
        // The format instructions come first and stay intact; the transcript stays last.
        let single = prompts[0]
        let headings = single.range(of: "## Open questions")!
        let block = single.range(of: "Additional instructions")!
        let body = single.range(of: "Transcript:\n" + transcript)!
        XCTAssertLessThan(headings.lowerBound, block.lowerBound)
        XCTAssertLessThan(block.lowerBound, body.lowerBound)
        XCTAssertTrue(prompts[2].hasSuffix("## Key points\n- Kiwi"))
    }

    func testNoInstructionsLeavesThePromptAsBefore() {
        let prompt = Summarizer.singlePassPrompt(transcript: transcript, extraInstructions: "  \n ")
        XCTAssertFalse(prompt.contains("Additional instructions"))
        XCTAssertFalse(prompt.contains("NOTE or MARK"))
        XCTAssertTrue(prompt.contains("if there were none.\n\nTranscript:\n" + transcript))
        XCTAssertTrue(
            Summarizer.overviewPrompt(notes: "N").hasSuffix("how it ended>\n\nN"))
    }

    func testNotesAndPausesAreExplainedOnlyWhenPresent() {
        let withNote = transcript + "\n" + TranscriptFormat.plainLine(CallMarker(kind: .note, start: 4, text: "Kiwi wins"))
        let prompt = Summarizer.singlePassPrompt(transcript: withNote)
        XCTAssertTrue(prompt.contains("NOTE or MARK were added by Me"))
        XCTAssertFalse(prompt.contains("PAUSED mark"))
        let withPause = transcript + "\n" + TranscriptFormat.plainLine(CallMarker(kind: .pause, start: 4, end: 9))
        let chunk = Summarizer.chunkPrompt(transcript: withPause, part: 1, of: 3)
        XCTAssertTrue(chunk.contains("PAUSED mark a stretch where recording was switched off"))
        XCTAssertFalse(chunk.contains("NOTE or MARK"))
    }
}
