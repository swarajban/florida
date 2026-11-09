import FloridaKit
import SwiftUI

/// Where task blocks were before a placement change, so the grid can slide them to their new
/// slots. Keyed by `GridLayout.Block.slotKey` (task id and block number), because the scheduler
/// replaces placements wholesale and their ids do not survive a run.
struct LayoutTransition: Equatable {
    struct Slot: Equatable {
        let dayIndex: Int
        let column: Int
        let columnCount: Int
        let startMinute: Int
        let endMinute: Int
    }

    let from: [String: Slot]
    let startedAt: Date

    static let duration: TimeInterval = 0.35
}

extension GridLayout {
    /// What a layout can switch on or off for the Feel settings.
    struct Options {
        var dimsOffHours = false
        var freeGaps = false
        var accountRims = false
    }

    /// A stretch of in-schedule time with nothing on it, at least 15 minutes long.
    struct Gap: Identifiable, Hashable {
        let id: String
        let dayIndex: Int
        let startMinute: Int
        let endMinute: Int
        let start: Date
        let end: Date

        var item: ItemID { .gap(id) }
        var minutes: Int { endMinute - startMinute }
    }

    static let minimumGapMinutes = 15

    /// A steady hue per Google account, so every calendar of one account shares a rim color.
    static func rimColor(accountId: String) -> Color {
        // FNV-1a: `hashValue` is seeded per launch.
        var hash: UInt32 = 2_166_136_261
        for byte in accountId.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.65, brightness: 0.85)
    }

    /// `working` from now on: nothing on past days, today's ranges from the next 5-minute mark.
    static func upcoming(_ working: [Range<Int>], on day: Date, now: Date, calendar: Calendar) -> [Range<Int>] {
        if DateNavigation.shift(day, by: 1, calendar: calendar) <= now { return [] }
        guard day <= now else { return working }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = ((parts.hour ?? 0) * 60 + (parts.minute ?? 0) + 4) / 5 * 5
        return working.compactMap { range in
            let lower = max(range.lowerBound, minute)
            return lower < range.upperBound ? lower..<range.upperBound : nil
        }
    }

    /// One day's timed blocks and gaps for `j` / `k`, by start; a block before a gap at the same minute.
    static func timedLines(blocks: [Block], gaps: [Gap]) -> [ItemID] {
        let blockLines = blocks.enumerated().map { (minute: $0.element.startMinute, rank: $0.offset, item: $0.element.item) }
        let gapLines = gaps.enumerated().map { (minute: $0.element.startMinute, rank: blocks.count + $0.offset, item: $0.element.item) }
        return (blockLines + gapLines)
            .sorted { $0.minute != $1.minute ? $0.minute < $1.minute : $0.rank < $1.rank }
            .map(\.item)
    }

    /// The free stretches of each `working` range on one day, around `blocks`.
    static func gaps(dayIndex: Int, day: Date, working: [Range<Int>], blocks: [Block], calendar: Calendar) -> [Gap] {
        let busy = blocks.map { $0.startMinute..<$0.endMinute }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Gap] = []
        func add(_ start: Int, _ end: Int) {
            guard end - start >= minimumGapMinutes else { return }
            result.append(Gap(
                id: "\(Int(day.timeIntervalSinceReferenceDate))-\(start)", dayIndex: dayIndex,
                startMinute: start, endMinute: end,
                start: date(forMinute: start, on: day, calendar: calendar),
                end: date(forMinute: end, on: day, calendar: calendar)))
        }
        for window in working {
            var cursor = window.lowerBound
            for range in busy where range.upperBound > cursor && range.lowerBound < window.upperBound {
                add(cursor, range.lowerBound)
                cursor = max(cursor, range.upperBound)
            }
            add(cursor, window.upperBound)
        }
        return result
    }

    static func date(forMinute minute: Int, on day: Date, calendar: Calendar) -> Date {
        if minute >= DayLayout.minutesPerDay {
            return DateNavigation.shift(day, by: 1, calendar: calendar)
        }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }

    func gap(id: String) -> Gap? {
        gapsByDay.joined().first { $0.id == id }
    }

    /// The minutes `item` covers, on `day` when it is drawn there, else where it is first drawn.
    func minuteSpan(of item: ItemID, preferringDay day: Date) -> (start: Int, end: Int)? {
        let dayIndex = days.firstIndex(of: day)
        if case .gap(let id) = item, let gap = gap(id: id) {
            return (gap.startMinute, gap.endMinute)
        }
        let blocks = blocksByDay.joined().filter { $0.item == item }
        guard let block = blocks.first(where: { $0.dayIndex == dayIndex }) ?? blocks.first else { return nil }
        return (block.startMinute, block.endMinute)
    }

    /// Every task block's frame by slot, for `LayoutTransition`.
    var slotFrames: [String: LayoutTransition.Slot] {
        var slots: [String: LayoutTransition.Slot] = [:]
        for block in blocksByDay.joined() where block.isTask {
            slots[block.slotKey] = LayoutTransition.Slot(
                dayIndex: block.dayIndex, column: block.column, columnCount: block.columnCount,
                startMinute: block.startMinute, endMinute: block.endMinute)
        }
        return slots
    }
}
