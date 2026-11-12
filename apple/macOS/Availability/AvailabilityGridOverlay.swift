import FloridaKit
import SwiftUI

struct AvailabilityGridOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let share = model.availabilityShare
        let days = model.visibleDays
        let calendar = model.calendar
        let flexible = model.placements.filter {
            !$0.pinned && model.tasksById[$0.taskId]?.isOpen == true && model.tasksById[$0.taskId]?.pinnedStart == nil
        }
        Canvas { context, size in
            guard let share else { return }
            let geometry = GridGeometry(
                size: size, gutterWidth: CalendarGridView.gutterWidth, dayCount: days.count,
                grid: CalendarGridView.grid)
            for (index, day) in days.enumerated() {
                guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                func minute(_ date: Date) -> Int {
                    let parts = calendar.dateComponents([.hour, .minute], from: date)
                    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }
                func rect(_ range: AvailabilityRange) -> CGRect? {
                    guard range.start < end, range.end > day else { return nil }
                    return geometry.rect(
                        dayIndex: index, column: 0, columnCount: 1,
                        startMinute: range.start <= day ? 0 : minute(range.start),
                        endMinute: range.end >= end ? 1440 : minute(range.end)).insetBy(dx: 3, dy: 0)
                }
                func movesTasks(_ range: AvailabilityRange) -> Bool {
                    flexible.contains { placement in
                        placement.startAt < min(range.end, end) && placement.endAt > max(range.start, day)
                    }
                }
                for range in share.suggestions {
                    guard let frame = rect(range) else { continue }
                    let color: Color = movesTasks(range) ? .orange : .blue
                    context.stroke(Path(roundedRect: frame, cornerRadius: 4), with: .color(color.opacity(0.65)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                for range in share.selected {
                    guard let frame = rect(range) else { continue }
                    let displaced = movesTasks(range)
                    let color: Color = displaced ? .orange : .blue
                    context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(color.opacity(0.18)))
                    context.stroke(Path(roundedRect: frame, cornerRadius: 4), with: .color(color), lineWidth: 2)
                    if frame.height >= 22 {
                        let label = displaced ? "Tasks move" : "Available"
                        var clipped = context
                        clipped.clip(to: Path(frame))
                        clipped.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(color),
                                     at: CGPoint(x: frame.minX + 6, y: frame.minY + 7), anchor: .topLeading)
                    }
                }
                if let cursor = share.cursor, let frame = rect(cursor) {
                    context.stroke(Path(roundedRect: frame.insetBy(dx: 3, dy: 3), cornerRadius: 3),
                                   with: .color(.primary), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
