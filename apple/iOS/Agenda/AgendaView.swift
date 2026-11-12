import FloridaKit
import SwiftUI

/// The Agenda tab: a week strip over the selected day, shown as a merged timeline list of events
/// and task blocks or, with the toggle beside the heading, as a one- or three-day time grid.
/// Swipe the strip to move a week, swipe the list or grid to move a day, tap the day heading for
/// a month grid, pull to sync. The toolbar adds tasks and events and picks which calendars show.
/// Today also shows the current block's progress, free gaps, finished blocks as ghosts and
/// "Day cleared", each behind a `JoySetting`. Under the list, a day with an optional routine block
/// shows what the scheduler would do in it ("Evening, if you're up for it").
///
/// The plan's other parts show here too: the day's kind (home, office, off) under the mode toggle,
/// the daily brief at the top of today's list, the day's open time and this week's missed
/// commitments under it, commitments and project time as timeline rows, and "Alongside …" under
/// every block that shares its time with other work.
struct AgendaView: View {
    @Environment(AppModel.self) private var model
    @State private var editingTask: TaskItem?
    @State private var selectedEvent: CalendarEvent?
    @State private var newEvent: CalendarEvent?
    @State private var showsDayPicker = false
    @State private var showsWeeklyReview = false
    @State private var openedLaunchSheet = false
    @State private var doneForNowTask: TaskItem?
    @State private var movingTask: TaskItem?
    @State private var now = Date()
    /// The day the list on screen was built for. It follows `model.selectedDay` one update later,
    /// inside an animation, so the old day's list slides out while the new one slides in.
    @State private var shownDay: Date?
    /// +1 when the day moved forward (new content enters from the right), −1 when back.
    @State private var slideDirection: CGFloat = 1
    @AppStorage(AgendaMode.storageKey, store: .florida) private var mode: AgendaMode = .list
    @AppStorage(JoySetting.blockProgress.rawValue, store: .florida) private var showsProgress = true
    @AppStorage(JoySetting.freeGaps.rawValue, store: .florida) private var showsGaps = true
    @AppStorage(JoySetting.ghosts.rawValue, store: .florida) private var showsGhosts = true
    @AppStorage(JoySetting.dayCleared.rawValue, store: .florida) private var showsDayCleared = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dayHeading
                if mode != .threeDays {
                    ZStack {
                        WeekStrip(
                            selectedDay: model.selectedDay,
                            today: model.today,
                            calendar: model.calendar,
                            onSelect: { model.select(day: $0) },
                            onShiftWeek: { model.shiftDay(by: 7 * $0) })
                        .id(DateNavigation.startOfWeek(for: shownDay ?? model.selectedDay, calendar: model.calendar))
                        .transition(slide)
                    }
                }
                Divider()
                content
            }
            .background(FloridaStyle.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FloridaStyle.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.selectToday()
                    } label: {
                        FloridaWordmark(height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Florida")
                    .accessibilityHint("Shows today, scrolled to now")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    calendarMenu
                    addMenu
                    Button("Today") {
                        model.selectToday()
                    }
                    .disabled(isToday)
                }
            }
            .sheet(isPresented: $showsDayPicker) {
                DayPickerSheet(selectedDay: model.selectedDay)
            }
            .sheet(isPresented: $showsWeeklyReview) {
                WeeklyReviewSheet()
            }
            .sheet(item: $editingTask) { task in
                TaskEditorView(task: task)
            }
            .sheet(item: $selectedEvent) { event in
                EventDetailView(event: event)
            }
            .sheet(item: $newEvent) { event in
                EventCaptureSheet(event: event)
            }
            .taskActionSheets(doneForNow: $doneForNowTask)
            .onChange(of: model.selectedDay) { old, new in
                slideDirection = new > old ? 1 : -1
                withAnimation(.snappy(duration: 0.22)) {
                    shownDay = new
                }
            }
            .onChange(of: model.agenda, initial: true) { _, agenda in
                // Screenshot runs (`-uiSheet event`): open the demo design review once it loads.
                guard LaunchOptions.initialSheet == "event", !openedLaunchSheet,
                      let event = agenda?.events.first(where: { $0.id == "demo-event-design" })
                else { return }
                openedLaunchSheet = true
                selectedEvent = event
            }
            .onAppear {
                // Screenshot runs (`-uiAgendaMode threeDays`): show the grid instead of the list.
                if let launchMode = LaunchOptions.initialAgendaMode {
                    mode = launchMode
                }
                // Screenshot runs (`-uiSheet daypicker`): open the month grid over the agenda.
                guard LaunchOptions.initialSheet == "daypicker", !openedLaunchSheet else { return }
                openedLaunchSheet = true
                showsDayPicker = true
            }
            .task {
                // Keeps the "now" marker, block progress and the dimming of finished items current.
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .toastOverlay()
        }
    }

    private var items: [AgendaItem] {
        model.agenda.map { AgendaItem.timed(from: $0, ghosts: showsGhosts ? model.visibleGhosts : []) } ?? []
    }

    private var allDayEvents: [CalendarEvent] {
        model.agenda.map(AgendaItem.allDay) ?? []
    }

    private var rows: [TimelineRow] {
        TimelineRow.rows(for: items, now: isToday ? now : nil, showsGaps: showsGaps)
    }

    /// For each task block (by `Placement.id`) and project block (by `PlanBlock.id`) of the day
    /// that shares its time, the titles of the work beside it. A finished task's block is no
    /// longer work: it gets no caption and is not named in another's.
    private var companions: [String: [String]] {
        guard let agenda = model.agenda else { return [:] }
        let open = agenda.placements.filter { $0.task.completedAt == nil }
        return ParallelWork.companionTitles(
            placements: open.map(\.placement),
            tasksById: Dictionary(open.map { ($0.task.id, $0.task) }, uniquingKeysWith: { first, _ in first }),
            planBlocks: agenda.planBlocks)
    }

    /// "1h 30m free": the selected day's open computer time, which is what `PlanText.free` reports.
    private var freeText: String? {
        model.freeMinutes(on: model.selectedDay).flatMap { PlanText.free($0.computer) }
    }

    /// The commitments with no slot this week, said once: on today.
    private var missedText: String? {
        guard isToday else { return nil }
        let names = model.missedCommitments(inWeekOf: model.selectedDay)
        return names.isEmpty ? nil : PlanText.missed(names)
    }

    /// Nothing on the day: no events, blocks or suggestions.
    private var isEmptyDay: Bool {
        items.isEmpty && allDayEvents.isEmpty && picks.isEmpty
    }

    /// Suggestions for the day's optional routine blocks; not part of the timeline above.
    private var picks: [OptionalPicks] {
        model.optionalPicks(on: model.selectedDay, now: now)
    }

    /// Today was asked for (the wordmark, a widget) while today's list is already on screen:
    /// bring the now marker to the middle. Another day's list is new and starts at the top.
    private func scrollToNow(_ proxy: ScrollViewProxy) {
        guard isToday, rows.contains(.now) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            proxy.scrollTo(TimelineRow.now.id, anchor: .center)
        }
    }

    private var isToday: Bool {
        model.selectedDay == model.today
    }

    /// New-content-from-the-side slide for day changes: 28 points and a fade, mirrored on exit.
    private var slide: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 28 * slideDirection).combined(with: .opacity),
            removal: .offset(x: -28 * slideDirection).combined(with: .opacity))
    }

    // MARK: - Heading and toolbar

    /// "Monday" over "November 9, 2026" (tap for the month grid), with the list / day / 3-day
    /// toggle on the right and the day's kind under it, level with the date.
    private var dayHeading: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                showsDayPicker = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if mode != .threeDays {
                        Text(model.selectedDay.formatted(.dateTime.weekday(.wide)))
                            .font(.title.weight(.medium))
                            .foregroundStyle(FloridaStyle.ink)
                    }
                    HStack(spacing: 4) {
                        Text(model.selectedDay.formatted(mode == .threeDays
                            ? .dateTime.month(.wide).year() : .dateTime.month(.wide).day().year()))
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to day")
            .accessibilityValue(model.selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            .accessibilityHint("Opens a month calendar")
            VStack(alignment: .trailing, spacing: 0) {
                modePicker
                dayKindMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(AgendaMode.allCases) { option in
                Image(systemName: option.symbolName)
                    .accessibilityLabel(option.title)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("agenda-mode")
    }

    /// What the selected day is ("Home day"), drawn like the date beside it. The menu makes the day
    /// a home, office or off day; a day that was changed can go back to its weekday's routine, and
    /// reads in ink until it does.
    private var dayKindMenu: some View {
        let day = model.selectedDay
        let kind = model.dayKind(of: day)
        let isChanged = model.dayOverride(on: day) != nil
        return Menu {
            Picker("Day", selection: Binding(get: { kind }, set: { model.setDay(day, kind: $0) })) {
                ForEach(DayKind.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.symbolName)
                        .tag(option)
                }
            }
            if isChanged {
                Button {
                    model.clearDayOverride(on: day)
                } label: {
                    Label("Back to the routine", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.symbolName)
                    .accessibilityHidden(true)
                Text(kind.label)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(isChanged ? FloridaStyle.ink : Color.secondary)
            .lineLimit(1)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The label's bottom padding is touch area only: it lies over the heading's own.
        .padding(.bottom, -8)
        // The toggle above does not grow with the text size, so the heading stays one block.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityValue(isChanged ? "Changed for this day" : "From the routine")
        .accessibilityHint("Changes what kind of day this is")
        .accessibilityIdentifier("agenda-day-kind")
    }

    /// Which calendars show, grouped by Google account. Flipping one updates the store at once and
    /// tells the server in the background, like the toggles in Settings.
    private var calendarMenu: some View {
        Menu {
            if model.calendars.isEmpty {
                Text(model.needsSetup ? "Connect to the server in Settings." : "No calendars synced yet.")
            }
            ForEach(model.accounts) { account in
                let owned = model.calendars.filter { $0.accountId == account.id }
                if !owned.isEmpty {
                    Section(account.label.isEmpty ? account.email : "\(account.label) · \(account.email)") {
                        ForEach(owned) { info in
                            Toggle(info.summary, isOn: calendarSelection(info))
                        }
                    }
                }
            }
        } label: {
            Label("Calendars", systemImage: "calendar")
        }
        .accessibilityIdentifier("agenda-calendars")
    }

    private func calendarSelection(_ info: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { model.calendarInfo(id: info.id)?.selected ?? info.selected },
            set: { model.setCalendarSelected(id: info.id, selected: $0) })
    }

    /// New task (the same composer as Tasks and the widget) or new event, starting at the next quarter hour
    /// today or 9:00 on another day.
    private var addMenu: some View {
        Menu {
            Button {
                model.showingQuickAdd = true
            } label: {
                Label("New Task", systemImage: "checkmark.circle")
            }
            Button {
                newEvent = model.newEventTemplate(start: defaultEventStart)
            } label: {
                Label("New Event", systemImage: "calendar.badge.plus")
            }
            .disabled(model.writableCalendars.isEmpty)
        } label: {
            Label("Add", systemImage: "plus")
        }
        .accessibilityIdentifier("agenda-add")
    }

    private var defaultEventStart: Date {
        if isToday { return now }
        return model.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: model.selectedDay) ?? model.selectedDay
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let dayCount = mode.dayCount {
            DayGridView(
                dayCount: dayCount,
                onSelectEvent: { selectedEvent = $0 },
                onEditTask: { editingTask = $0 },
                onCreateAt: { newEvent = model.newEventTemplate(start: $0) })
        } else {
            // A ZStack so the outgoing and incoming lists overlap during the slide instead of
            // stacking.
            ZStack {
                ScrollViewReader { proxy in
                    timeline
                        .onChange(of: model.todayRequests) { _, _ in
                            scrollToNow(proxy)
                        }
                }
                .id(shownDay ?? model.selectedDay)
                .transition(slide)
            }
        }
    }

    private var timeline: some View {
        let beside = companions
        return List {
            if model.hasProblem {
                Section {
                    SyncErrorBanner()
                }
            }
            if model.needsSetup {
                Section {
                    Label("Not connected. Add the server URL and token in Settings.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            // What the plan says about the day, before the day itself. Both rows line up with the
            // heading above (20 points) and take less height than a default row would.
            if isToday || freeText != nil {
                Section {
                    if isToday {
                        BriefCard(onShowWeek: { showsWeeklyReview = true })
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(FloridaStyle.paper)
                    }
                    if freeText != nil || missedText != nil {
                        DayPlanNotes(free: freeText, missed: missedText)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(FloridaStyle.paper)
                    }
                }
            }
            if !allDayEvents.isEmpty {
                Section("All day") {
                    ForEach(allDayEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            AllDayEventRow(event: event, style: model.eventStyle(event), continuation: continuation(of: event))
                                .foregroundStyle(.primary)
                        }
                        .accessibilityHint("Shows the event")
                        .listRowBackground(FloridaStyle.paper)
                    }
                }
            }
            Section {
                ForEach(rows) { row in
                    switch row {
                    case .now:
                        NowMarker(now: now)
                            .listRowBackground(FloridaStyle.paper)
                    case .gap(let gap):
                        FreeGapRow(gap: gap)
                            .listRowBackground(FloridaStyle.paper)
                    case .item(.event(let event)):
                        eventRow(event)
                            .timelineSeparator()
                            .listRowBackground(FloridaStyle.paper)
                    case .item(.block(let block)):
                        blockRow(block, beside: beside[block.placement.id])
                    case .item(.plan(let block)):
                        planRow(block, beside: beside[block.id])
                            .timelineSeparator()
                            .listRowBackground(FloridaStyle.paper)
                    case .item(.ghost(let ghost)):
                        GhostRow(ghost: ghost, category: model.category(id: ghost.categoryId))
                            .timelineSeparator()
                            .listRowBackground(FloridaStyle.paper)
                    }
                }
                // Today's list starts with the brief, so the empty day is said under it, not over it.
                if isEmptyDay && isToday {
                    nothingScheduled
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .listRowBackground(FloridaStyle.paper)
                }
            } header: {
                if showsDayCleared && model.isDayCleared {
                    Label("Day cleared", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .textCase(nil)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            ForEach(picks) { group in
                OptionalPicksSection(group: group, now: now, onEdit: { editingTask = $0 })
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(FloridaStyle.paper)
        .animation(.snappy, value: model.isDayCleared)
        .overlay {
            if isEmptyDay && !isToday {
                nothingScheduled
                    .allowsHitTesting(false)
            }
        }
        .refreshable {
            await model.syncNow()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                    model.shiftDay(by: dx < 0 ? 1 : -1)
                }
        )
    }

    private var nothingScheduled: some View {
        ContentUnavailableView(
            "Nothing scheduled",
            systemImage: "calendar",
            description: Text("No events or task blocks on this day."))
    }

    /// A task block: tap to edit, swipe or long-press for its actions. A block of a task that is
    /// already done has none. `beside` names the work that shares its time, said under the block
    /// and outside its button, so the button reads to VoiceOver and UI tests as it always did.
    @ViewBuilder
    private func blockRow(_ block: ScheduledBlock, beside: [String]?) -> some View {
        let category = model.category(id: block.task.categoryId)
        let isBlooming = model.blooming[block.task.id] != nil
        let row = VStack(alignment: .leading, spacing: 0) {
            Button {
                editingTask = block.task
            } label: {
                BlockRow(block: block, category: category, now: now, showsProgress: showsProgress && isToday)
                    .strikethrough(isBlooming || block.task.completedAt != nil)
                    .foregroundStyle(.primary)
            }
            .accessibilityHint("Edits the task")
            if let beside {
                AlongsideCaption(
                    id: block.placement.id, titles: beside, inset: BlockRow.titleInset,
                    isOver: AgendaItem.block(block).isOver(at: now))
            }
        }
        .timelineSeparator()
        .listRowBackground(BloomBackground(color: Color.category(category), active: isBlooming, base: FloridaStyle.paper))
        if block.task.completedAt == nil {
            row.taskActions(
                block.task, targets: TaskActionTargets(doneForNow: $doneForNowTask, moving: $movingTask),
                onEdit: { editingTask = block.task }, allowsDelete: false)
        } else {
            row
        }
    }

    /// A commitment or project time, with the work that shares its time under it. Nothing opens
    /// from it.
    private func planRow(_ block: PlanBlock, beside: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PlanBlockRow(block: block, category: category(of: block), now: now)
            if let beside {
                AlongsideCaption(
                    id: block.id, titles: beside, inset: PlanBlockRow.titleInset,
                    isOver: AgendaItem.plan(block).isOver(at: now))
            }
        }
    }

    /// The category of the project the block holds time for, for its color; nil for a commitment
    /// and for a project without a category.
    private func category(of block: PlanBlock) -> TaskCategory? {
        guard case .project(let projectId) = block.kind else { return nil }
        return model.project(id: projectId)?.categoryId.flatMap { model.category(id: $0) }
    }

    /// Tapping an event opens its detail sheet.
    private func eventRow(_ event: CalendarEvent) -> some View {
        Button {
            selectedEvent = event
        } label: {
            EventRow(event: event, style: model.eventStyle(event), continuation: continuation(of: event), now: now)
                .foregroundStyle(.primary)
        }
        .accessibilityHint("Shows the event")
    }

    private func continuation(of event: CalendarEvent) -> String? {
        EventTiming.continuation(of: event, on: model.selectedDay, calendar: model.calendar)
    }
}
