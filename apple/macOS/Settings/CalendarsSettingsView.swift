import FloridaKit
import SwiftUI

/// Connected Google accounts with a toggle per calendar. A toggle flips the local flag at once
/// and tells the server in the background.
struct CalendarsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.accounts.isEmpty {
            ContentUnavailableView(
                "No Google accounts", systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Connect an account on the server, then sync."))
        } else {
            List {
                ForEach(model.accounts) { account in
                    Section {
                        ForEach(model.calendars.filter { $0.accountId == account.id }) { calendar in
                            CalendarToggleRow(calendar: calendar)
                        }
                    } header: {
                        HStack {
                            Text(account.email)
                            Text(account.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct CalendarToggleRow: View {
    @Environment(AppModel.self) private var model
    let calendar: CalendarInfo

    var body: some View {
        Toggle(isOn: isSelected) {
            HStack(spacing: 8) {
                Circle()
                    .fill(calendar.tint)
                    .frame(width: 10, height: 10)
                Text(calendar.summary)
                if calendar.accessRole == "reader" || calendar.accessRole == "freeBusyReader" {
                    Text("read-only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isSelected: Binding<Bool> {
        Binding(
            get: { calendar.selected },
            set: { model.setCalendarSelected(id: calendar.id, selected: $0) })
    }
}
