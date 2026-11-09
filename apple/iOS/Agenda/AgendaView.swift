import FloridaKit
import SwiftUI

/// The Agenda tab: a week strip over the selected day, shown as a merged timeline list of events
/// and task blocks or, with the toggle beside the heading, as a one- or three-day time grid.
/// Swipe the strip to move a week, swipe the list or grid to move a day, tap the day heading for
/// a month grid, pull to sync. The toolbar adds tasks and events and picks which calendars show.
/// Today also shows the current block's progress, free gaps, finished blocks as ghosts and
/// "Day cleared", each behind a `JoySetting`.
struct AgendaView: View {
    @Environment(AppModel.self) private var model
    @State private var editingTask: TaskItem?
    @State private var newTask: TaskEditorRequest?
    @State private var selectedEvent: CalendarEvent?
    @State private var newEvent: CalendarEvent?
    @State private var showsDayPicker = false
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
            .sheet(item: $editingTask) { task in
                TaskEditorView(task: task)
            }
            .sheet(item: $newTask) { request in
                TaskEditorView(request: request)
            }
            .sheet(item: $selectedEvent) { event in
                EventDetailView(event: event)
            }
            .sheet(item: $newEvent) { event in
                EventEditorView(event: event, isNew: true)
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
    /// toggle on the right.
    private var dayHeading: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                showsDayPicker = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedDay.formatted(.dateTime.weekday(.wide)))
                        .font(.title.weight(.medium))
                        .foregroundStyle(FloridaStyle.ink)
                    HStack(spacing: 4) {
                        Text(model.selectedDay.formatted(.dateTime.month(.wide).day().year()))
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
            modePicker
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

    /// New task (the same editor as the Tasks tab) or new event, starting at the next quarter hour
    /// today or 9:00 on another day.
    private var addMenu: some View {
        Menu {
            Button {
                newTask = TaskEditorRequest(task: model.newTaskTemplate(), isNew: true)
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
        List {
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
                            .listRowBackground(FloridaStyle.paper)
                    case .item(.block(let block)):
                        blockRow(block)
                    case .item(.ghost(let ghost)):
                        GhostRow(ghost: ghost, category: model.category(id: ghost.categoryId))
                            .listRowBackground(FloridaStyle.paper)
                    }
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(FloridaStyle.paper)
        .animation(.snappy, value: model.isDayCleared)
        .overlay {
            if items.isEmpty && allDayEvents.isEmpty {
                ContentUnavailableView(
                    "Nothing scheduled",
                    systemImage: "calendar",
                    description: Text("No events or task blocks on this day."))
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

    /// A task block: tap to edit, swipe or long-press for its actions. A block of a task that is
    /// already done has none.
    @ViewBuilder
    private func blockRow(_ block: ScheduledBlock) -> some View {
        let category = model.category(id: block.task.categoryId)
        let isBlooming = model.blooming[block.task.id] != nil
        let row = Button {
            editingTask = block.task
        } label: {
            BlockRow(block: block, category: category, now: now, showsProgress: showsProgress && isToday)
                .strikethrough(isBlooming || block.task.completedAt != nil)
                .foregroundStyle(.primary)
        }
        .accessibilityHint("Edits the task")
        .listRowBackground(BloomBackground(color: Color.category(category), active: isBlooming, base: FloridaStyle.paper))
        if block.task.completedAt == nil {
            row.taskActions(
                block.task, targets: TaskActionTargets(doneForNow: $doneForNowTask, moving: $movingTask),
                onEdit: { editingTask = block.task }, allowsDelete: false)
        } else {
            row
        }
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
