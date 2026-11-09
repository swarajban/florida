import FloridaKit
import SwiftUI
import UIKit

/// `dayCount` is 1 or 3. Shows the days starting at `model.selectedDay`.
///
/// Headers, the all-day strip and a scrolling hour grid: a `Canvas` for the chrome with one
/// small view per block on top. Frames come from `DayGridLayout`, rebuilt only when the data
/// changes; points from `DayGridGeometry`. Tap a block to open it, tap empty grid to create
/// there, hold a block for a moment and drag to move it; a horizontal swipe shows the next or
/// previous days.
struct DayGridView: View {
    let dayCount: Int
    let onSelectEvent: (CalendarEvent) -> Void
    let onEditTask: (TaskItem) -> Void
    /// Tapping an empty slot: the caller opens a new-event editor starting there.
    let onCreateAt: (Date) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption2) private var hourHeight: CGFloat = 60
    @State private var layout = DayGridLayout()
    @State private var hourLabels = HourLabels.make(calendar: .autoupdatingCurrent)
    @State private var drag: BlockDrag?
    /// True while a block is lifted. SwiftUI resets it when the touch ends *or is cancelled* (a
    /// call banner, an edge swipe), which `onEnded` does not report.
    @GestureState private var lifting = false
    /// Set once a horizontal swipe is seen while a block is lifted, so that drag's finger does
    /// not also turn the page when it ends.
    @State private var swipeBlocked = false
    @State private var position = ScrollPosition(idType: Int.self, y: DayGridView.initialY)
    /// Height of the scrolling part; 0 until the first layout pass of the current day's grid.
    @State private var visibleHeight: CGFloat = 0
    /// Where the grid is scrolled to, carried from one day's grid to the next (the day change
    /// recreates the scroll view); nil until the user or `scrollToStart` has scrolled once.
    @State private var scrollY: CGFloat?
    /// The first day on screen; trails `model.selectedDay` by the slide, like `AgendaView`.
    @State private var shownDay: Date?
    @State private var slideDirection: CGFloat = 1

    static let gutterWidth: CGFloat = 52
    static let slotMinutes = 15
    static let longPressDuration: TimeInterval = 0.3

    /// Where the grid opens before its height is known: the current hour, a little above the
    /// middle, at the default hour height. The first layout pass corrects it (`scrollToStart`).
    static var initialY: CGFloat {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: Date())
        let minute = (components.hour ?? 8) * 60 + (components.minute ?? 0)
        return max(0, CGFloat(TimeGrid(hourHeight: 60, slotMinutes: slotMinutes).y(forMinute: minute)) - 200)
    }

    private var grid: TimeGrid {
        TimeGrid(hourHeight: Double(hourHeight), slotMinutes: Self.slotMinutes)
    }

    /// The local midnights on screen.
    private var days: [Date] {
        AppModel.gridDays(from: shownDay ?? model.selectedDay, dayCount: dayCount, calendar: model.calendar)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = DayGridGeometry(
                width: proxy.size.width, gutterWidth: Self.gutterWidth, dayCount: dayCount, grid: grid)
            ZStack {
                gridContent(geometry: geometry, days: days)
                    .id(shownDay ?? model.selectedDay)
                    .transition(slide)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FloridaStyle.paper)
        .onAppear {
            model.setGridRange(start: model.selectedDay, dayCount: dayCount)
        }
        .onDisappear {
            model.stopObservingGrid()
        }
        .onChange(of: model.selectedDay) { old, new in
            slideDirection = new > old ? 1 : -1
            model.setGridRange(start: new, dayCount: dayCount)
            // The incoming grid is a new scroll view; its first layout pass restores `scrollY`,
            // so paging while looking at 4 PM stays at 4 PM, as the Mac grid and Apple Calendar do.
            visibleHeight = 0
            withAnimation(.snappy(duration: 0.2)) {
                shownDay = new
            }
        }
        .onChange(of: lifting) { _, isLifting in
            // The touch ended without `onEnded` (cancelled by a call banner or an edge swipe):
            // put the block back and write nothing. After a normal release `drop()` has already
            // cleared `drag` by the time this runs, since `onChange` fires on the next render.
            guard !isLifting, drag != nil else { return }
            withAnimation(.snappy(duration: 0.2)) {
                drag = nil
            }
            swipeBlocked = false
        }
        .onChange(of: dayCount) { _, count in
            model.setGridRange(start: model.selectedDay, dayCount: count)
        }
        .onChange(of: inputs, initial: true) { _, inputs in
            layout = DayGridLayout.build(
                days: inputs.days, agendas: inputs.agendas, ghosts: inputs.ghosts, blooming: inputs.blooming,
                minimumMinutes: inputs.minimumMinutes, calendar: model.calendar,
                eventStyle: { EventStyle(event: $0, calendars: inputs.calendars, accounts: inputs.accounts) },
                categoryTint: { id in Color.category(inputs.categories.first { $0.id == id }) })
        }
        .onChange(of: locale) { _, _ in
            hourLabels = HourLabels.make(calendar: model.calendar)
        }
        .simultaneousGesture(swipe)
    }

    // MARK: - Content

    @ViewBuilder
    private func gridContent(geometry: DayGridGeometry, days: [Date]) -> some View {
        TimelineView(.everyMinute) { timeline in
            VStack(spacing: 0) {
                DayGridHeader(days: days, today: model.today, gutterWidth: Self.gutterWidth, calendar: model.calendar)
                Divider()
                if layout.allDayRowCount > 0 {
                    DayGridAllDayStrip(layout: layout, geometry: geometry, now: timeline.date, onSelect: onSelectEvent)
                    Divider()
                }
                ScrollView(.vertical) {
                    timedGrid(geometry: geometry, days: days, now: timeline.date)
                }
                .scrollPosition($position)
                .scrollDisabled(drag != nil)
                .onScrollGeometryChange(for: ScrollSnapshot.self) { scroll in
                    ScrollSnapshot(height: scroll.containerSize.height, y: scroll.contentOffset.y)
                } action: { _, scroll in
                    let firstLayout = visibleHeight == 0
                    visibleHeight = scroll.height
                    guard firstLayout else {
                        scrollY = scroll.y
                        return
                    }
                    // A fresh scroll view starts at the top; put it back where the previous
                    // day's grid was, or at now / 08:00 the very first time.
                    if let scrollY {
                        position.scrollTo(y: scrollY)
                    } else {
                        scrollToStart(days: days)
                    }
                }
            }
        }
    }

    private func timedGrid(geometry: DayGridGeometry, days: [Date], now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            DayGridCanvas(geometry: geometry, days: days, hourLabels: hourLabels, now: now, calendar: model.calendar)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    create(at: point, geometry: geometry, days: days)
                }
            ForEach(layout.blocks) { block in
                let rect = geometry.rect(for: block)
                DayGridBlockView(
                    block: block, timeText: block.timeText, showsTime: rect.height >= geometry.timeTextHeight,
                    isPast: block.end <= now)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(drag?.block.id == block.id ? 0.3 : 1)
                    .onTapGesture {
                        open(block)
                    }
                    .gesture(moveGesture(for: block, geometry: geometry, days: days))
            }
            if let drag {
                let rect = drag.rect(in: geometry)
                DayGridBlockView(
                    block: drag.block, timeText: drag.timeText, showsTime: rect.height >= geometry.timeTextHeight,
                    isPast: false, isLifted: true)
                    .frame(width: rect.width, height: rect.height)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .scaleEffect(1.03)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                    .animation(.snappy(duration: 0.12), value: drag)
            }
        }
        .frame(width: geometry.width, height: geometry.dayHeight, alignment: .topLeading)
        .animation(.snappy(duration: 0.25), value: layout.blocks)
    }

    /// What the layout is built from. Compared on every body evaluation (a few dozen small
    /// values), rebuilt only when something in it changed.
    private struct Inputs: Equatable {
        var days: [Date]
        var agendas: [DayAgenda]
        var ghosts: [GhostBlock]
        var blooming: Set<String>
        var categories: [TaskCategory]
        var calendars: [CalendarInfo]
        var accounts: [GoogleAccount]
        var minimumMinutes: Int
    }

    private var inputs: Inputs {
        Inputs(
            days: days, agendas: model.gridDays,
            // Today's finished blocks, on whichever column today is (`visibleGhosts` assumes the
            // selected day is today, which a 3-day grid opened on yesterday breaks).
            ghosts: JoySetting.ghosts.isOn ? model.ghostBlocks : [],
            blooming: Set(model.blooming.keys), categories: model.categories, calendars: model.calendars,
            accounts: model.accounts, minimumMinutes: DayGridGeometry.minimumMinutes(for: grid))
    }

    // MARK: - Scrolling

    private struct ScrollSnapshot: Equatable {
        var height: CGFloat
        var y: CGFloat
    }

    /// Puts the now line (today on screen) or 08:00 a third of the way down the visible grid.
    private func scrollToStart(days: [Date]) {
        guard visibleHeight > 0 else { return }
        let minute: Int
        if days.contains(model.today) {
            let components = model.calendar.dateComponents([.hour, .minute], from: Date())
            minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        } else {
            minute = 8 * 60
        }
        let y = CGFloat(grid.y(forMinute: minute)) - visibleHeight * 0.3
        let clamped = min(max(0, y), max(0, CGFloat(grid.dayHeight) - visibleHeight))
        position.scrollTo(y: clamped)
    }

    // MARK: - Day change

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 24 * slideDirection).combined(with: .opacity),
            removal: .offset(x: -24 * slideDirection).combined(with: .opacity))
    }

    /// Clear horizontal intent (the rule `AgendaView`'s list uses) turns the page by `dayCount`
    /// days. Runs alongside the scroll view's pan and the blocks' gestures; a swipe seen while a
    /// block is lifted belongs to that drag and is ignored when it ends.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { _ in
                if drag != nil, !swipeBlocked {
                    swipeBlocked = true
                }
            }
            .onEnded { value in
                let blocked = swipeBlocked
                swipeBlocked = false
                guard !blocked, drag == nil else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                model.shiftDay(by: dx < 0 ? dayCount : -dayCount)
            }
    }

    // MARK: - Taps

    private func open(_ block: DayGridLayout.Block) {
        switch block.item {
        case .event(let event):
            onSelectEvent(event)
        case .task(let scheduled):
            onEditTask(scheduled.task)
        case .ghost(let ghost):
            if let task = model.task(id: ghost.taskId) {
                onEditTask(task)
            }
        }
    }

    private func create(at point: CGPoint, geometry: DayGridGeometry, days: [Date]) {
        guard drag == nil, let dayIndex = geometry.dayIndex(atX: point.x), days.indices.contains(dayIndex) else { return }
        let minute = geometry.slotMinute(atY: point.y)
        onCreateAt(DayGridLayout.date(forMinute: minute, on: days[dayIndex], calendar: model.calendar))
    }

    // MARK: - Moving blocks

    /// Hold for `longPressDuration`, then drag. Before the hold completes the scroll view owns
    /// any movement (a finger that travels first scrolls, a quick tap opens); once it completes
    /// the block lifts, scrolling is disabled for the rest of the touch, and the drag's
    /// translation moves the block in whole slots across the columns.
    private func moveGesture(for block: DayGridLayout.Block, geometry: DayGridGeometry, days: [Date]) -> some Gesture {
        LongPressGesture(minimumDuration: Self.longPressDuration, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($lifting) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                switch value {
                case .second(true, nil):
                    lift(block, geometry: geometry)
                case .second(true, let move?):
                    follow(move.translation, geometry: geometry, days: days)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let move) = value, let move {
                    follow(move.translation, geometry: geometry, days: days)
                }
                drop()
            }
    }

    private func lift(_ block: DayGridLayout.Block, geometry: DayGridGeometry) {
        guard block.canMove, drag == nil else { return }
        // A read-only calendar's event never lifts: the toast says why instead of a block that
        // follows the finger and then snaps back.
        if case .event(let event) = block.item, !model.requireEditable(event) { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy(duration: 0.15)) {
            drag = BlockDrag(block: block, homeRect: geometry.rect(for: block))
        }
    }

    private func follow(_ translation: CGSize, geometry: DayGridGeometry, days: [Date]) {
        guard var current = drag else { return }
        if current.move(by: translation, geometry: geometry, days: days, calendar: model.calendar) {
            drag = current
        }
    }

    /// Tasks are pinned at the new start (the scheduler keeps them there); events keep their
    /// duration and move only when the calendar lets us write, otherwise the block snaps back.
    private func drop() {
        guard let current = drag else { return }
        withAnimation(.snappy(duration: 0.2)) {
            drag = nil
        }
        guard current.hasMoved else { return }
        switch current.block.item {
        case .task(let scheduled):
            model.pin(scheduled.task, at: current.start)
        case .event(let event):
            guard model.canEdit(event) else { return }
            model.reschedule(event, start: current.start, end: current.end)
        case .ghost:
            break
        }
    }
}
