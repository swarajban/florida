import FloridaKit
import SwiftUI

/// The weekly routine the scheduler places tasks in, pushed from Settings: each block's days,
/// hours and the task contexts it allows. Read-only; the server owns the routine for now.
struct RoutineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.routineBlocks) { block in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.name)
                        Text(RoutineText.when(block, calendar: model.calendar))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(RoutineText.allows(block))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if block.optional {
                            Label(RoutineText.optionalNote, systemImage: "moon.stars")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if !model.routineBlocks.isEmpty {
                    Text(RoutineText.footnote(timeZone: model.userSettings?.timeZone))
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.routineBlocks.isEmpty {
                ContentUnavailableView(
                    "No routine yet", systemImage: "calendar.day.timeline.left", description: Text("Sync with the server."))
            }
        }
        .navigationTitle("Routine")
    }
}
