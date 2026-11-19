import XCTest

@testable import EarshotCore

/// "Yours" for action items once "Me" has been given a name.
final class ActionItemOwnerTests: XCTestCase {
    private let transcript = """
        # Weekly sync

        - **Date:** Tuesday, 17 November 2026 at 10:00
        - **Duration:** 02:05
        - **Speakers:** Me, Them 1, Them 2
        - Transcribed on-device by Earshot. "Me" is the microphone; "Them" is system audio.

        ---

        **[00:01] Them 1:** Hello.

        **[00:05] Me:** I will review it.

        """

    private let summary = """
        # Weekly sync — Summary

        ## Action items
        - [ ] **Them 2** — send the deck
        - [ ] **Me** — review it

        """

    func testOwnersResolveToLabelsThroughSpeakerNames() {
        let names = ["Me": "Sam", "Them 1": "Priya", "Them 2": "Zoë"]
        XCTAssertEqual(SpeakerNames.label(of: "Sam", names: names), "Me")
        XCTAssertEqual(SpeakerNames.label(of: "sam", names: names), "Me")
        XCTAssertEqual(SpeakerNames.label(of: "Zoe", names: names), "Them 2")
        XCTAssertEqual(SpeakerNames.label(of: "them 3", names: names), "Them 3")
        XCTAssertEqual(SpeakerNames.label(of: "Me", names: [:]), "Me")
        XCTAssertNil(SpeakerNames.label(of: "Unassigned", names: names))
        XCTAssertNil(SpeakerNames.label(of: "Samantha", names: names))
        XCTAssertEqual(SpeakerNames.myName(names), "Sam")
    }

    func testRenamedMeStillOwnsItsItems() {
        let names = ["Me": "Sam", "Them 1": "Priya"]
        let items = ActionItems.parse("## Action items\n- [ ] **Sam** — Fix the payment sheet.\n- [ ] **Priya** — Book the room.\n")
        XCTAssertEqual(items.map { $0.isMine(names: names) }, [true, false])
        // Without the call's names a renamed owner reads as somebody else, as before.
        XCTAssertEqual(items.map(\.isMine), [false, false])
        // "Me" is always yours, named or not.
        XCTAssertTrue(ActionItem(line: 0, done: false, text: "**Me** — Ship it.").isMine(names: names))
        XCTAssertFalse(ActionItem(line: 0, done: false, text: "Ship it.").isMine(names: names))
    }

    func testLibraryCarriesTheNamesOfASavedCall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-mine-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("2026-11-17-weekly-sync")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

        try SpeakerNames.rename(folder: folder, label: "Me", to: "Sam")
        let call = try XCTUnwrap(CallLibrary.list(root: root).first)
        XCTAssertEqual(call.speakerNames, ["Me": "Sam"])
        XCTAssertEqual(CallLibrary.load(folder: folder)?.names, ["Me": "Sam"])
        XCTAssertEqual(call.actionItems.map(\.owner), ["Them 2", "Sam"])
        XCTAssertEqual(call.actionItems.map { $0.isMine(names: call.speakerNames) }, [false, true])
    }
}
