import FloridaKit
import SwiftUI

/// Schedules on the left, the selected one's editor on the right. A schedule is the weekly
/// hours a category's tasks may be placed in.
struct SchedulesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedId: String?
    @State private var confirmingDelete: Schedule?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(model.schedules) { schedule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.name)
                            Text(usage(of: schedule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(schedule.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button {
                        selectedId = model.createSchedule()?.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add schedule")
                    Button {
                        confirmingDelete = selected
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Delete schedule")
                    .disabled(selected.map(isInUse) ?? true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            if let selected {
                ScheduleEditorView(schedule: selected)
                    .id(selected.id)
            } else {
                ContentUnavailableView("No schedule selected", systemImage: "clock")
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if selectedId == nil { selectedId = model.schedules.first?.id }
        }
        .confirmationDialog(
            "Delete “\(confirmingDelete?.name ?? "")”?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let schedule = confirmingDelete {
                    model.deleteSchedule(schedule)
                    selectedId = model.schedules.first { $0.id != schedule.id }?.id
                }
            }
        }
    }

    private var selected: Schedule? {
        model.schedules.first { $0.id == selectedId }
    }

    private func isInUse(_ schedule: Schedule) -> Bool {
        model.categories.contains { $0.scheduleId == schedule.id }
    }

    /// "Work, Errands" or "Unused".
    private func usage(of schedule: Schedule) -> String {
        let names = model.orderedCategories.filter { $0.scheduleId == schedule.id }.map(\.name)
        return names.isEmpty ? "Unused" : names.joined(separator: ", ")
    }
}
