import FloridaKit
import SwiftUI

/// Connected Google accounts with independent visibility and scheduling controls.
struct CalendarsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.accounts.isEmpty {
            ContentUnavailableView(
                "No Google accounts", systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Connect an account on the server, then sync."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.accounts) { account in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(account.email)
                                    .accessibilityIdentifier("calendar-account-header-\(account.id)")
                                Text(account.label)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(model.calendars.filter { $0.accountId == account.id }) { calendar in
                                CalendarToggleRow(calendar: calendar)
                                Divider()
                            }
                            Text("Show calendar controls visibility only. Blocks scheduling keeps busy time unavailable to tasks, even when hidden.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(.background)
        }
    }
}

struct CalendarToggleRow: View {
    @Environment(AppModel.self) private var model
    let calendar: CalendarInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(calendar.tint)
                    .frame(width: 10, height: 10)
                Text(calendar.summary)
                    .accessibilityIdentifier("calendar-name-\(calendar.id)")
                if calendar.accessRole == "reader" || calendar.accessRole == "freeBusyReader" {
                    Text("read-only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityAddTraits(.isHeader)
            Toggle("Show calendar", isOn: isSelected)
                .accessibilityIdentifier("calendar-selected-\(calendar.id)")
            Toggle("Blocks scheduling", isOn: blocksScheduling)
                .accessibilityIdentifier("calendar-blocks-scheduling-\(calendar.id)")
        }
        .padding(.vertical, 4)
        .toggleStyle(.checkbox)
    }

    private var isSelected: Binding<Bool> {
        Binding(
            get: { calendar.selected },
            set: { model.setCalendarSelected(id: calendar.id, selected: $0) })
    }

    private var blocksScheduling: Binding<Bool> {
        Binding(
            get: { calendar.blocksScheduling },
            set: { model.setCalendarBlocksScheduling(id: calendar.id, blocksScheduling: $0) })
    }
}
