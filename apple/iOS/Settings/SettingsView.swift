import FloridaKit
import SwiftUI

/// The Settings tab: server connection, sync controls and status (with the refused and waiting
/// changes), the Delight switches, the connected Google accounts with a toggle per calendar,
/// and the app version.
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
                    if let storeError = model.storeError {
                        Label(storeError, systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.red)
                    }
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                SyncQueueSections()

                Section {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label {
                            LabeledContent("Categories", value: "\(model.categories.count)")
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                    NavigationLink {
                        SchedulesView()
                    } label: {
                        Label {
                            LabeledContent("Schedules", value: "\(model.schedules.count)")
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Categories group tasks (Engineering, Infosec, Finances…) and pick the schedule whose hours they follow. Add as many as you like.")
                }

                JoySettingsSection()

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
                            Text("Label: \(account.label). Calendars that are off are hidden from the agenda and ignored when scheduling.")
                        }
                    }
                }

                Section("About") {
                    FloridaWordmark()
                        .padding(.vertical, 8)
                    LabeledContent("Version", value: Self.appVersion)
                    if let serverConfig = model.serverConfig {
                        LabeledContent("Server", value: serverConfig.baseURL.host() ?? serverConfig.baseURL.absoluteString)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FloridaStyle.paper)
            .navigationTitle("Settings")
            .toolbarBackground(FloridaStyle.paper, for: .navigationBar)
            .toastOverlay()
            .onAppear {
                guard !loaded else { return }
                loaded = true
                serverURL = (model.serverConfig?.baseURL ?? Florida.defaultServerURL).absoluteString
                token = model.serverConfig?.token ?? ""
            }
        }
    }

    /// "1.0 (42)": the marketing version and the build number.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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

/// One Google calendar: color, name, and a toggle for whether its events are mirrored. The toggle
/// flips the local flag at once and tells the server in the background.
private struct CalendarRow: View {
    @Environment(AppModel.self) private var model
    let calendar: CalendarInfo

    var body: some View {
        Toggle(isOn: isSelected) {
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
            }
        }
        .disabled(model.needsSetup)
    }

    private var isSelected: Binding<Bool> {
        Binding(
            get: { calendar.selected },
            set: { model.setCalendarSelected(id: calendar.id, selected: $0) })
    }
}
