import XCTest

@testable import EarshotCore

final class ActionItemsTests: XCTestCase {
    private let summary = """
        # Launch Review — Summary

        ## TL;DR
        The launch moved.

        ## Key points
        - [ ] Not an action item, just a bullet.

        ## Action items
        - [ ] **Them 2** — update the press release by Friday.
        - [x] **Me** — Tell leadership.
          * **Unassigned**: book the room
        - Send the deck around.

        ## Open questions
        - None recorded.

        ---
        _Summarized on-device. Full transcript: [transcript.md](transcript.md)_
        """

    func testParsesOldAndNewBullets() {
        let items = ActionItems.parse(summary)
        XCTAssertEqual(items.map(\.done), [false, true, false, false])
        XCTAssertEqual(items.map(\.owner), ["Them 2", "Me", "Unassigned", nil])
        XCTAssertEqual(items[0].task, "Update the press release by Friday.")
        XCTAssertEqual(items[0].text, "**Them 2** — update the press release by Friday.")
        XCTAssertEqual(items[2].task, "Book the room")
        XCTAssertEqual(items[3].task, "Send the deck around.")
        XCTAssertTrue(items[1].isMine)
        XCTAssertEqual(items.map(\.line), [9, 10, 11, 12])
        XCTAssertTrue(ActionItems.parse("# X — Summary\n\n_The summary could not be generated._").isEmpty)
        XCTAssertTrue(ActionItems.parse("## Action items\n- [ ] None recorded.\n").isEmpty)
    }

    func testCheckboxNeedsASpaceOrEnd() {
        XCTAssertEqual(ActionItems.checkbox("[x] Ship").done, true)
        XCTAssertEqual(ActionItems.checkbox("[X]").done, true)
        XCTAssertNil(ActionItems.checkbox("[link](x) text").done)
        XCTAssertEqual(ActionItems.checkbox("[link](x) text").text, "[link](x) text")
    }

    func testTickingChangesOnlyThatLine() throws {
        let items = ActionItems.parse(summary)
        let ticked = try XCTUnwrap(ActionItems.setting(true, for: items[0], in: summary))
        let before = summary.components(separatedBy: "\n")
        let after = ticked.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(after[9], "- [x] **Them 2** — update the press release by Friday.")
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 1)

        // Old-style bullets gain a checkbox, keeping indentation and the bullet character.
        let indented = try XCTUnwrap(ActionItems.setting(true, for: items[2], in: summary))
        XCTAssertEqual(indented.components(separatedBy: "\n")[11], "  * [x] **Unassigned**: book the room")
        let plain = try XCTUnwrap(ActionItems.setting(false, for: items[3], in: summary))
        XCTAssertEqual(plain.components(separatedBy: "\n")[12], "- [ ] Send the deck around.")
        let unticked = try XCTUnwrap(ActionItems.setting(false, for: items[1], in: summary))
        XCTAssertEqual(unticked.components(separatedBy: "\n")[10], "- [ ] **Me** — Tell leadership.")
    }

    func testTickingFindsAMovedItemAndReportsAMissingOne() throws {
        let item = ActionItems.parse(summary)[1]
        // Someone added a line above it since the summary was read.
        let edited = summary.replacingOccurrences(of: "## Action items\n", with: "## Action items\n- [ ] New thing\n")
        let ticked = try XCTUnwrap(ActionItems.setting(false, for: item, in: edited))
        XCTAssertTrue(ticked.contains("- [ ] **Me** — Tell leadership."))
        XCTAssertTrue(ticked.contains("- [ ] New thing"))
        XCTAssertNil(ActionItems.setting(true, for: item, in: "## Action items\n- [ ] Something else\n"))
        // A bullet with the same text outside the action items is never touched.
        let outside = ActionItem(line: 6, done: false, text: "Not an action item, just a bullet.")
        XCTAssertNil(ActionItems.setting(true, for: outside, in: summary))
    }

    func testSetDoneRewritesTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("summary.md")
        try summary.write(to: url, atomically: true, encoding: .utf8)
        let item = ActionItems.parse(summary)[0]
        try ActionItems.setDone(true, for: item, folder: folder)
        XCTAssertEqual(ActionItems.parse(try String(contentsOf: url, encoding: .utf8)).map(\.done), [true, true, false, false])
        try "# X\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ActionItems.setDone(true, for: item, folder: folder)) {
            XCTAssertEqual($0 as? ActionItems.Failure, .notFound)
        }
    }

    func testNormalizesNewSummaries() {
        let raw = "## Key points\n- A point\n\n## Action items\n- **Me** — Do it\n- [ ] **Them** — Done already\n- [ ] None recorded.\n\n---\n- footer"
        XCTAssertEqual(
            ActionItems.normalized(raw),
            "## Key points\n- A point\n\n## Action items\n- [ ] **Me** — Do it\n- [ ] **Them** — Done already\n- None recorded.\n\n---\n- footer")
    }

    func testRegeneratingKeepsTicks() {
        let old = "## Action items\n- [x] **Me** — Tell leadership.\n- [x] **Them** — Order pizza.\n- [ ] **Me** — Open thing\n"
        // Same task with a renamed owner and different punctuation is still ticked; the dropped
        // ticked item is appended so the finished work is not lost.
        let new = "## TL;DR\nX\n\n## Action items\n- [ ] **Priya** — tell leadership\n- [ ] **Me** — Open thing\n\n## Open questions\n- None recorded.\n"
        XCTAssertEqual(
            ActionItems.carryingOver(from: old, into: new),
            "## TL;DR\nX\n\n## Action items\n- [x] **Priya** — tell leadership\n- [ ] **Me** — Open thing\n- [x] **Them** — Order pizza.\n\n## Open questions\n- None recorded.\n")
        // A "None recorded." placeholder is replaced.
        XCTAssertEqual(
            ActionItems.carryingOver(from: old, into: "## Action items\n- None recorded.\n"),
            "## Action items\n- [x] **Me** — Tell leadership.\n- [x] **Them** — Order pizza.\n")
        // No action items section: one is added before the footnote.
        XCTAssertEqual(
            ActionItems.carryingOver(from: "## Action items\n- [x] A\n", into: "## TL;DR\nX\n\n---\n_foot_\n"),
            "## TL;DR\nX\n\n## Action items\n- [x] A\n\n---\n_foot_\n")
        // Nothing ticked: unchanged.
        XCTAssertEqual(ActionItems.carryingOver(from: "## Action items\n- [ ] A\n", into: new), new)
    }

    func testLibraryListsActionItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("2026-11-17-review")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Review\n\n**[00:02] Them:** Hi.\n".write(
            to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let call = try XCTUnwrap(CallLibrary.list(root: root).first)
        XCTAssertEqual(call.actionItems.count, 4)
        XCTAssertEqual(call.openActionItems.map(\.owner), ["Them 2", "Unassigned", nil])
        XCTAssertEqual(call.overview, "The launch moved.")
    }
}

final class ActionItemExportTests: XCTestCase {
    private let summary = """
        # Launch Review — Summary

        ## TL;DR
        Moved.

        ## Action items
        - [ ] **Them 2** — Update the press release.
        - [x] **Me** — Tell leadership.
        - Old style item
        """

    func testDoneItemsInEveryFormat() throws {
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: summary))
        let section = try XCTUnwrap(export.actionItems)
        XCTAssertEqual(section.items, ["**Them 2** — Update the press release.", "**Me** — Tell leadership.", "Old style item"])
        XCTAssertEqual(section.done, [false, true, false])
        XCTAssertTrue(export.slackText.hasSuffix(
            "*Action items*\n• *Them 2* — Update the press release.\n• ✓ ~*Me* — Tell leadership.~\n• Old style item"))
        XCTAssertTrue(export.html(.document).contains(
            "<ul><li><b>Them 2</b> — Update the press release.</li><li>✓ <s><b>Me</b> — Tell leadership.</s></li><li>Old style item</li></ul>"))
        XCTAssertTrue(export.markdown.hasSuffix(
            "## Action items\n- [ ] **Them 2** — Update the press release.\n- [x] **Me** — Tell leadership.\n- [ ] Old style item\n"))
    }

    func testCopyActionItems() throws {
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: summary))
        XCTAssertEqual(
            export.actionItemsMarkdown,
            "**Launch Review** — Action items\n\n- [ ] **Them 2** — Update the press release.\n- [x] **Me** — Tell leadership.\n- [ ] Old style item\n")
        let html = try XCTUnwrap(export.actionItemsHTML)
        XCTAssertTrue(html.hasPrefix("<p><b>Launch Review</b> — Action items</p>"))
        XCTAssertTrue(html.contains("<li>☐ <b>Them 2</b> — Update the press release.</li><li>☑ <s><b>Me</b> — Tell leadership.</s></li>"))
        let none = try XCTUnwrap(SummaryExport(summaryMarkdown: "# A — Summary\n\n## TL;DR\nX\n\n## Action items\n- None recorded.\n"))
        XCTAssertNil(none.actionItems)
        XCTAssertNil(none.actionItemsMarkdown)
    }

    func testWholeCallMarkdownAndText() throws {
        let export = try XCTUnwrap(SummaryExport(summaryMarkdown: summary, title: "Launch Review", detail: "Tue · 02:02"))
        let lines: [CallExport.Line] = [("00:02", "Them 2", "Hello."), ("00:05", "Me", "Hi.")]
        let markdown = CallExport.markdown(summary: export, title: "Launch Review", detail: "Tue · 02:02", lines: lines)
        XCTAssertTrue(markdown.hasPrefix("# Launch Review\n\n_Tue · 02:02_\n\nMoved.\n\n## Action items\n- [ ] **Them 2**"))
        XCTAssertTrue(markdown.hasSuffix("## Transcript\n\n**[00:02] Them 2:** Hello.\n\n**[00:05] Me:** Hi.\n"))
        XCTAssertEqual(
            CallExport.markdown(summary: nil, title: "Empty", detail: nil, lines: []), "# Empty\n")
        XCTAssertEqual(
            CallExport.transcriptText(title: "Launch Review", detail: "Tue", lines: lines),
            "Launch Review\nTue\n\n[00:02] Them 2: Hello.\n[00:05] Me: Hi.\n")
        XCTAssertEqual(CallExport.fileName("Q3: plan / review?", extension: "md"), "Q3- plan - review.md")
        XCTAssertEqual(CallExport.fileName("  ", extension: "txt"), "Call.txt")
    }
}
