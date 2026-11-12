import Foundation

extension Availability {
    public static func text(
        _ ranges: [AvailabilityRange], timeZone: TimeZone, recipientTimeZone: TimeZone? = nil
    ) -> String {
        let ranges = merge(ranges)
        guard !ranges.isEmpty else { return "" }
        let primary = formatted(ranges, timeZone: timeZone)
        guard let recipientTimeZone, recipientTimeZone != timeZone else {
            return primary.needsIdentifier
                ? "\(timeZone.identifier):\n\(primary.lines.joined(separator: "\n"))"
                : primary.lines.joined(separator: "\n")
        }
        let recipient = formatted(ranges, timeZone: recipientTimeZone)
        return "\(timeZone.identifier):\n\(primary.lines.joined(separator: "\n"))\n\n"
            + "\(recipientTimeZone.identifier):\n\(recipient.lines.joined(separator: "\n"))"
    }

    private static func formatted(
        _ ranges: [AvailabilityRange], timeZone: TimeZone
    ) -> (lines: [String], needsIdentifier: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = DateFormatter()
        day.calendar = calendar
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "EEE, MMM d, yyyy"
        let time = DateFormatter()
        time.calendar = calendar
        time.locale = day.locale
        time.timeZone = timeZone
        time.dateFormat = "h:mm"
        let zone = DateFormatter()
        zone.calendar = calendar
        zone.locale = day.locale
        zone.timeZone = timeZone
        zone.dateFormat = "z"
        let clearLabels: Set<String> = [
            "UTC", "GMT", "PST", "PDT", "MST", "MDT", "EST", "EDT", "HST", "AKST", "AKDT",
            "JST", "KST", "CET", "CEST", "EET", "EEST", "NZST", "NZDT",
        ]
        var needsIdentifier = false
        func offsetLabel(_ date: Date) -> String {
            let offset = timeZone.secondsFromGMT(for: date)
            return String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) / 60 % 60)
        }
        let lines = ranges.map { range in
            let startPeriod = calendar.component(.hour, from: range.start) < 12 ? "AM" : "PM"
            let endPeriod = calendar.component(.hour, from: range.end) < 12 ? "AM" : "PM"
            let sameDay = calendar.isDate(range.start, inSameDayAs: range.end)
            let sameOffset = timeZone.secondsFromGMT(for: range.start) == timeZone.secondsFromGMT(for: range.end)
            var startZone = zone.string(from: range.start)
            var endZone = zone.string(from: range.end)
            if !clearLabels.contains(startZone) || !clearLabels.contains(endZone) { needsIdentifier = true }
            if startZone.isEmpty { startZone = offsetLabel(range.start) }
            if endZone.isEmpty { endZone = offsetLabel(range.end) }
            if !sameOffset && startZone == endZone {
                startZone += " (\(offsetLabel(range.start)))"
                endZone += " (\(offsetLabel(range.end)))"
            }
            var start = "\(day.string(from: range.start)): \(time.string(from: range.start))"
            let end = "\(time.string(from: range.end)) \(endPeriod) \(endZone)"
            if !sameDay || !sameOffset || startPeriod != endPeriod { start += " \(startPeriod)" }
            if !sameOffset { start += " \(startZone)" }
            if !sameDay { return "\(start) – \(day.string(from: range.end)): \(end)" }
            return "\(start)–\(end)"
        }
        return (lines, needsIdentifier)
    }
}
