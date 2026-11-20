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
        @Bindable var model = model
        let calendars = model.calendars.filter { $0.matchesSearch(query) }
        let byAccount = Dictionary(grouping: calendars, by: \.accountId)
        let accounts = model.accounts.filter { byAccount[$0.id] != nil }
        let accountIDs = Set(accounts.map(\.id))
        let otherCalendars = calendars.filter { !accountIDs.contains($0.accountId) }
        let sectionCount = accounts.count + (otherCalendars.isEmpty ? 0 : 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Calendars").font(.headline)
                Spacer()
                Button("Done") { model.isCalendarsPopoverOpen = false }
                    .buttonStyle(.borderless)
            }
            Toggle("Tasks on Calendar", isOn: $model.showTasksOnCalendar)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("calendar-visibility-row-tasks")
            Divider()
            TextField("Filter calendars", text: $query)
                .focused($searchFocused)
                .accessibilityIdentifier("calendar-visibility-search")
                .onSubmit {
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let firstMatch = accounts.first.flatMap { byAccount[$0.id]?.first } ?? otherCalendars.first
                    if let firstMatch {
                        model.setCalendarSelected(id: firstMatch.id, selected: !firstMatch.selected)
                    }
                }
            if calendars.isEmpty {
                Text(model.calendars.isEmpty ? "No calendars connected" : "No matching calendars")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(accounts) { account in
                            section("\(account.label) · \(account.email)", calendars: byAccount[account.id] ?? [])
                        }
                        if !otherCalendars.isEmpty {
                            section("Other calendars", calendars: otherCalendars)
                        }
                    }
                }
                .frame(height: min(270, CGFloat(calendars.count * 30 + sectionCount * 26)))
            }
            Text("Changes what you see. Scheduling rules stay the same.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360)
        .defaultFocus($searchFocused, true)
    }

    @ViewBuilder
    private func section(_ title: String, calendars: [CalendarInfo]) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 26)
            .accessibilityAddTraits(.isHeader)
        ForEach(calendars) { calendar in
            row(calendar)
        }
    }

    private func row(_ calendar: CalendarInfo) -> some View {
        let syncing = model.calendarActivation.syncingCalendarIds.contains(calendar.id)
        let readOnly = calendar.accessRole == "reader" || calendar.accessRole == "freeBusyReader"
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
                if readOnly {
                    Text("read-only")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if syncing {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(calendar.summary + (readOnly ? ", read-only" : "") + (syncing ? ", syncing" : ""))
        .accessibilityIdentifier("calendar-visibility-row-\(calendar.id)")
        .frame(height: 30)
    }
}
