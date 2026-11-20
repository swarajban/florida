import FloridaKit
import SwiftUI
import UIKit

/// `dayCount` is 1 or 3. Shows the days starting at `model.selectedDay`.
///
/// Column headers (three days only), the all-day strip and a scrolling hour grid: a `Canvas` for
/// the chrome with one small view per block on top. Frames come from `DayGridLayout`, rebuilt
/// only when the data changes; points from `DayGridGeometry`. Tap a block to open it, tap empty
/// grid to create there, hold a block for a moment and drag to move it (`BlockMoveGesture`); a
/// horizontal scrolling tracks the finger and snaps by day in both grid modes.
/// Plan blocks stay where the scheduler put them: no hold, no drag.
struct DayGridView: View {
    let dayCount: Int
    let showTasksOnCalendar: Bool
    let onSelectEvent: (CalendarEvent) -> Void
    let onEditTask: (TaskItem) -> Void
    /// Tapping an empty slot: the caller opens a new-event editor starting there.
    let onCreateAt: (Date) -> Void
    /// Tapping a plan block: the gym (`PlanBlock.Kind.commitment`) or project time
    /// (`.project(projectId:)`). Nothing happens until a caller passes this, for example to open
    /// the project's editor.
    var onSelectPlanBlock: (PlanBlock) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption2) private var hourHeight: CGFloat = 60
    @State private var layout = DayGridLayout()
    @State private var hourLabels = HourLabels.make(calendar: .autoupdatingCurrent)
    @State private var drag: BlockDrag?
    /// The suggestion whose block was tapped; its dialog offers to take it.
    @State private var takingSuggestion: OptionalPicks.Pick?
    @State private var position = ScrollPosition(idType: Int.self, y: DayGridView.initialY)
    /// Height of the scrolling part; 0 until the first layout pass of the current day's grid.
    @State private var visibleHeight: CGFloat = 0
    @State private var scrollY: CGFloat?
    @State private var carouselStart: Date?
    @State private var horizontalPosition = ScrollPosition(idType: Int.self)
    @State private var horizontalOffset: CGFloat = 0
    @State private var isPanningDays = false

    static let gutterWidth: CGFloat = 52
    static let slotMinutes = 15
    /// Preloaded local days on each side; replenished at rest, never during a finger's movement.
    private static let carouselPadding = 7
    /// A plan block narrower than this (one sharing its time in a three-day grid) drops its
    /// symbol and keeps the width for its title.
    static let planSymbolWidth: CGFloat = 72

    /// Where the grid opens before its height is known: the current hour, a little above the
    /// middle, at the default hour height. The first layout pass corrects it (`scrollToStart`).
    static var initialY: CGFloat {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: AppModel.currentTime)
        let minute = (components.hour ?? 8) * 60 + (components.minute ?? 0)
        return max(0, CGFloat(TimeGrid(hourHeight: 60, slotMinutes: slotMinutes).y(forMinute: minute)) - 200)
    }

    private var grid: TimeGrid {
        TimeGrid(hourHeight: Double(hourHeight), slotMinutes: Self.slotMinutes)
    }

    private var days: [Date] {
        let start = carouselStart ?? DateNavigation.shift(model.selectedDay, by: -Self.carouselPadding, calendar: model.calendar)
        return AppModel.gridDays(from: start, dayCount: dayCount + 2 * Self.carouselPadding, calendar: model.calendar)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = DayGridGeometry(
                width: proxy.size.width, gutterWidth: Self.gutterWidth, dayCount: dayCount, grid: grid)
            carousel(geometry: geometry, height: proxy.size.height)
                .id(dayCount)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(FloridaStyle.paper)
        .onAppear {
            carouselStart = days.first
            observeDays()
        }
        .onDisappear {
            model.stopObservingGrid()
        }
        .onChange(of: model.todayRequests) { _, _ in
            scrollY = nil
            withAnimation(.snappy(duration: 0.3)) {
                scrollToStart()
            }
        }
        .onChange(of: dayCount) { _, _ in
            visibleHeight = 0
            carouselStart = DateNavigation.shift(model.selectedDay, by: -Self.carouselPadding, calendar: model.calendar)
            observeDays()
        }
        .onChange(of: inputs, initial: true) { _, inputs in
            if !inputs.showTasksOnCalendar {
                if let drag, case .task = drag.block.item { cancelDrag() }
                takingSuggestion = nil
            }
            rebuildLayout(inputs)
        }
        .onChange(of: locale) { _, _ in
            hourLabels = HourLabels.make(calendar: model.calendar)
        }
    }

    // MARK: - Content

    private func carousel(geometry: DayGridGeometry, height: CGFloat) -> some View {
        let content = DayGridGeometry(
            width: geometry.gutterWidth + CGFloat(days.count) * geometry.columnWidth,
            gutterWidth: geometry.gutterWidth, dayCount: days.count, grid: grid)
        return ScrollView(.horizontal) {
            gridContent(geometry: content, days: days)
                .frame(width: content.width, height: height)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($horizontalPosition)
        .defaultScrollAnchor(.center)
        .scrollTargetBehavior(DayColumnScrollTarget(columnWidth: geometry.columnWidth, singleDay: dayCount == 1))
        .scrollDisabled(drag != nil)
        .onAppear {
            if let index = days.firstIndex(of: model.selectedDay), index <= days.count - dayCount {
                horizontalOffset = CGFloat(index) * geometry.columnWidth
                horizontalPosition.scrollTo(x: horizontalOffset)
            } else {
                recenter(on: model.selectedDay, columnWidth: geometry.columnWidth)
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            horizontalOffset = x
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { isPanningDays = true }
            guard phase == .idle, isPanningDays else { return }
            isPanningDays = false
            guard drag == nil, geometry.columnWidth > 0 else { return }
            let index = min(max(0, Int((horizontalOffset / geometry.columnWidth).rounded())), days.count - dayCount)
            let day = days[index]
            model.select(day: day)
            if index < dayCount || index > days.count - 2 * dayCount {
                recenter(on: day, columnWidth: geometry.columnWidth)
            }
        }
        .onChange(of: model.selectedDay) { _, day in
            isPanningDays = false
            if let index = days.firstIndex(of: day), index <= days.count - dayCount {
                let x = CGFloat(index) * geometry.columnWidth
                guard abs(horizontalOffset - x) > 1 else { return }
                withAnimation(.snappy(duration: 0.3)) { horizontalPosition.scrollTo(x: x) }
            } else {
                recenter(on: day, columnWidth: geometry.columnWidth)
            }
        }
        .onChange(of: geometry.columnWidth) { _, width in
            if let index = days.firstIndex(of: model.selectedDay) {
                horizontalPosition.scrollTo(x: CGFloat(index) * width)
            }
        }
    }

    private func observeDays() {
        guard let first = days.first else { return }
        model.setGridRange(start: first, dayCount: days.count)
    }

    private func recenter(on day: Date, columnWidth: CGFloat) {
        // Change the dates and offset together, preserving the visible columns and vertical
        // position. Doing this only at rest leaves UIKit's finger tracking and inertia intact.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            carouselStart = DateNavigation.shift(day, by: -Self.carouselPadding, calendar: model.calendar)
            horizontalOffset = CGFloat(Self.carouselPadding) * columnWidth
            observeDays()
            rebuildLayout(inputs)
            horizontalPosition.scrollTo(x: horizontalOffset)
        }
    }

    private var pinnedGutterX: CGFloat { horizontalOffset }

    private func visibleDayIndices(columnWidth: CGFloat) -> Range<Int> {
        guard columnWidth > 0 else { return 0..<0 }
        let first = min(days.count, max(0, Int(((horizontalOffset + 0.5) / columnWidth).rounded(.down))))
        let last = min(days.count, max(first, Int(((horizontalOffset - 0.5) / columnWidth).rounded(.up)) + dayCount))
        return first..<last
    }

    @ViewBuilder
    private func gridContent(geometry: DayGridGeometry, days: [Date]) -> some View {
        TimelineView(.everyMinute) { timeline in
            let now = model.now
            VStack(spacing: 0) {
                // One day is already named by the heading and week strip above; only the columns
                // of a three-day grid need labelling.
                if dayCount > 1 {
                    DayGridHeader(
                        days: days, today: model.today, gutterWidth: Self.gutterWidth,
                        columnWidth: geometry.columnWidth, pinnedGutterX: pinnedGutterX, calendar: model.calendar,
                        blockingByDay: Dictionary(uniqueKeysWithValues: model.gridDays.map { ($0.day, $0.blockingAllDayEvents) }),
                        onSelect: onSelectEvent)
                    Divider()
                }
                if layout.allDayRowCount > 0 {
                    DayGridAllDayStrip(
                        layout: layout, geometry: geometry, now: now,
                        pinnedGutterX: pinnedGutterX, visibleDays: Set(days[visibleDayIndices(columnWidth: geometry.columnWidth)]),
                        compactsVisibleRows: dayCount == 1, onSelect: onSelectEvent)
                    Divider()
                }
                ScrollView(.vertical) {
                    timedGrid(geometry: geometry, days: days, now: now)
                }
                .accessibilityIdentifier("day-grid-hours")
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
                        scrollToStart()
                    }
                }
            }
            .onChange(of: timeline.date) { _, _ in
                // Suggestions expire with time too, without rebuilding during every pan frame.
                rebuildLayout(inputs)
            }
        }
    }

    private func timedGrid(geometry: DayGridGeometry, days: [Date], now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            DayGridCanvas(
                geometry: geometry, days: days, hourLabels: hourLabels, now: now,
                calendar: model.calendar, pinnedGutterX: pinnedGutterX,
                viewportWidth: Self.gutterWidth + CGFloat(dayCount) * geometry.columnWidth)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    create(at: CGPoint(x: point.x + pinnedGutterX, y: point.y), geometry: geometry, days: days)
                }
                .offset(x: pinnedGutterX)
            ZStack(alignment: .topLeading) {
                ForEach(layout.blocks) { block in
                    let rect = geometry.rect(for: block)
                    let hitLeft = max(0, pinnedGutterX + geometry.gutterWidth - rect.minX)
                    DayGridBlockView(
                        block: block, timeText: block.timeText, showsTime: rect.height >= geometry.timeTextHeight,
                        isPast: block.end <= now, showsSymbol: rect.width >= Self.planSymbolWidth,
                        showsThirdLine: rect.height >= geometry.timeTextHeight * 2)
                        .frame(width: rect.width, height: rect.height)
                        // Clip each block's hit area too; empty slots still belong to the canvas.
                        .contentShape(Path(CGRect(
                            x: hitLeft, y: 0, width: max(0, rect.width - hitLeft), height: rect.height)))
                        .offset(x: rect.minX, y: rect.minY)
                        .accessibilityHidden(!visibleDayIndices(columnWidth: geometry.columnWidth).contains(block.dayIndex))
                        .opacity(drag?.block.id == block.id ? 0.3 : 1)
                        // A quick tap opens; only a still hold lifts the block. Finished tasks
                        // and plan blocks get no hold, so their touches can always scroll.
                        .modifier(HoldToMove(
                            isEnabled: block.canMove,
                            gesture: BlockMoveGesture(
                                onLift: { lift(block, geometry: geometry) },
                                onMove: { follow($0, geometry: geometry, days: days) },
                                onDrop: { translation in
                                    follow(translation, geometry: geometry, days: days)
                                    drop()
                                },
                                onCancel: { cancelDrag() })))
                        .onTapGesture {
                            open(block)
                        }
                        .modifier(SuggestionDialog(
                            block: block, taking: $takingSuggestion, now: now, calendar: model.calendar,
                            onTake: { model.take($0) }, onEdit: { onEditTask($0.task) }))
                }
            }
            .frame(width: geometry.width, height: geometry.dayHeight, alignment: .topLeading)
            .mask(Rectangle().padding(.leading, max(0, pinnedGutterX + geometry.gutterWidth)))
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
    }

    /// What the layout is built from. Compared on every body evaluation (a few dozen small
    /// values), rebuilt only when something in it changed.
    private struct Inputs: Equatable {
        var days: [Date]
        var showTasksOnCalendar: Bool
        var agendas: [DayAgenda]
        var ghosts: [GhostBlock]
        var optionalPlacements: [OptionalPlacement]
        var openTasks: [TaskItem]
        var routineBlocks: [RoutineBlock]
        var blooming: Set<String>
        var categories: [TaskCategory]
        /// For the color of project time: its project's category.
        var projects: [Project]
        var calendars: [CalendarInfo]
        var accounts: [GoogleAccount]
        var minimumMinutes: Int
    }

    private var inputs: Inputs {
        let somedayIDs = model.somedayTaskIDs
        return Inputs(
            days: days, showTasksOnCalendar: showTasksOnCalendar, agendas: model.gridDays,
            // Today's finished blocks, on whichever column today is (`visibleGhosts` assumes the
            // selected day is today, which a 3-day grid opened on yesterday breaks).
            ghosts: JoySetting.ghosts.isOn ? model.ghostBlocks.filter { !somedayIDs.contains($0.taskId) } : [],
            optionalPlacements: model.optionalPlacements, openTasks: model.openTasks, routineBlocks: model.routineBlocks,
            blooming: Set(model.blooming.keys), categories: model.categories, projects: model.projects,
            calendars: model.calendars, accounts: model.accounts,
            minimumMinutes: DayGridGeometry.minimumMinutes(for: grid))
    }

    private func rebuildLayout(_ inputs: Inputs) {
        layout = DayGridLayout.build(
            days: inputs.days, agendas: inputs.agendas, ghosts: inputs.ghosts,
            suggestions: inputs.showTasksOnCalendar ? inputs.days.flatMap { model.optionalPicks(on: $0).flatMap(\.picks) } : [],
            showTasksOnCalendar: inputs.showTasksOnCalendar,
            blooming: inputs.blooming, minimumMinutes: inputs.minimumMinutes, calendar: model.calendar,
            eventStyle: { EventStyle(event: $0, calendars: inputs.calendars, accounts: inputs.accounts) },
            categoryTint: { id in Color.category(inputs.categories.first { $0.id == id }) },
            projectTint: { id in
                let categoryId = inputs.projects.first(where: { $0.id == id })?.categoryId
                return Color.category(inputs.categories.first(where: { $0.id == categoryId }))
            })
    }

    // MARK: - Scrolling

    private struct ScrollSnapshot: Equatable {
        var height: CGFloat
        var y: CGFloat
    }

    /// Puts the now line (today on screen) or 08:00 a third of the way down the visible grid.
    private func scrollToStart() {
        guard visibleHeight > 0 else { return }
        let visibleDays = AppModel.gridDays(from: model.selectedDay, dayCount: dayCount, calendar: model.calendar)
        let minute: Int
        if visibleDays.contains(model.today) {
            let components = model.calendar.dateComponents([.hour, .minute], from: model.now)
            minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        } else {
            minute = 8 * 60
        }
        let y = CGFloat(grid.y(forMinute: minute)) - visibleHeight * 0.3
        let clamped = min(max(0, y), max(0, CGFloat(grid.dayHeight) - visibleHeight))
        position.scrollTo(y: clamped)
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
        case .suggestion(let pick):
            takingSuggestion = pick
        case .plan(let plan):
            onSelectPlanBlock(plan)
        }
    }

    private func create(at point: CGPoint, geometry: DayGridGeometry, days: [Date]) {
        guard drag == nil, point.x >= pinnedGutterX + geometry.gutterWidth,
              let dayIndex = geometry.dayIndex(atX: point.x), days.indices.contains(dayIndex) else { return }
        let minute = geometry.slotMinute(atY: point.y)
        onCreateAt(DayGridLayout.date(forMinute: minute, on: days[dayIndex], calendar: model.calendar))
    }

    // MARK: - Moving blocks

    // `BlockMoveGesture` on each block calls these. Before its hold completes the scroll view
    // owns any movement (a finger that travels first scrolls, a quick tap opens); once it
    // completes the block lifts, scrolling is disabled for the rest of the touch
    // (`scrollDisabled(drag != nil)`), and the finger's travel moves the block in whole slots
    // across the columns.

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
        case .ghost, .suggestion, .plan:
            break
        }
    }

    /// The system took the touch away (a call banner, an edge swipe): the block goes back and
    /// nothing is written.
    private func cancelDrag() {
        guard drag != nil else { return }
        withAnimation(.snappy(duration: 0.2)) {
            drag = nil
        }
    }
}

/// Keep full day columns at rest without limiting how many days one gesture can travel.
private struct DayColumnScrollTarget: ScrollTargetBehavior {
    let columnWidth: CGFloat
    let singleDay: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard columnWidth > 0 else { return }
        var x = (target.rect.minX / columnWidth).rounded() * columnWidth
        if singleDay {
            let start = (context.originalTarget.rect.minX / columnWidth).rounded() * columnWidth
            x = min(max(x, start - columnWidth), start + columnWidth)
        }
        target.rect.origin.x = min(max(0, x), max(0, context.contentSize.width - context.containerSize.width))
    }
}

/// Hold-and-drag for the blocks that can be carried. A plan block gets no recognizer at all, so a
/// touch that starts on one can only scroll the grid or tap.
private struct HoldToMove: ViewModifier {
    let isEnabled: Bool
    let gesture: BlockMoveGesture

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(gesture)
        } else {
            content
        }
    }
}

/// On a suggestion's block: "Do tonight" or edit the task. Attached to the block so the dialog
/// opens anchored to it (see `Binding.only`); other blocks get nothing.
private struct SuggestionDialog: ViewModifier {
    let block: DayGridLayout.Block
    @Binding var taking: OptionalPicks.Pick?
    let now: Date
    let calendar: Calendar
    let onTake: (OptionalPicks.Pick) -> Void
    let onEdit: (OptionalPicks.Pick) -> Void

    func body(content: Content) -> some View {
        if case .suggestion(let pick) = block.item {
            content.confirmationDialog(
                pick.task.title, isPresented: $taking.only(pick).isPresent(), titleVisibility: .visible
            ) {
                Button(RoutineText.takeTitle(pick.placement, now: now, calendar: calendar)) {
                    onTake(pick)
                }
                Button("Edit Task") {
                    onEdit(pick)
                }
            } message: {
                Text("Suggested for \(block.timeText). It is not on the plan until you take it.")
            }
        } else {
            content
        }
    }
}
