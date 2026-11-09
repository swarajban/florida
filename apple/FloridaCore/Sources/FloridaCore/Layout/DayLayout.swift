import Foundation

/// Anything drawn as a block on the day grid: a Google event or a scheduler placement.
public struct LayoutItem<ID: Hashable & Sendable>: Hashable, Sendable {
    public var id: ID
    public var start: Date
    public var end: Date
    /// An all-day event's dates as the server stores them (UTC midnights, see `AllDayDate`).
    /// `AllDayLayout` maps them to local days; the timed layout ignores the flag.
    public var allDay: Bool

    public init(id: ID, start: Date, end: Date, allDay: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.allDay = allDay
    }
}

/// Where one item is drawn within a day column.
public struct LayoutFrame<ID: Hashable & Sendable>: Hashable, Sendable {
    public var id: ID
    /// 0-based column within its overlap cluster and the cluster's column count:
    /// x = column / columnCount of the day width.
    public var column: Int
    public var columnCount: Int
    /// Wall-clock minutes from the start of the day, clamped to [0, 1440].
    public var startMinute: Int
    public var endMinute: Int

    public init(id: ID, column: Int, columnCount: Int, startMinute: Int, endMinute: Int) {
        self.id = id
        self.column = column
        self.columnCount = columnCount
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public var durationMinutes: Int { endMinute - startMinute }
}

public enum DayLayout {
    public static let minutesPerDay = 1440

    /// Assigns columns to overlapping items the way Google Calendar / Fantastical do: items are
    /// sorted by start, then longer first; items that transitively overlap form a cluster; within a
    /// cluster each item takes the lowest column whose last item ended at or before it starts; every
    /// item in the cluster gets the cluster's column count.
    ///
    /// `day` is any instant in the day being laid out (normalized to its local midnight). Minutes
    /// are wall-clock, so on DST days a 9:00 event sits on the 9:00 line. Items crossing midnight are
    /// clamped to [0, 1440]; items entirely outside the day are dropped. Items shorter than
    /// `minimumMinutes` are treated as that long for overlap and height. The result is in drawing
    /// order (by start, then longer first).
    public static func layout<ID: Hashable & Sendable>(
        _ items: [LayoutItem<ID>], day: Date, calendar: Calendar, minimumMinutes: Int = 15
    ) -> [LayoutFrame<ID>] {
        let dayStart = calendar.startOfDay(for: day)
        // Where DST skips midnight the day starts at 01:00 and adding a day keeps that wall-clock
        // time; `startOfDay` again lands on the next day's first instant.
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let dayEnd = calendar.startOfDay(for: nextDay)
        let minimum = max(0, minimumMinutes)

        var timed: [TimedItem<ID>] = []
        for (order, item) in items.enumerated() {
            let itemEnd = max(item.start, item.end)
            // Keep items that start inside the day, or started earlier and are still running at midnight.
            guard item.start < dayEnd, item.start >= dayStart || itemEnd > dayStart else { continue }
            var start = minute(of: item.start, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
            var end = minute(of: itemEnd, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
            if end - start < minimum {
                end = min(minutesPerDay, start + minimum)
                start = max(0, end - minimum)
            }
            timed.append(TimedItem(id: item.id, start: start, end: end, order: order))
        }

        timed.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.duration != b.duration { return a.duration > b.duration }
            return a.order < b.order
        }

        var frames: [LayoutFrame<ID>] = []
        frames.reserveCapacity(timed.count)
        var clusterFirstIndex = 0
        var clusterEnd = 0
        /// End minute of the last item placed in each column of the current cluster.
        var columnEnds: [Int] = []

        func finishCluster() {
            for index in clusterFirstIndex..<frames.count {
                frames[index].columnCount = columnEnds.count
            }
        }

        for item in timed {
            if columnEnds.isEmpty || item.start >= clusterEnd {
                finishCluster()
                clusterFirstIndex = frames.count
                columnEnds.removeAll(keepingCapacity: true)
                clusterEnd = item.end
            } else {
                clusterEnd = max(clusterEnd, item.end)
            }

            let column: Int
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                column = free
            } else {
                column = columnEnds.count
                columnEnds.append(0)
            }
            columnEnds[column] = item.end

            frames.append(LayoutFrame(id: item.id, column: column, columnCount: 0, startMinute: item.start, endMinute: item.end))
        }
        finishCluster()

        return frames
    }

    /// Wall-clock minutes since midnight, clamped to the day.
    static func minute(of date: Date, dayStart: Date, dayEnd: Date, calendar: Calendar) -> Int {
        if date <= dayStart { return 0 }
        if date >= dayEnd { return minutesPerDay }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private struct TimedItem<ID: Hashable & Sendable> {
    var id: ID
    var start: Int
    var end: Int
    var order: Int

    var duration: Int { end - start }
}
