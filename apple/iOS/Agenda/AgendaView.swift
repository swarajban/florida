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
    @State private var selectedOOO: AllDayPresentation.Item?
    @State private var newEvent: CalendarEvent?
    @State private var showsDayPicker = false
    @State private var showsWeeklyReview = false
    @State private var openedLaunchSheet = false
    @State private var doneForNowTask: TaskItem?
    @State private var movingTask: TaskItem?
    @State private var now = Date()
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
                    WeekStrip(
                        selectedDay: model.selectedDay,
                        today: model.today,
                        calendar: model.calendar,
                        onSelect: { model.select(day: $0) },
                        onShiftWeek: { model.shiftDay(by: 7 * $0) })
                }
                Divider()
                content
            }
            .background(FloridaStyle.paper)
            .toolbar(.hidden, for: .navigationBar)
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
        .sheet(isPresented: $showsDayPicker) {
            DayPickerSheet(selectedDay: model.selectedDay, isPresented: $showsDayPicker)
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
        .sheet(item: $selectedOOO) { item in
            CoworkerOOOSheet(events: item.events)
        }
        .sheet(item: $newEvent) { event in
            EventCaptureSheet(event: event, onDismiss: { newEvent = nil })
        }
        .taskActionSheets(doneForNow: $doneForNowTask)
    }

    private var isToday: Bool {
        model.selectedDay == model.today
    }

    // MARK: - Heading and toolbar

    private var dayHeading: some View {
        VStack(spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    datePickerButton
                    Spacer(minLength: 0)
                    headerActions
                }
                VStack(alignment: .leading, spacing: 0) {
                    datePickerButton
                    headerActions
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    modePicker
                    Spacer(minLength: 0)
                    todayButton
                    dayStatusMenu
                }
                VStack(spacing: 2) {
                    modePicker
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            todayButton
                            Spacer(minLength: 8)
                            dayStatusMenu
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            todayButton
                            dayStatusMenu
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var datePickerButton: some View {
        Button {
            showsDayPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedDay.formatted(headingDateFormat))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(FloridaStyle.ink)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to day")
        .accessibilityValue(model.selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityHint("Opens a month calendar")
    }

    private var headingDateFormat: Date.FormatStyle {
        var format: Date.FormatStyle = mode == .threeDays
            ? .dateTime.month(.wide) : .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        format.calendar = model.calendar
        format.timeZone = model.calendar.timeZone
        return model.calendar.component(.year, from: model.selectedDay) == model.calendar.component(.year, from: model.today)
            ? format : format.year()
    }

    private var headerActions: some View {
        HStack(spacing: 0) {
            calendarMenu
            addMenu
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(FloridaStyle.ink)
    }

    private var todayButton: some View {
        Button("Today") { model.selectToday() }
            .font(.subheadline)
            .fixedSize()
            .frame(minHeight: 44)
            .foregroundStyle(isToday ? Color.secondary : FloridaStyle.ink)
    }

    private var dayStatusMenu: some View {
        AgendaDayStatus(day: model.selectedDay, events: model.agenda?.blockingAllDayEvents ?? []) {
            selectedEvent = $0
        }
        .accessibilityIdentifier("agenda-day-kind")
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
                .frame(minWidth: 44, minHeight: 44)
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
                .frame(minWidth: 44, minHeight: 44)
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
            AgendaListCarousel { day, agenda in
                ScrollViewReader { proxy in
                    timeline(on: day, agenda: agenda)
                        .onChange(of: model.todayRequests) { _, _ in
                            guard day == model.today, day == model.selectedDay else { return }
                            withAnimation(.snappy(duration: 0.3)) {
                                proxy.scrollTo(TimelineRow.now.id, anchor: .center)
                            }
                        }
                }
            }
        }
    }

    private func timeline(on day: Date, agenda: DayAgenda?) -> some View {
        let isToday = day == model.today
        let live = Set(agenda?.placements.map(\.placement.id) ?? [])
        let ghosts = isToday && showsGhosts
            ? model.ghostBlocks.filter { !live.contains($0.id) && !model.somedayTaskIDs.contains($0.taskId) } : []
        let items = agenda.map { AgendaItem.timed(from: $0, ghosts: ghosts) } ?? []
        let allDayEvents = agenda.map(AgendaItem.allDay) ?? []
        let allDayItems = AllDayPresentation.items(for: allDayEvents) { id in
            model.calendars.first { $0.id == id }?.summary
        }
        let rows = TimelineRow.rows(for: items, now: isToday ? now : nil, showsGaps: showsGaps)
        let picks = model.optionalPicks(on: day, now: now)
        let isEmptyDay = items.isEmpty && allDayEvents.isEmpty && picks.isEmpty
        let freeText = model.freeMinutes(on: day).flatMap { PlanText.free($0.computer) }
        let missed = isToday ? model.missedCommitments(inWeekOf: day) : []
        let missedText = missed.isEmpty ? nil : PlanText.missed(missed)
        let open = agenda?.placements.filter { $0.task.completedAt == nil } ?? []
        let beside = ParallelWork.companionTitles(
            placements: open.map(\.placement),
            tasksById: Dictionary(open.map { ($0.task.id, $0.task) }, uniquingKeysWith: { first, _ in first }),
            planBlocks: agenda?.planBlocks ?? [])
        let unfinished = open.filter { model.blooming[$0.task.id] == nil }
        let isDayCleared = isToday && unfinished.isEmpty
            && (agenda?.placements.count ?? 0) - unfinished.count + ghosts.count > 0
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
            if isToday || freeText != nil || missedText != nil {
                Section {
                    if isToday {
                        BriefCard(onShowWeek: { showsWeeklyReview = true }, freeText: freeText)
                            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(FloridaStyle.paper)
                    }
                    if (!isToday && freeText != nil) || missedText != nil {
                        DayPlanNotes(free: isToday ? nil : freeText, missed: missedText)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(FloridaStyle.paper)
                    }
                }
            }
            if !allDayEvents.isEmpty {
                Section {
                    ForEach(allDayItems) { item in
                        let event = item.events[0]
                        Button {
                            if item.isGroup { selectedOOO = item } else { selectedEvent = event }
                        } label: {
                            if item.isGroup {
                                CoworkerOOOLabel(item: item)
                            } else {
                                AllDayEventRow(
                                    event: event, style: model.eventStyle(event),
                                    continuation: EventTiming.continuation(of: event, on: day, calendar: model.calendar),
                                    protectsDay: agenda?.blockingAllDayEvents.contains(where: { $0.id == event.id }) == true)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .accessibilityHint("Shows the event")
                        .accessibilityIdentifier(item.isGroup ? "all-day-coworker-ooo" : "all-day-event-\(event.id)")
                        .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                        .listRowBackground(FloridaStyle.paper)
                    }
                }
                .listSectionSeparator(.visible, edges: .bottom)
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
                        eventRow(event, on: day)
                            .timelineSeparator()
                            .listRowBackground(FloridaStyle.paper)
                    case .item(.block(let block)):
                        blockRow(block, beside: beside[block.placement.id], isToday: isToday)
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
                if showsDayCleared && isDayCleared {
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
        .environment(\.defaultMinListRowHeight, 30)
        .scrollContentBackground(.hidden)
        .background(FloridaStyle.paper)
        .animation(.snappy, value: isDayCleared)
        .overlay {
            if isEmptyDay && !isToday {
                nothingScheduled
                    .allowsHitTesting(false)
            }
        }
        .refreshable {
            await model.syncNow()
        }
    }

    private var nothingScheduled: some View {
        ContentUnavailableView(
            "Nothing scheduled",
            systemImage: "calendar",
            description: Text("No events or task blocks on this day."))
    }

    /// A task block: tap to edit, long-press for its actions. A block of a task that is
    /// already done has none. `beside` names the work that shares its time, said under the block
    /// and outside its button, so the button reads to VoiceOver and UI tests as it always did.
    @ViewBuilder
    private func blockRow(_ block: ScheduledBlock, beside: [String]?, isToday: Bool) -> some View {
        let category = model.category(id: block.task.categoryId)
        let isBlooming = model.blooming[block.task.id] != nil
        let row = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    editingTask = block.task
                } label: {
                    BlockRow(block: block, category: category, now: now, showsProgress: showsProgress && isToday)
                        .strikethrough(isBlooming || block.task.completedAt != nil)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Edits the task")
                if let source = block.task.source {
                    TaskSourceButton(source: source, identifier: "agenda-source-open-\(block.placement.id)", compact: true)
                }
            }
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
                onEdit: { editingTask = block.task }, allowsDelete: false, allowsSwipe: false)
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
    private func eventRow(_ event: CalendarEvent, on day: Date) -> some View {
        Button {
            selectedEvent = event
        } label: {
            EventRow(
                event: event, style: model.eventStyle(event),
                continuation: EventTiming.continuation(of: event, on: day, calendar: model.calendar), now: now)
                .foregroundStyle(.primary)
        }
        .accessibilityHint("Shows the event")
    }
}
