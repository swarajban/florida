import FloridaKit
import SwiftUI

/// Arrows, Today, the visible range's title, the view-mode picker and the tasks toggle. When the
/// gym found no slot in the highlighted day's week, a line under them says so.
struct CalendarHeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            let missed = model.missedCommitments(inWeekOf: model.selectedDay)
            if !missed.isEmpty {
                Label(PlanText.missed(missed), systemImage: PlanText.commitmentSymbol)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityIdentifier("missed-commitments")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button {
                    model.page(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous")
                Button("Today") {
                    model.goToToday()
                }
                .help("Today (T)")
                Button {
                    model.page(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(model.viewTitle)
                .font(.title3.weight(.medium))
                .lineLimit(1)

            Spacer()

            Picker("View", selection: viewModeBinding) {
                ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)

            Button {
                model.perform(.toggleTasks)
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle tasks (⌘T)")
        }
    }

    private var viewModeBinding: Binding<CalendarViewMode> {
        Binding(
            get: { model.viewMode },
            set: { model.setViewMode($0) })
    }
}
