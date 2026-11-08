import FloridaKit
import SwiftUI

/// The Agenda tab: a week strip over the merged timeline of events and task blocks for one day.
/// Swipe the strip to move a week, swipe the list to move a day, pull to sync.
struct AgendaView: View {
    @Environment(AppModel.self) private var model
    @State private var editingTask: TaskItem?
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekStrip(
                    selectedDay: model.selectedDay,
                    today: model.today,
                    calendar: model.calendar,
                    onSelect: { model.select(day: $0) },
                    onShiftWeek: { model.shiftDay(by: 7 * $0) })
                Divider()
                timeline
            }
            .navigationTitle(model.selectedDay.formatted(.dateTime.month(.wide).year()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") {
                        model.selectToday()
                    }
                    .disabled(isToday)
                }
            }
            .sheet(item: $editingTask) { task in
                TaskEditorView(task: task)
            }
            .task {
                // Keeps the "now" marker and the dimming of finished items current.
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    private var items: [AgendaItem] {
        model.agenda.map(AgendaItem.timed) ?? []
    }

    private var allDayEvents: [CalendarEvent] {
        model.agenda.map(AgendaItem.allDay) ?? []
    }

    private var isToday: Bool {
        model.selectedDay == model.today
    }

    private var timeline: some View {
        List {
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
                        AllDayEventRow(event: event)
                    }
                }
            }
            Section {
                ForEach(TimelineRow.rows(for: items, now: isToday ? now : nil)) { row in
                    switch row {
                    case .now:
                        NowMarker(now: now)
                    case .item(.event(let event)):
                        eventRow(event)
                    case .item(.block(let block)):
                        BlockRow(block: block, project: model.project(id: block.task.projectId), now: now)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingTask = block.task
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
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

    /// Events link out to Google Calendar when the server stored an `htmlLink`.
    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
        if let url = event.htmlLink.flatMap(URL.init(string:)) {
            Link(destination: url) {
                EventRow(event: event, now: now)
            }
            .foregroundStyle(.primary)
        } else {
            EventRow(event: event, now: now)
        }
    }
}
