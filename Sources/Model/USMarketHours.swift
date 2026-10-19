import Foundation

/// Utility for tracking US stock market hours (NYSE / NASDAQ).
/// Regular Trading Hours: Monday through Friday, 9:30 AM to 4:00 PM US Eastern Time (ET).
enum USMarketHours {
    static let easternTimeZone: TimeZone = {
        TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!
    }()

    /// Returns true if the regular US stock market is currently open.
    static func isMarketOpen(at date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = easternTimeZone

        // 1 = Sunday, 2 = Monday, ..., 6 = Friday, 7 = Saturday
        let weekday = calendar.component(.weekday, from: date)
        guard weekday >= 2 && weekday <= 6 else { return false }

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let totalMinutes = hour * 60 + minute

        // 9:30 AM = 9 * 60 + 30 = 570
        // 4:00 PM = 16 * 60 = 960
        return totalMinutes >= 570 && totalMinutes < 960
    }

    /// Status string for UI display, e.g. "Open · 10:45 AM ET" or "Closed · 7:15 PM ET (Opens Mon-Fri 9:30 AM ET)"
    static func statusDescription(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = easternTimeZone
        formatter.dateFormat = "h:mm a 'ET'"
        let currentTimeET = formatter.string(from: date)

        if isMarketOpen(at: date) {
            return "Open · \(currentTimeET)"
        } else {
            return "Closed · \(currentTimeET) (Opens Mon-Fri 9:30 AM ET)"
        }
    }
}
