import Foundation

/// The words and thresholds every capacity surface shares, so the home
/// indicator, the Settings strip and ⌘P cannot disagree.
public enum CapacityDisplay {
    /// §5 amber at this many percent left or fewer. Never red: §5 reserves
    /// red for production, and a low account is not a production hazard.
    public static let lowThreshold = 20

    public static func isLow(_ w: CapacityWindow) -> Bool { w.percentLeft <= lowThreshold }

    public static func hasReset(_ w: CapacityWindow, now: Date) -> Bool { now >= w.resetsAt }

    private static func formatter(_ pattern: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f
    }

    /// `20:20` today, `Fri 09:00` within the week, `16 Oct` beyond.
    public static func resetLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return formatter("HH:mm", calendar).string(from: date) }
        if date.timeIntervalSince(now) < 7 * 86_400 { return formatter("EEE HH:mm", calendar).string(from: date) }
        return formatter("d MMM", calendar).string(from: date)
    }

    public static func asOfLabel(_ date: Date, calendar: Calendar = .current) -> String {
        "as of " + formatter("HH:mm", calendar).string(from: date)
    }

    /// ⌘P's one line. `as of` is added only when the reading is over an hour old.
    public static func paletteText(_ r: CapacityReading, now: Date, calendar: Calendar = .current) -> (text: String, low: Bool) {
        switch r.state {
        case .notRead: return ("not read yet", false)
        case .noLimits: return ("no limits", false)
        case .error: return ("capacity unreadable", false)
        case .read: break
        }
        var parts: [String] = []
        var low = false
        for (name, window) in [("5h", r.fiveHour), ("week", r.sevenDay), ("month", r.month)] {
            guard let window else { continue }
            if hasReset(window, now: now) {
                parts.append("\(name) reset")
            } else {
                parts.append("\(name) \(window.percentLeft)%")
                low = low || isLow(window)
            }
        }
        if let asOf = r.asOf, now.timeIntervalSince(asOf) > 3_600 {
            parts.append(asOfLabel(asOf, calendar: calendar))
        }
        return (parts.joined(separator: " · "), low)
    }
}
