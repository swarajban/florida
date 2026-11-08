import FloridaKit
import SwiftUI

/// Arrows, Today, the visible range's title, the view-mode picker and the tasks toggle.
struct CalendarHeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Spacer()

            Picker("View", selection: viewModeBinding) {
                ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Button {
                model.perform(.toggleTasks)
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle tasks (⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var viewModeBinding: Binding<CalendarViewMode> {
        Binding(
            get: { model.viewMode },
            set: { model.setViewMode($0) })
    }
}
