import Foundation

/// One all-day item's position in the strip above the week: which row and which day columns.
public struct AllDaySpan<ID: Hashable & Sendable>: Hashable, Sendable {
    public var id: ID
    public var row: Int
    /// Index into the `days` passed to `AllDayLayout.rows`, inclusive on both ends.
    public var startDayIndex: Int
    public var endDayIndex: Int

    public init(id: ID, row: Int, startDayIndex: Int, endDayIndex: Int) {
        self.id = id
        self.row = row
        self.startDayIndex = startDayIndex
        self.endDayIndex = endDayIndex
    }

    public var dayCount: Int { endDayIndex - startDayIndex + 1 }
}

public enum AllDayLayout {
    /// Greedy row packer for the all-day strip. Each item covers the days it touches (clamped to
    /// `days`) and takes the first row where all of those day slots are free. Items are placed by
    /// first day, then longer first. The outer array is indexed by row; each row is sorted by start
    /// day. Items touching none of `days` are dropped.
    public static func rows<ID: Hashable & Sendable>(
        _ items: [LayoutItem<ID>], days: [Date], calendar: Calendar
    ) -> [[AllDaySpan<ID>]] {
        guard !days.isEmpty else { return [] }
        let dayStarts = days.map { calendar.startOfDay(for: $0) }
        let dayEnds = dayStarts.map { calendar.date(byAdding: .day, value: 1, to: $0) ?? $0.addingTimeInterval(86_400) }

        var spans: [SpannedItem<ID>] = []
        for (order, item) in items.enumerated() {
            // A zero-length item still covers the day it starts on.
            let end = max(item.end, item.start.addingTimeInterval(1))
            var first: Int?
            var last: Int?
            for index in dayStarts.indices where item.start < dayEnds[index] && end > dayStarts[index] {
                if first == nil { first = index }
                last = index
            }
            if let first, let last {
                spans.append(SpannedItem(id: item.id, first: first, last: last, order: order))
            }
        }

        spans.sort { a, b in
            if a.first != b.first { return a.first < b.first }
            if a.last != b.last { return a.last > b.last }
            return a.order < b.order
        }

        var occupied: [[Bool]] = []
        var rows: [[AllDaySpan<ID>]] = []
        for span in spans {
            var row = 0
            while row < occupied.count, occupied[row][span.first...span.last].contains(true) {
                row += 1
            }
            if row == occupied.count {
                occupied.append(Array(repeating: false, count: dayStarts.count))
                rows.append([])
            }
            for index in span.first...span.last {
                occupied[row][index] = true
            }
            rows[row].append(AllDaySpan(id: span.id, row: row, startDayIndex: span.first, endDayIndex: span.last))
        }

        return rows
    }
}

private struct SpannedItem<ID: Hashable & Sendable> {
    var id: ID
    var first: Int
    var last: Int
    var order: Int
}
