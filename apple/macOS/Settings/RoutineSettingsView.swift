import FloridaKit
import SwiftUI

/// Settings › Routine: the weekly blocks tasks are scheduled in, with the contexts each allows.
/// Read-only; the server owns the routine for now.
struct RoutineSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.routineBlocks.isEmpty {
            ContentUnavailableView(
                "No routine yet", systemImage: "calendar.day.timeline.left", description: Text("Sync with the server."))
        } else {
            Form {
                Section {
                    ForEach(model.routineBlocks) { block in
                        LabeledContent {
                            Text(RoutineText.allows(block))
                        } label: {
                            Text(block.name)
                            Text(RoutineText.when(block, calendar: model.calendar))
                        }
                    }
                } footer: {
                    Text(RoutineText.footnote(timeZone: model.userSettings?.timeZone))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}
