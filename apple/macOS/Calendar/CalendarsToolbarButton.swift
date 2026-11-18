import FloridaKit
import SwiftUI

struct CalendarsToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let status = model.calendarActivation.status(in: model.calendars)
        Button {
            model.run(.toggleCalendars)
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    if status != nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "calendar")
                    }
                }
                .frame(width: 16, height: 16)
                Text("Calendars")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canToggleCalendars)
        .help(status ?? "Toggle calendars (\(MacKeymap.default.shortcut(for: .toggleCalendars)))")
        .accessibilityLabel("Calendars")
        .accessibilityValue(status ?? "")
        .accessibilityIdentifier("calendar-visibility-button")
        .popover(isPresented: $model.isCalendarsPopoverOpen, arrowEdge: .bottom) {
            CalendarVisibilityChecklist()
                .onExitCommand { model.isCalendarsPopoverOpen = false }
        }
    }
}

private struct CalendarVisibilityChecklist: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let calendars = model.calendars.filter { $0.matchesSearch(query) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendars").font(.headline)
            TextField("Filter calendars", text: $query)
                .focused($searchFocused)
                .accessibilityIdentifier("calendar-visibility-search")
            if calendars.isEmpty {
                Text(model.calendars.isEmpty ? "No calendars connected" : "No matching calendars")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(calendars) { calendar in
                            row(calendar)
                        }
                    }
                }
                .frame(height: CGFloat(min(calendars.count, 9)) * 30)
            }
            Text("Changes what you see. Scheduling rules stay the same.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 330)
        .defaultFocus($searchFocused, true)
    }

    private func row(_ calendar: CalendarInfo) -> some View {
        let syncing = model.calendarActivation.syncingCalendarIds.contains(calendar.id)
        return Toggle(isOn: Binding(
            get: { model.calendarsById[calendar.id]?.selected ?? calendar.selected },
            set: { model.setCalendarSelected(id: calendar.id, selected: $0) }
        )) {
            HStack(spacing: 8) {
                Circle()
                    .fill(calendar.tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(calendar.summary).lineLimit(1)
                Spacer(minLength: 0)
                if syncing {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(syncing ? "\(calendar.summary), syncing" : calendar.summary)
        .accessibilityIdentifier("calendar-visibility-row-\(calendar.id)")
        .frame(height: 30)
    }
}
