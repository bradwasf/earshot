import XCTest

@testable import EarshotCore

final class SpeakerNamesTests: XCTestCase {
    private let transcript = """
        # Weekly sync

        - **Date:** Tuesday, 17 November 2026 at 10:00
        - **Duration:** 02:05
        - **Speakers:** Me, Them 1, Them 2
        - Transcribed on-device by Earshot. "Me" is the microphone; "Them" is system audio.

        ---

        **[00:01] Them 1:** Hello, Them 2 here? Them 12 is not a thing.

        **[00:05] Me:** Yes.

        > A line that is not a turn: **[00:06] Them 1:** quoted

        **[00:09] Them 2:** I will send the deck.

        **[00:20] Them 1:** Great.

        """

    private let summary = """
        # Weekly sync — Summary

        ## TL;DR
        Them 1 opened; Them 2 will send the deck. Them 12 and Them1 are not labels. Mentally, Me agreed.

        ## Action items
        - [ ] **Them 2** — send the deck
        - [ ] **Me** — review it

        ---

        _Summarized by Them 1 model_

        """

    func testOldTranscriptsParseAsBefore() {
        let parsed = CallLibrary.parseTranscript(transcript)
        XCTAssertEqual(parsed.turns.map(\.label), ["Them 1", "Me", "Them 2", "Them 1"])
        XCTAssertEqual(parsed.turns.map(\.originalLabel), ["Them 1", "Me", "Them 2", "Them 1"])
        XCTAssertEqual(parsed.turns.map(\.speaker), [1, nil, 2, 1])
        XCTAssertEqual(parsed.turns[1].channel, .me)
        XCTAssertEqual(parsed.turns[0].text, "Hello, Them 2 here? Them 12 is not a thing.")
        // A single remote speaker is plain "Them", with no number.
        let single = CallLibrary.parseTranscript("**[00:01] Them:** Hi.")
        XCTAssertEqual(single.turns.first?.originalLabel, "Them")
        XCTAssertNil(single.turns.first?.speaker)
    }

    func testRenameRewritesHeaderAndTurns() throws {
        let renamed = try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "  Priya\nRao ")
        XCTAssertEqual(renamed.previous, "Them 1")
        XCTAssertEqual(renamed.current, "Priya Rao")
        let text = renamed.text
        XCTAssertTrue(text.contains("- **Speakers:** Me, Them 1, Them 2\n- **Speaker names:** Them 1 = Priya Rao\n"))
        XCTAssertTrue(text.contains("**[00:01] Priya Rao:** Hello, Them 2 here? Them 12 is not a thing."))
        XCTAssertTrue(text.contains("**[00:20] Priya Rao:** Great."))
        XCTAssertTrue(text.contains("**[00:09] Them 2:** I will send the deck."))
        // Lines that are not turns are left exactly as they were.
        XCTAssertTrue(text.contains("> A line that is not a turn: **[00:06] Them 1:** quoted"))

        let parsed = CallLibrary.parseTranscript(text)
        XCTAssertEqual(parsed.turns.map(\.label), ["Priya Rao", "Me", "Them 2", "Priya Rao"])
        XCTAssertEqual(parsed.turns.map(\.originalLabel), ["Them 1", "Me", "Them 2", "Them 1"])
        XCTAssertEqual(parsed.turns.map(\.speaker), [1, nil, 2, 1])
        XCTAssertEqual(parsed.title, "Weekly sync")
        XCTAssertEqual(parsed.duration, "02:05")
    }

    func testRenameAgainAndRevert() throws {
        var text = try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "Priya").text
        text = try SpeakerNames.renameInTranscript(text, label: "Me", to: "Sam").text
        let again = try SpeakerNames.renameInTranscript(text, label: "Them 1", to: "Priyanka")
        XCTAssertEqual(again.previous, "Priya")
        XCTAssertTrue(again.text.contains("- **Speaker names:** Me = Sam, Them 1 = Priyanka\n"))
        XCTAssertTrue(again.text.contains("**[00:05] Sam:** Yes."))

        // Reverting with the label itself, then with an empty name.
        var reverted = try SpeakerNames.renameInTranscript(again.text, label: "Them 1", to: "Them 1").text
        reverted = try SpeakerNames.renameInTranscript(reverted, label: "Me", to: " ").text
        XCTAssertEqual(reverted, transcript)
    }

    func testNamesWithPunctuationAndCommas() throws {
        var text = try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "O'Neil, Dr. J. = lead").text
        text = try SpeakerNames.renameInTranscript(text, label: "Them 2", to: "Ana-María (PM)").text
        let header = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix(SpeakerNames.headerPrefix) })
        XCTAssertEqual(SpeakerNames.parseHeader(header), ["Them 1": "O'Neil, Dr. J. = lead", "Them 2": "Ana-María (PM)"])
        let parsed = CallLibrary.parseTranscript(text)
        XCTAssertEqual(parsed.turns.map(\.speaker), [1, nil, 2, 1])
        XCTAssertEqual(parsed.turns[2].label, "Ana-María (PM)")
        // Asterisks would break the bold label, so they are dropped.
        let starred = try SpeakerNames.renameInTranscript(transcript, label: "Me", to: "**Sam**").text
        XCTAssertTrue(starred.contains("**[00:05] Sam:** Yes."))
    }

    func testRejectsLabelsAndDuplicateNames() throws {
        XCTAssertThrowsError(try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "Them 2")) {
            XCTAssertEqual($0 as? SpeakerNames.Failure, .reservedLabel("Them 2"))
        }
        XCTAssertThrowsError(try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "me"))
        XCTAssertThrowsError(try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "THEM 7"))
        let named = try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "Priya").text
        XCTAssertThrowsError(try SpeakerNames.renameInTranscript(named, label: "Them 2", to: "priya")) {
            XCTAssertEqual($0 as? SpeakerNames.Failure, .duplicate(name: "Priya", label: "Them 1"))
        }
        XCTAssertThrowsError(try SpeakerNames.renameInTranscript(transcript, label: "Them 3", to: "Raj")) {
            XCTAssertEqual($0 as? SpeakerNames.Failure, .unknownSpeaker("Them 3"))
        }
        // A name that only looks like a label is fine.
        XCTAssertNoThrow(try SpeakerNames.renameInTranscript(transcript, label: "Them 1", to: "Themis"))
    }

    func testSummaryReplacesWholeLabelsOnly() {
        let renamed = SpeakerNames.renameInSummary(summary, from: "Them 1", to: "Priya")
        XCTAssertTrue(renamed.contains("Priya opened; Them 2 will send the deck. Them 12 and Them1 are not labels."))
        XCTAssertTrue(renamed.hasPrefix("# Weekly sync — Summary\n"))
        // The footnote after the rule is not touched.
        XCTAssertTrue(renamed.contains("_Summarized by Them 1 model_"))

        let me = SpeakerNames.renameInSummary(summary, from: "Me", to: "Sam")
        XCTAssertTrue(me.contains("Mentally, Sam agreed."))
        XCTAssertTrue(me.contains("- [ ] **Sam** — review it"))

        // A bare "Them" is not the start of "Them 2".
        let bare = SpeakerNames.renameInSummary("Them said hi. Them 2 agreed. Them, too.", from: "Them", to: "Lee")
        XCTAssertEqual(bare, "Lee said hi. Them 2 agreed. Lee, too.")
        // "$" and "\\" in a name are literal, not template syntax.
        XCTAssertEqual(SpeakerNames.renameInSummary("Them 2 paid", from: "Them 2", to: "A$1\\b"), "A$1\\b paid")
        // Another speaker's longer name that contains the old one is kept.
        XCTAssertEqual(
            SpeakerNames.renameInSummary("Priya and Priya S met", from: "Priya", to: "Pia", keeping: ["Priya S"]),
            "Pia and Priya S met")
        // Names ending in punctuation still match as whole words.
        XCTAssertEqual(SpeakerNames.renameInSummary("Ask Dr. J. today", from: "Dr. J.", to: "Jo"), "Ask Jo today")
    }

    func testRenameInFolderUpdatesBothFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-names-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("2026-11-17-weekly-sync")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try SpeakerNames.rename(folder: folder, label: "Them 2", to: "Raj"), "Raj")
        XCTAssertEqual(try SpeakerNames.rename(folder: folder, label: "Them 2", to: "Raj K"), "Raj K")
        let loaded = try XCTUnwrap(CallLibrary.load(folder: folder))
        XCTAssertEqual(loaded.turns[2].label, "Raj K")
        XCTAssertEqual(loaded.turns[2].speaker, 2)
        let written = try XCTUnwrap(CallLibrary.summary(folder: folder))
        XCTAssertTrue(written.contains("- [ ] **Raj K** — send the deck"))
        XCTAssertTrue(written.contains("Them 1 opened; Raj K will send"))

        // Reverting restores the labels in both files.
        XCTAssertEqual(try SpeakerNames.rename(folder: folder, label: "Them 2", to: nil), "Them 2")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8), transcript)
        XCTAssertEqual(CallLibrary.summary(folder: folder), summary)
        // Searching the library finds calls by speaker name.
        try SpeakerNames.rename(folder: folder, label: "Them 1", to: "Priya")
        XCTAssertTrue(try XCTUnwrap(CallLibrary.list(root: root).first).matches("priya"))
    }
}

final class TalkTimeTests: XCTestCase {
    private func turn(_ time: String, _ label: String, _ words: Int, original: String? = nil) -> SavedTurn {
        let original = original ?? label
        let identity = SpeakerNames.identity(of: original)
        return SavedTurn(
            id: 0, time: time, label: label, channel: identity.channel, speaker: identity.speaker,
            text: Array(repeating: "word", count: words).joined(separator: " "), originalLabel: original)
    }

    func testParsesTimestamps() {
        XCTAssertEqual(TranscriptFormat.seconds("02:03"), 123)
        XCTAssertEqual(TranscriptFormat.seconds("01:02:03"), 3723)
        XCTAssertNil(TranscriptFormat.seconds("live"))
        XCTAssertNil(TranscriptFormat.seconds("1:"))
        XCTAssertNil(TranscriptFormat.seconds(""))
    }

    func testTurnsRunToTheNextOneCappedByWordsAndCallLength() {
        let turns = [
            turn("00:00", "Me", 30),  // gap 10 s, cap 22 s → 10
            turn("00:10", "Priya", 3, original: "Them 1"),  // gap 50 s, cap 4 s → 4 (long pause not counted)
            turn("01:00", "Them 2", 60),  // last: call ends at 01:06 → 6
        ]
        let shares = TalkTime.shares(turns, duration: 66)
        XCTAssertEqual(shares.map(\.label), ["Me", "Them 1", "Them 2"])
        XCTAssertEqual(shares.map(\.name), ["Me", "Priya", "Them 2"])
        XCTAssertEqual(shares.map(\.seconds), [10, 4, 6])
        XCTAssertEqual(shares[1].speaker, 1)
        XCTAssertEqual(shares.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(TalkTime.percentages(shares), [50, 20, 30])
        // Without a duration the last turn is capped by its words.
        XCTAssertEqual(TalkTime.shares([turn("00:00", "Me", 3)], duration: nil).first?.seconds, 4)
    }

    func testSumsTurnsPerSpeakerAndHandlesEmptyCalls() {
        let shares = TalkTime.shares(
            [turn("00:00", "Them", 10), turn("00:05", "Me", 10), turn("00:08", "Them", 10)], duration: 20)
        XCTAssertEqual(shares.map(\.label), ["Me", "Them"])
        XCTAssertEqual(shares[0].seconds, 3)
        XCTAssertEqual(shares[1].seconds, 5 + 2 + 10 / 1.5, accuracy: 1e-9)
        XCTAssertTrue(TalkTime.shares([], duration: 100).isEmpty)
        XCTAssertTrue(TalkTime.shares([turn("live", "Me", 3)], duration: 10).isEmpty)
        // Percentages always add up to 100.
        let thirds = TalkTime.shares(
            [turn("00:00", "Me", 30), turn("00:10", "Them 1", 30, original: "Them 1"), turn("00:20", "Them 2", 30)],
            duration: 30)
        XCTAssertEqual(TalkTime.percentages(thirds).reduce(0, +), 100)
    }
}

final class TextSearchTests: XCTestCase {
    func testCaseAndDiacriticInsensitive() {
        let matches = TextSearch.matches("cafe", in: ["Le Café opens.", "no", "CAFE cafe"])
        XCTAssertEqual(matches.map(\.block), [0, 2, 2])
        XCTAssertEqual(matches[0].range, 3..<7)
        XCTAssertEqual(matches[2].range, 5..<9)
        XCTAssertTrue(TextSearch.matches("  ", in: ["anything"]).isEmpty)
    }

    func testPhraseFirstThenWords() {
        let blocks = ["the kiwi option won", "budget is fine"]
        XCTAssertEqual(TextSearch.matches("kiwi  option", in: blocks).map(\.range), [4..<15])
        // The phrase occurs nowhere: each word is found instead, in reading order.
        let words = TextSearch.matches("budget kiwi", in: blocks)
        XCTAssertEqual(words.map(\.block), [0, 1])
        XCTAssertEqual(words.map(\.range), [4..<8, 0..<6])
        // Overlapping word matches are not doubled.
        XCTAssertEqual(TextSearch.matches("plan an", in: ["a plan"]).map(\.range), [2..<6])
    }

    func testOffsetsCountCharactersNotBytes() {
        let matches = TextSearch.matches("deck", in: ["👋🏽 Ana-María sends the deck"])
        XCTAssertEqual(matches.first?.range, 22..<26)
    }
}
