import Foundation

/// Saved calls that share a day header on the home screen ("Today", "Yesterday", "Tuesday",
/// "October 2026").
public struct CallGroup: Identifiable, Sendable, Equatable {
    /// Stable for the period: "day-2026-11-19" or "month-2026-10".
    public let id: String
    public let title: String
    public var calls: [SavedCall]
}

public enum CallGrouping {
    /// Groups calls by when they happened, relative to `now`: Today, Yesterday, the weekday name
    /// for the five days before that, then one group per month. Calls keep their order within a
    /// group, and groups appear in the order of their first call (newest first for the library).
    public static func byDay(
        _ calls: [SavedCall], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> [CallGroup] {
        var groups: [CallGroup] = []
        var index: [String: Int] = [:]
        let today = calendar.startOfDay(for: now)
        let weekday = DateFormatter()
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        weekday.locale = locale
        weekday.setLocalizedDateFormatFromTemplate("EEEE")
        let month = DateFormatter()
        month.calendar = calendar
        month.timeZone = calendar.timeZone
        month.locale = locale
        month.setLocalizedDateFormatFromTemplate("MMMMyyyy")

        for call in calls {
            let (id, title) = period(
                of: call.date, today: today, calendar: calendar, weekday: weekday, month: month)
            if let position = index[id] {
                groups[position].calls.append(call)
            } else {
                index[id] = groups.count
                groups.append(CallGroup(id: id, title: title, calls: [call]))
            }
        }
        return groups
    }

    private static func period(
        of date: Date, today: Date, calendar: Calendar, weekday: DateFormatter, month: DateFormatter
    ) -> (id: String, title: String) {
        // Folders without a creation date are listed as .distantPast.
        guard calendar.component(.year, from: date) >= 1970 else { return ("undated", "Earlier") }
        let day = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        // A clock that moved backwards can leave a call "in the future": keep it under Today.
        let parts = calendar.dateComponents([.year, .month, .day], from: daysAgo < 0 ? today : day)
        let dayID = String(format: "day-%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        switch daysAgo {
        case ...0: return (dayID, "Today")
        case 1: return (dayID, "Yesterday")
        case 2...6: return (dayID, weekday.string(from: date))
        default:
            return (String(format: "month-%04d-%02d", parts.year ?? 0, parts.month ?? 0), month.string(from: date))
        }
    }
}

/// Text for the "Summary ready" notification.
public enum SummaryNotice {
    /// The summary's TL;DR, shortened for a notification (nil when the summary has none).
    public static func body(summaryMarkdown: String, limit: Int = 180) -> String? {
        CallLibrary.overview(of: summaryMarkdown).map { truncate($0, limit: limit) }
    }

    /// Cuts `text` to at most `limit` characters at a word boundary, ending in "…".
    public static func truncate(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        let cut = collapsed.prefix(limit - 1)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "…"
    }
}
