import XCTest

@testable import EarshotCore

final class CallGroupingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    private func call(_ when: String, _ title: String = "Call") -> SavedCall {
        SavedCall(
            folder: URL(fileURLWithPath: "/tmp/\(title)-\(when)"), title: title, date: date(when), duration: nil,
            overview: nil, searchText: "")
    }

    private func groups(_ calls: [SavedCall], now: String) -> [CallGroup] {
        CallGrouping.byDay(calls, now: date(now), calendar: calendar, locale: locale)
    }

    func testRelativeDayHeaders() {
        // Thursday 19 November 2026, mid-afternoon.
        let calls = [
            call("2026-11-19 14:00:00", "a"), call("2026-11-19 00:00:00", "b"),
            call("2026-11-18 23:59:59", "c"), call("2026-11-18 00:00:00", "d"),
            call("2026-11-17 09:00:00", "e"), call("2026-11-13 09:00:00", "f"),
            call("2026-11-12 23:59:59", "g"), call("2026-11-01 09:00:00", "h"),
            call("2026-10-31 09:00:00", "i"), call("2025-11-19 09:00:00", "j"),
        ]
        let result = groups(calls, now: "2026-11-19 15:30:00")
        XCTAssertEqual(
            result.map(\.title),
            ["Today", "Yesterday", "Tuesday", "Friday", "November 2026", "October 2026", "November 2025"])
        XCTAssertEqual(result.map { $0.calls.map(\.title).joined() }, ["ab", "cd", "e", "f", "gh", "i", "j"])
    }

    func testBoundariesFollowTheCalendarDayNotTwentyFourHours() {
        // Just after midnight, a call from five minutes ago is already "Yesterday".
        let result = groups([call("2026-11-18 23:55:00")], now: "2026-11-19 00:00:01")
        XCTAssertEqual(result.map(\.title), ["Yesterday"])
        // Six days back is still a weekday name; seven is the month.
        XCTAssertEqual(groups([call("2026-11-13 00:00:00")], now: "2026-11-19 23:59:59").map(\.title), ["Friday"])
        XCTAssertEqual(
            groups([call("2026-11-12 23:59:59")], now: "2026-11-19 00:00:00").map(\.title), ["November 2026"])
    }

    func testDaylightSavingChangeDoesNotShiftDays() {
        // Clocks went back on 25 October 2026 in Berlin, so that day had 25 hours.
        let result = groups(
            [call("2026-10-25 23:30:00", "a"), call("2026-10-24 23:30:00", "b")], now: "2026-10-26 00:30:00")
        XCTAssertEqual(result.map(\.title), ["Yesterday", "Saturday"])
    }

    func testIdsAreStableAndGroupsMergeOutOfOrderCalls() {
        let calls = [call("2026-11-19 10:00:00", "a"), call("2026-09-02 10:00:00", "b"), call("2026-11-19 08:00:00", "c")]
        let result = groups(calls, now: "2026-11-19 12:00:00")
        XCTAssertEqual(result.map(\.id), ["day-2026-11-19", "month-2026-09"])
        XCTAssertEqual(result[0].calls.map(\.title), ["a", "c"])
        // A day keeps its id when it stops being Today.
        XCTAssertEqual(groups([calls[0]], now: "2026-11-21 12:00:00").map(\.id), ["day-2026-11-19"])
    }

    func testFutureAndUndatedCalls() {
        var undated = call("2026-11-19 10:00:00", "u")
        undated = SavedCall(
            folder: undated.folder, title: "u", date: .distantPast, duration: nil, overview: nil, searchText: "")
        let result = groups([call("2026-11-20 10:00:00", "f"), undated], now: "2026-11-19 12:00:00")
        XCTAssertEqual(result.map(\.title), ["Today", "Earlier"])
        XCTAssertTrue(groups([], now: "2026-11-19 12:00:00").isEmpty)
    }
}

final class SummaryNoticeTests: XCTestCase {
    func testBodyIsTheTldr() {
        let summary = "# Sync — Summary\n\n## TL;DR\nWe moved the launch\nto the 10th.\n\n## Decisions\n- Ship"
        XCTAssertEqual(SummaryNotice.body(summaryMarkdown: summary), "We moved the launch to the 10th.")
        XCTAssertNil(SummaryNotice.body(summaryMarkdown: "# Sync — Summary\n\n_The summary could not be generated._"))
    }

    func testTruncatesAtAWordBoundary() {
        XCTAssertEqual(SummaryNotice.truncate("Short  text", limit: 40), "Short text")
        XCTAssertEqual(SummaryNotice.truncate("We agreed to ship, then review it.", limit: 20), "We agreed to ship…")
        let long = String(repeating: "x", count: 50)
        XCTAssertEqual(SummaryNotice.truncate(long, limit: 10), String(repeating: "x", count: 9) + "…")
        XCTAssertLessThanOrEqual(SummaryNotice.truncate(String(repeating: "word ", count: 100), limit: 180).count, 180)
    }
}
