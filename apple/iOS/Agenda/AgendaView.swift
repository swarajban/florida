import FloridaKit
import SwiftUI

/// The Agenda tab: a week strip over the merged timeline of events and task blocks for one day.
/// Swipe the strip to move a week, swipe the list to move a day, tap the day heading for a month
/// grid, pull to sync. Today also shows the current block's progress, free gaps, finished blocks
/// as ghosts and "Day cleared", each behind a `JoySetting`.
struct AgendaView: View {
    @Environment(AppModel.self) private var model
    @State private var editingTask: TaskItem?
    @State private var selectedEvent: CalendarEvent?
    @State private var showsDayPicker = false
    @State private var openedLaunchSheet = false
    @State private var doneForNowTask: TaskItem?
    @State private var movingTask: TaskItem?
    @State private var now = Date()
    @AppStorage(JoySetting.blockProgress.rawValue, store: .florida) private var showsProgress = true
    @AppStorage(JoySetting.freeGaps.rawValue, store: .florida) private var showsGaps = true
    @AppStorage(JoySetting.ghosts.rawValue, store: .florida) private var showsGhosts = true
    @AppStorage(JoySetting.dayCleared.rawValue, store: .florida) private var showsDayCleared = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dayHeading
                WeekStrip(
                    selectedDay: model.selectedDay,
                    today: model.today,
                    calendar: model.calendar,
                    onSelect: { model.select(day: $0) },
                    onShiftWeek: { model.shiftDay(by: 7 * $0) })
                Divider()
                timeline
            }
            .background(FloridaStyle.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FloridaStyle.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    FloridaWordmark(height: 26)
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            .sheet(item: $selectedEvent) { event in
                EventDetailView(event: event)
            }
            .taskActionSheets(doneForNow: $doneForNowTask, moving: $movingTask)
            .onChange(of: model.agenda, initial: true) { _, agenda in
                // Screenshot runs (`-uiSheet event`): open the demo design review once it loads.
                guard LaunchOptions.initialSheet == "event", !openedLaunchSheet,
                      let event = agenda?.events.first(where: { $0.id == "demo-event-design" })
                else { return }
                openedLaunchSheet = true
                selectedEvent = event
            }
            .onAppear {
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

    private var isToday: Bool {
        model.selectedDay == model.today
    }

    /// "Monday" over "November 9, 2026". Tapping it opens the month grid to jump to any day.
    private var dayHeading: some View {
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
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityLabel("Go to day")
        .accessibilityValue(model.selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityHint("Opens a month calendar")
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
                ForEach(TimelineRow.rows(for: items, now: isToday ? now : nil, showsGaps: showsGaps)) { row in
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
