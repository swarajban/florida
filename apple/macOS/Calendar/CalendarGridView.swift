import FloridaKit
import SwiftUI

/// Day / 3-day / week: headers, the all-day strip, and a scrolling `Canvas` time grid that opens
/// at 07:00 and scrolls to keep the selected block on screen. Clicks select; a double-click on a
/// block edits it (tasks) or opens its details (events). Click or drag on empty grid to compose
/// an event. Dragging an existing event moves it, keeping its length (`GridDrag`).
struct CalendarGridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(JoyPreference.currentProgress.key) private var showsProgress = true
    @State private var position = ScrollPosition(idType: Int.self, y: CalendarGridView.initialY)
    private enum DragSession {
        case idle, event, creation, availability, cancelled
    }
    @State private var dragSession: DragSession = .idle
    @GestureState private var dragIsActive = false
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
                                draft: model.gridEventDraft,
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
                    .contentShape(Rectangle())
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
                            .updating($dragIsActive) { _, active, _ in active = true }
                            .onChanged { dragChanged($0, width: geometry.size.width) }
                            .onEnded { dragEnded($0, width: geometry.size.width) })
                    .onChange(of: dragIsActive) { _, active in
                        guard !active, dragSession == .creation || dragSession == .cancelled else { return }
                        if model.gridEventDraft != nil { model.cancel() }
                        dragSession = .idle
                    }
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
        return BlockDrag.date(onDay: day, minute: Self.grid.eventStartMinute(forY: point.y), calendar: model.calendar)
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
        if let gap = geometry.gap(at: point, in: layout), !isDouble {
            clickedItem = gap.item
            model.select(gap.item, in: .calendar)
            return
        }
        let day = layout.days[dayIndex]
        let start = BlockDrag.date(onDay: day, minute: Self.grid.eventStartMinute(forY: point.y), calendar: model.calendar)
        composeEvent(on: day, start: start)
    }

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
        if dragSession == .creation {
            guard let draft = model.gridEventDraft else {
                dragSession = .cancelled
                return
            }
            updateDraft(dayIndex: draft.dayIndex, from: value.startLocation.y, to: value.location.y)
            return
        }
        var drag: GridDrag
        if let current = model.gridDrag, !current.isDropped {
            drag = current
        } else if dragSession == .idle, model.canBeginGridDrag,
                  let dayIndex = geometry.dayIndex(atX: value.startLocation.x) {
            guard let block = geometry.block(at: value.startLocation, in: layout) else {
                dragSession = .creation
                updateDraft(dayIndex: dayIndex, from: value.startLocation.y, to: value.location.y)
                return
            }
            guard let begun = model.beginDrag(on: block) else {
                dragSession = .cancelled
                return
            }
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

    private func updateDraft(dayIndex: Int, from startY: CGFloat, to endY: CGFloat) {
        let minutes = Self.grid.eventMinutes(from: startY, to: endY)
        guard minutes != model.gridEventDraft?.minutes else { return }
        let dates = Self.grid.eventDates(on: model.gridLayout.days[dayIndex], minutes: minutes, calendar: model.calendar)
        model.transitionInteraction(to: .draftingEvent(GridEventDraft(dayIndex: dayIndex, minutes: minutes, dates: dates)))
    }

    private func dragEnded(_ value: DragGesture.Value, width: CGFloat) {
        defer { dragSession = .idle }
        if dragSession == .availability {
            model.availabilityShare?.paint = nil
            return
        }
        if dragSession == .creation {
            guard model.gridEventDraft != nil else { return }
            dragChanged(value, width: width)
            guard let draft = model.gridEventDraft else { return }
            model.transitionInteraction(to: .browsing)
            composeEvent(on: model.gridLayout.days[draft.dayIndex], start: draft.dates.lowerBound, end: draft.dates.upperBound)
            return
        }
        guard dragSession == .event, model.interaction.kind == .dragging,
              let drag = model.gridDrag, !drag.isDropped else { return }
        model.drop(drag)
    }

    private func composeEvent(on day: Date, start: Date, end: Date? = nil) {
        model.focus = .calendar
        model.selectDay(day)
        model.select(nil)
        model.statusMessage = nil
        model.openNewEventEditor(start: start, end: end)
    }
}
