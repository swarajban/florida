import FloridaKit
import SwiftUI

/// Schedules, pushed from the Tasks tab: each with its time zone, its hours in short form and the
/// categories that follow it. Tap to edit, + to add, swipe to delete (refused while in use).
struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Schedule?
    @State private var deleting: Schedule?

    var body: some View {
        List {
            ForEach(model.schedules) { schedule in
                Button {
                    editing = schedule
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(schedule.name)
                            .foregroundStyle(.primary)
                        Text(ScheduleText.summary(schedule.windows, calendar: model.calendar))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(footnote(schedule))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityHint("Edits the schedule")
                .swipeActions(edge: .trailing) {
                    Button {
                        deleting = schedule
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.schedules.isEmpty {
                ContentUnavailableView("No schedules", systemImage: "clock", description: Text("Sync with the server, or add one."))
            }
        }
        .navigationTitle("Schedules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = model.newSchedule()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add schedule")
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditorView(schedule: schedule, isNew: model.schedule(id: schedule.id) == nil)
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { schedule in
            Button("Delete Schedule", role: .destructive) {
                do {
                    try model.deleteSchedule(schedule)
                } catch {
                    model.showToast(Toast(message: error.localizedDescription, systemImage: "exclamationmark.triangle.fill", style: .error))
                }
            }
        }
        .toastOverlay()
    }

    /// "America/Los_Angeles · Inbox, Work".
    private func footnote(_ schedule: Schedule) -> String {
        let users = model.categoriesUsing(scheduleId: schedule.id).map(\.name)
        return ([schedule.timeZone] + (users.isEmpty ? ["No categories"] : [users.joined(separator: ", ")]))
            .joined(separator: " · ")
    }
}

/// Schedule windows in words.
enum ScheduleText {
    /// "Mon–Fri 09:00–17:00 · Sat, Sun 10:00–18:00".
    static func summary(_ windows: [ScheduleWindow], calendar: Calendar) -> String {
        guard !windows.isEmpty else { return "No hours" }
        return windows.map { "\(days($0.days, calendar: calendar)) \($0.start)–\($0.end)" }.joined(separator: " · ")
    }

    /// "Mon–Fri", "Sat, Sun", "Every day"; runs of three or more days collapse to a range.
    static func days(_ days: [Int], calendar: Calendar) -> String {
        let sorted = Array(Set(days)).sorted()
        if sorted.count == 7 { return "Every day" }
        let names = calendar.shortWeekdaySymbols
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 {
                end += 1
            }
            if end - index >= 2 {
                parts.append("\(names[sorted[index]])–\(names[sorted[end]])")
            } else {
                parts.append(contentsOf: sorted[index...end].map { names[$0] })
            }
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }
}
