import Foundation

public struct AvailabilityRange: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum Availability {
    public static let timeZoneIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    public static func routineTimeZone(_ settings: UserSettings?) -> TimeZone {
        settings.flatMap { TimeZone(identifier: $0.timeZone) } ?? .gmt
    }

    public static func eventBlocksTime(_ event: CalendarEvent) -> Bool {
        guard event.isVisible, let start = event.startAt, let end = event.endAt, start < end
        else { return false }
        if event.allDay { return AllDayBlocking.isEffective(event, calendarBlocksScheduling: true) }
        if event.eventType == "focusTime" || event.eventType == "workingLocation" { return false }
        return event.isOutOfOffice || event.transparency != "transparent"
    }

    public static func blockingRange(_ event: CalendarEvent, timeZone: TimeZone) -> AvailabilityRange? {
        guard eventBlocksTime(event), let start = event.startAt, let end = event.endAt else { return nil }
        guard event.allDay else { return AvailabilityRange(start: start, end: end) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let days = AllDayBlocking.protectedDays(for: event, calendar: calendar),
              days.lowerBound < days.upperBound else { return nil }
        return AvailabilityRange(start: days.lowerBound, end: days.upperBound)
    }

    public static func freeRanges(
        in visible: Range<Date>, schedules: [Schedule], events: [CalendarEvent], tasks: [TaskItem],
        placements: [Placement], commitments: [RoutineOccurrence], now: Date, timeZone: TimeZone? = nil
    ) -> [AvailabilityRange] {
        let lower = max(visible.lowerBound, now)
        guard lower < visible.upperBound else { return [] }
        let liveTasks = tasks.filter { $0.deletedAt == nil && $0.completedAt == nil && $0.remainingMinutes > 0 }
        let liveTaskIds = Set(liveTasks.map(\.id))
        let busyZone = timeZone ?? schedules.lazy.compactMap { TimeZone(identifier: $0.timeZone) }.first ?? .gmt
        var busy = events.compactMap { blockingRange($0, timeZone: busyZone) }
        busy += placements.filter { $0.pinned && liveTaskIds.contains($0.taskId) }.map {
            AvailabilityRange(start: $0.startAt, end: $0.endAt)
        }
        busy += liveTasks.compactMap { task in
            guard let start = task.pinnedStart else { return nil }
            return AvailabilityRange(start: start, end: start.addingTimeInterval(Double(task.remainingMinutes) * 60))
        }
        busy += commitments.map { AvailabilityRange(start: $0.startAt, end: $0.endAt) }
        busy = merge(busy)

        var windows: [(range: AvailabilityRange, timeZone: TimeZone)] = []
        for schedule in schedules where schedule.deletedAt == nil {
            guard let zone = TimeZone(identifier: schedule.timeZone) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var day = calendar.startOfDay(for: lower)
            while day < visible.upperBound {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let dayEnd = calendar.startOfDay(for: next)
                guard dayEnd > day else { break }
                let weekday = calendar.component(.weekday, from: day) - 1
                for window in schedule.windows where window.days.contains(weekday) {
                    guard let startMinute = minutes(window.start), let endMinute = minutes(window.end),
                          startMinute < endMinute,
                          let start = instant(minute: startMinute, day: day, dayEnd: dayEnd, calendar: calendar),
                          let end = instant(minute: endMinute, day: day, dayEnd: dayEnd, calendar: calendar)
                    else { continue }
                    let range = AvailabilityRange(start: max(start, lower), end: min(end, visible.upperBound))
                    if range.start < range.end { windows.append((range, zone)) }
                }
                day = dayEnd
            }
        }

        var free = merge(windows.map(\.range))
        for blocker in busy { free = subtract(free, removing: blocker) }
        return merge(free.compactMap { range in
            guard let startZone = windows.first(where: { $0.range.start <= range.start && range.start < $0.range.end })?.timeZone,
                  let endZone = windows.first(where: { $0.range.start < range.end && range.end <= $0.range.end })?.timeZone
            else { return nil }
            let start = boundary(range.start, timeZone: startZone, rounding: .up)
            let end = boundary(range.end, timeZone: endZone, rounding: .down)
            return start < end ? AvailabilityRange(start: start, end: end) : nil
        })
    }

    public static func merge(_ ranges: [AvailabilityRange]) -> [AvailabilityRange] {
        var result: [AvailabilityRange] = []
        for range in ranges.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }

    public static func subtract(_ ranges: [AvailabilityRange], removing: AvailabilityRange) -> [AvailabilityRange] {
        guard removing.start < removing.end else { return merge(ranges) }
        return merge(ranges).flatMap { range -> [AvailabilityRange] in
            guard removing.start < range.end, removing.end > range.start else { return [range] }
            var pieces: [AvailabilityRange] = []
            if range.start < removing.start {
                pieces.append(AvailabilityRange(start: range.start, end: removing.start))
            }
            if removing.end < range.end {
                pieces.append(AvailabilityRange(start: removing.end, end: range.end))
            }
            return pieces
        }
    }

    public static func toggle(_ range: AvailabilityRange, in ranges: [AvailabilityRange]) -> [AvailabilityRange] {
        let normalized = merge(ranges)
        if normalized.contains(where: { $0.start <= range.start && $0.end >= range.end }) {
            return subtract(normalized, removing: range)
        }
        return merge(normalized + [range])
    }

    public static func selection(_ ranges: [AvailabilityRange], minimumMinutes: Int) -> [AvailabilityRange] {
        merge(ranges).filter { $0.end.timeIntervalSince($0.start) >= Double(max(0, minimumMinutes)) * 60 }
    }

    public static func paintedRange(
        on day: Date, fromMinute: Int, toMinute: Int, calendar: Calendar
    ) -> AvailabilityRange {
        let grid = TimeGrid()
        let first = grid.snappedMinute(forY: Double(fromMinute))
        let last = grid.snappedMinute(forY: Double(toMinute))
        let low = min(1425, min(first, last))
        let high = max(low + 15, max(first, last))
        let start = BlockDrag.date(onDay: day, minute: low, calendar: calendar)
        let end = high == 1440
            ? calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
            : BlockDrag.date(onDay: day, minute: high, calendar: calendar)
        return AvailabilityRange(start: start, end: end)
    }

    public static func clipped(
        _ range: AvailabilityRange, to free: [AvailabilityRange], minimumMinutes: Int
    ) -> [AvailabilityRange] {
        merge(free).compactMap { available in
            let start = max(range.start, available.start)
            let end = min(range.end, available.end)
            guard start < end, end.timeIntervalSince(start) >= Double(max(0, minimumMinutes)) * 60 else { return nil }
            return AvailabilityRange(start: start, end: end)
        }
    }

    public static func snapped(_ date: Date, timeZone: TimeZone) -> Date {
        boundary(date, timeZone: timeZone, rounding: .toNearestOrAwayFromZero)
    }

    private static func boundary(_ date: Date, timeZone: TimeZone, rounding: FloatingPointRoundingRule) -> Date {
        let offset = Double(timeZone.secondsFromGMT(for: date))
        let wallSeconds = date.timeIntervalSince1970 + offset
        return Date(timeIntervalSince1970: (wallSeconds / 900).rounded(rounding) * 900 - offset)
    }

    private static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour) && (0...59).contains(minute) || hour == 24 && minute == 0
        else { return nil }
        return hour * 60 + minute
    }

    private static func instant(minute: Int, day: Date, dayEnd: Date, calendar: Calendar) -> Date? {
        if minute == 1440 { return dayEnd }
        guard let date = calendar.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first), date >= day, date <= dayEnd
        else { return nil }
        return date
    }
}
