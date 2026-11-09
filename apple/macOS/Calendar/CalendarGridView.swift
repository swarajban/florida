import FloridaKit
import SwiftUI

/// Day / 3-day / week: headers, the all-day strip, and a scrolling `Canvas` time grid that opens
/// at 07:00 and scrolls to keep the selected block on screen. Clicks select; a double-click on a
/// block edits it (tasks) or opens its details (events); a double-click on empty grid starts a
/// quick add pinned to that slot.
struct CalendarGridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(JoyPreference.currentProgress.key) private var showsProgress = true
    @State private var position = ScrollPosition(idType: Int.self, y: CalendarGridView.initialY)
    /// The part of the 24-hour grid on screen, in grid coordinates.
    @State private var visibleRect = CGRect.zero

    static let grid = TimeGrid(hourHeight: 60, slotMinutes: 15)
    static let gutterWidth: CGFloat = 56
    static let initialHour = 7
    static let initialY = CGFloat(grid.y(forMinute: initialHour * 60))

    var body: some View {
        VStack(spacing: 0) {
            DayHeaderView(gutterWidth: Self.gutterWidth)
            Divider()
            AllDayStripView(gutterWidth: Self.gutterWidth)
            ScrollView(.vertical) {
                GeometryReader { geometry in
                    // Paused except while blocks slide; `clockNow` redraws the now line each minute.
                    TimelineView(.animation(minimumInterval: nil, paused: model.layoutTransition == nil)) { timeline in
                        TimeGridCanvas(
                            layout: model.gridLayout, selection: model.selection, selectedDay: model.selectedDay,
                            now: model.clockNow, frameDate: timeline.date, transition: model.layoutTransition,
                            showsProgress: showsProgress, calendar: model.calendar, grid: Self.grid,
                            gutterWidth: Self.gutterWidth)
                    }
                    .onTapGesture(count: 2) { point in
                        handleTap(at: point, width: geometry.size.width, isDouble: true)
                    }
                    .onTapGesture { point in
                        handleTap(at: point, width: geometry.size.width, isDouble: false)
                    }
                    .eventDetailPopover(
                        model, eventId: detailBlock == nil ? nil : model.eventDetailID,
                        anchor: .rect(.rect(detailBlock.map { gridGeometry(width: geometry.size.width).rect(for: $0) } ?? .zero)))
                }
                .frame(height: Self.grid.dayHeight)
            }
            .scrollPosition($position)
            .onAppear {
                position.scrollTo(y: Self.initialY)
            }
            .onScrollGeometryChange(for: CGRect.self) { geometry in
                geometry.visibleRect
            } action: { _, rect in
                visibleRect = rect
            }
            .onChange(of: model.selection) { _, selection in
                revealSelection(selection)
            }
            .onChange(of: model.gridScrollRequest) { _, request in
                if let request {
                    scroll(toMinute: request.minute, centered: request.centered, animated: request.animated)
                }
            }
        }
    }

    /// The timed block the open event detail points at: on the highlighted day if it spans two.
    private var detailBlock: GridLayout.Block? {
        guard let id = model.eventDetailID else { return nil }
        let layout = model.gridLayout
        let blocks = layout.blocksByDay.joined().filter { $0.item == .event(id) }
        let dayIndex = layout.days.firstIndex(of: model.selectedDay)
        return blocks.first { $0.dayIndex == dayIndex } ?? blocks.first
    }

    private func gridGeometry(width: CGFloat) -> GridGeometry {
        GridGeometry(
            size: CGSize(width: width, height: Self.grid.dayHeight), gutterWidth: Self.gutterWidth,
            dayCount: model.gridLayout.days.count, grid: Self.grid)
    }

    /// Scrolls just enough to bring the selected block or gap on the highlighted day on screen;
    /// does nothing when it is already fully visible or is not on the timed grid.
    private func revealSelection(_ selection: ItemID?) {
        guard let selection, visibleRect.height > 0,
              let span = model.gridLayout.minuteSpan(of: selection, preferringDay: model.selectedDay)
        else { return }
        let top = CGFloat(Self.grid.y(forMinute: span.start))
        let bottom = CGFloat(Self.grid.y(forMinute: span.end))
        let margin: CGFloat = 12
        if top >= visibleRect.minY + margin, bottom <= visibleRect.maxY - margin { return }
        scroll(toMinute: span.start, centered: false, animated: true)
    }

    /// Puts `minute` a third of the way down the visible grid, or in the middle when `centered`.
    private func scroll(toMinute minute: Int, centered: Bool, animated: Bool) {
        let height = visibleRect.height
        let y = CGFloat(Self.grid.y(forMinute: minute)) - height * (centered ? 0.5 : 0.3)
        let clamped = min(max(0, y), max(0, CGFloat(Self.grid.dayHeight) - height))
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                position.scrollTo(y: clamped)
            }
        } else {
            position.scrollTo(y: clamped)
        }
    }

    private func handleTap(at point: CGPoint, width: CGFloat, isDouble: Bool) {
        let layout = model.gridLayout
        let geometry = gridGeometry(width: width)
        guard let dayIndex = geometry.dayIndex(atX: point.x) else { return }
        if let block = geometry.block(at: point, in: layout) {
            model.select(block.item, in: .calendar)
            if isDouble {
                model.editSelection()
            }
            return
        }
        if !isDouble, let gap = geometry.gap(at: point, in: layout) {
            model.select(gap.item, in: .calendar)
            return
        }
        let day = layout.days[dayIndex]
        model.focus = .calendar
        model.selectDay(day)
        model.select(nil)
        if isDouble {
            let minute = Self.grid.snappedMinute(forY: point.y)
            model.openQuickAdd(prefill: Self.quickAddPrefix(day: day, minute: minute, calendar: model.calendar))
        }
    }

    /// "11/20/2026 at 2:00pm " — the forms `QuickAddParser` reads as a pinned start.
    static func quickAddPrefix(day: Date, minute: Int, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let hour24 = min(minute / 60, 23)
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let clock = String(format: "%d:%02d%@", hour12, minute % 60, hour24 < 12 ? "am" : "pm")
        return "\(components.month ?? 1)/\(components.day ?? 1)/\(components.year ?? 2000) at \(clock) "
    }
}
