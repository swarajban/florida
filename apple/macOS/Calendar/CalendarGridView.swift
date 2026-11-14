import FloridaKit
import SwiftUI

/// Day / 3-day / week: headers, the all-day strip, and a scrolling `Canvas` time grid that opens
/// at 07:00 and scrolls to keep the selected block on screen. Clicks select; a double-click on a
/// block edits it (tasks) or opens its details (events); a double-click on empty grid starts a
/// quick add pinned to that slot. Dragging an event moves it, in quarter hours and across days,
/// keeping its length (`GridDrag`).
struct CalendarGridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(JoyPreference.currentProgress.key) private var showsProgress = true
    @State private var position = ScrollPosition(idType: Int.self, y: CalendarGridView.initialY)
    private enum DragSession {
        case idle, event, availability, cancelled
    }
    @State private var dragSession: DragSession = .idle
    /// What the last click in the grid selected, until the selection change it caused is handled.
    @State private var clickedItem: ItemID?
    @State private var eventStart: Date?

    static let grid = TimeGrid(hourHeight: 60, slotMinutes: 15)
    static let gutterWidth: CGFloat = 56
    static let initialHour = 7
    static let initialY = CGFloat(grid.y(forMinute: initialHour * 60))

    var body: some View {
        VStack(spacing: 0) {
            DayHeaderView(gutterWidth: Self.gutterWidth)
                .disabled(model.availabilityShare != nil)
                .allowsHitTesting(model.availabilityShare == nil)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("calendar-day-headers")
            Divider()
            AllDayStripView(gutterWidth: Self.gutterWidth)
                .disabled(model.availabilityShare != nil)
            ScrollView(.vertical) {
                GeometryReader { geometry in
                    // Paused except while blocks slide; `clockNow` redraws the now line each minute.
                    ZStack {
                        TimelineView(.animation(minimumInterval: nil, paused: model.layoutTransition == nil)) { timeline in
                            TimeGridCanvas(
                                layout: model.gridLayout, selection: model.selection,
                                jumpLabels: model.jump?.remaining ?? [:],
                                jumpViewport: model.jump == nil ? nil : model.jumpGridViewport, drag: model.gridDrag,
                                selectedDay: model.selectedDay,
                                now: model.clockNow, frameDate: timeline.date, transition: model.layoutTransition,
                                showsProgress: showsProgress, calendar: model.calendar, hourLabels: model.hourLabels,
                                grid: Self.grid, gutterWidth: Self.gutterWidth)
                        }
                        if model.availabilityShare != nil {
                            AvailabilityGridOverlay()
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("calendar-time-grid")
                    .onClickAt { point, isDouble in
                        handleTap(at: point, width: geometry.size.width, isDouble: isDouble)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Calendar time grid")
                    .accessibilityIdentifier("calendar-time-grid")
                    .onContinuousHover { phase in
                        if case .active(let point) = phase {
                            let start = newEventStart(at: point, width: geometry.size.width)
                            if eventStart != start {
                                eventStart = start
                            }
                        }
                    }
                    .contextMenu {
                        if let eventStart {
                            Button("New Event…") {
                                model.openNewEventEditor(start: eventStart)
                            }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { dragChanged($0, width: geometry.size.width) }
                            .onEnded { _ in dragEnded() })
                    .eventDetailPopover(
                        model, eventId: detailBlock == nil ? nil : model.eventDetailID,
                        anchor: .rect(.rect(detailBlock.map { gridGeometry(width: geometry.size.width).rect(for: $0) } ?? .zero)))
                }
                .frame(height: Self.grid.dayHeight)
            }
            .scrollPosition($position)
            .onAppear {
                model.gridScrollTarget = nil
                position.scrollTo(y: Self.initialY)
            }
            .onScrollGeometryChange(for: CGRect.self) { geometry in
                geometry.visibleRect
            } action: { old, rect in
                model.gridVisibleRect = rect
                if old.height != rect.height, model.availabilityShare != nil {
                    model.revealAvailabilityCursor()
                }
                if let target = model.gridScrollTarget, abs(rect.minY - target) < 0.5 {
                    model.gridScrollTarget = nil
                }
            }
            .onScrollPhaseChange { _, phase in
                // A scroll by hand takes over from one a key started, which then never arrives.
                if phase != .animating { model.gridScrollTarget = nil }
            }
            .onChange(of: model.selection) { _, selection in
                // What a click selected is under the pointer already. Scrolling to it would put
                // something else there before the second click of a double-click lands.
                let clicked = clickedItem
                clickedItem = nil
                if selection != clicked { revealSelection(selection) }
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

    private func newEventStart(at point: CGPoint, width: CGFloat) -> Date? {
        guard let dayIndex = gridGeometry(width: width).dayIndex(atX: point.x) else { return nil }
        let day = model.gridLayout.days[dayIndex]
        let minute = Self.grid.snappedMinute(forY: point.y)
        return model.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }

    /// Scrolls just enough to bring the selected block or gap on the highlighted day on screen;
    /// does nothing when it is already fully visible or is not on the timed grid.
    private func revealSelection(_ selection: ItemID?) {
        let visibleRect = model.gridVisibleRect
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
        let height = model.gridVisibleRect.height
        let y = CGFloat(Self.grid.y(forMinute: minute)) - height * (centered ? 0.5 : 0.3)
        let clamped = min(max(0, y), max(0, CGFloat(Self.grid.dayHeight) - height))
        if animated {
            // Jump mode reads the target: `f` pressed while this runs labels what it will show.
            // The target is cleared when the grid gets there (`onScrollGeometryChange`).
            model.gridScrollTarget = abs(clamped - model.gridVisibleRect.minY) < 0.5 ? nil : clamped
            withAnimation(.easeInOut(duration: 0.25)) {
                position.scrollTo(y: clamped)
            }
        } else {
            model.gridScrollTarget = nil
            position.scrollTo(y: clamped)
        }
    }

    private func handleTap(at point: CGPoint, width: CGFloat, isDouble: Bool) {
        let layout = model.gridLayout
        let geometry = gridGeometry(width: width)
        guard let dayIndex = geometry.dayIndex(atX: point.x) else { return }
        if model.availabilityShare != nil {
            model.tapAvailability(day: layout.days[dayIndex], minute: Self.grid.snappedMinute(forY: point.y))
            return
        }
        if let block = geometry.block(at: point, in: layout) {
            if model.jumpLabel(for: block.item) != nil {
                model.selectJumped(block.item)
                return
            }
            clickedItem = block.item
            model.select(block.item, in: .calendar)
            if isDouble {
                model.editSelection()
            }
            return
        }
        if !isDouble, let gap = geometry.gap(at: point, in: layout) {
            clickedItem = gap.item
            model.select(gap.item, in: .calendar)
            return
        }
        let day = layout.days[dayIndex]
        model.focus = .calendar
        model.selectDay(day)
        // The status bar's note was about the block this click deselects.
        model.statusMessage = nil
        model.select(nil)
        if isDouble {
            let minute = Self.grid.snappedMinute(forY: point.y)
            model.openQuickAdd(prefill: Self.quickAddPrefix(day: day, minute: minute, calendar: model.calendar))
        }
    }

    /// A drag in the grid: begins on the block under the point where the button went down, then
    /// follows the pointer by slots and day columns. The model is told only when the slot
    /// changes, so the canvas redraws a few times per drag, not once per pointer event.
    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        guard dragSession != .cancelled else { return }
        if dragSession == .event, model.interaction.kind != .dragging {
            dragSession = .cancelled
            return
        }
        if dragSession == .availability, model.availabilityShare == nil {
            dragSession = .cancelled
            return
        }
        if model.availabilityShare != nil {
            dragSession = .availability
            let geometry = gridGeometry(width: width)
            guard let index = geometry.dayIndex(atX: value.startLocation.x) else { return }
            model.paintAvailability(
                day: model.gridLayout.days[index], startMinute: Self.grid.snappedMinute(forY: value.startLocation.y),
                endMinute: Self.grid.snappedMinute(forY: value.location.y))
            return
        }
        let layout = model.gridLayout
        let geometry = gridGeometry(width: width)
        var drag: GridDrag
        if let current = model.gridDrag, !current.isDropped {
            drag = current
        } else if dragSession == .idle, model.canBeginGridDrag,
                  let begun = model.beginDrag(on: geometry.block(at: value.startLocation, in: layout)) {
            drag = begun
            model.gridDrag = begun
            dragSession = .event
        } else {
            dragSession = .cancelled
            return
        }
        let minute = BlockDrag(startMinute: drag.block.startMinute, durationMinutes: drag.durationMinutes)
            .startMinute(movedBy: value.translation.height, grid: Self.grid)
        // Past either side of the grid the block stays in the nearest day.
        let dayIndex = geometry.dayIndex(atX: value.location.x)
            ?? (value.location.x < Self.gutterWidth ? 0 : layout.days.count - 1)
        guard minute != drag.startMinute || dayIndex != drag.dayIndex else { return }
        drag.move(toDay: dayIndex, minute: minute, days: layout.days, calendar: model.calendar)
        model.gridDrag = drag
    }

    private func dragEnded() {
        defer { dragSession = .idle }
        if dragSession == .availability {
            model.availabilityShare?.paint = nil
            return
        }
        guard dragSession == .event, model.interaction.kind == .dragging,
              let drag = model.gridDrag, !drag.isDropped else { return }
        model.drop(drag)
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
