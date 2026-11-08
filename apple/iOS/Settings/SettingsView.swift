import FloridaKit
import SwiftUI

/// The Settings tab: server connection, sync controls and status, and the read-only list of
/// connected Google accounts and their calendars.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var token = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $serverURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API token", text: $token)
                    Button("Save and sync") {
                        save()
                    }
                    .disabled(parsedURL == nil || token.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Server")
                } footer: {
                    if model.needsSetup {
                        Text("Enter the sync server's URL and the API token it was deployed with.")
                    }
                }

                Section("Sync") {
                    Button {
                        model.requestSync()
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        model.runScheduler()
                    } label: {
                        Label("Run scheduler", systemImage: "calendar.badge.clock")
                    }
                    Button {
                        model.refreshGoogleCalendars()
                    } label: {
                        Label("Refresh Google calendars", systemImage: "arrow.clockwise.icloud")
                    }
                }
                .disabled(model.needsSetup || model.isSyncing)

                Section("Status") {
                    LabeledContent("Last sync") {
                        if model.isSyncing {
                            ProgressView()
                        } else if let lastSyncAt = model.lastSyncAt {
                            Text(lastSyncAt, style: .relative) + Text(" ago")
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Pending writes", value: "\(model.pendingWriteCount)")
                    if let storeError = model.storeError {
                        Label(storeError, systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.red)
                    }
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if model.accounts.isEmpty {
                    Section("Google accounts") {
                        Text("No Google accounts connected. Connect one on the server's web page, then refresh.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.accounts) { account in
                        Section {
                            ForEach(model.calendars.filter { $0.accountId == account.id }) { calendar in
                                CalendarRow(calendar: calendar)
                            }
                        } header: {
                            Text(account.email)
                        } footer: {
                            Text("Label: \(account.label)")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                guard !loaded else { return }
                loaded = true
                serverURL = (model.serverConfig?.baseURL ?? Florida.defaultServerURL).absoluteString
                token = model.serverConfig?.token ?? ""
            }
        }
    }

    /// The typed URL when it is an absolute http(s) URL.
    private var parsedURL: URL? {
        let text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    private func save() {
        guard let url = parsedURL else { return }
        model.saveServerConfig(ServerConfig(baseURL: url, token: token.trimmingCharacters(in: .whitespaces)))
    }
}

/// One Google calendar: color, name, whether its events are mirrored.
private struct CalendarRow: View {
    let calendar: CalendarInfo

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(calendar.color.flatMap(Color.init(hex:)) ?? .secondary)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.summary)
                Text(calendar.accessRole)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if calendar.selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            } else {
                Text("Hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
