import FloridaKit
import SwiftUI

/// Server URL and API token. Save stores them in the keychain and starts a sync.
struct ServerSettingsForm: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = ""
    @State private var token = ""
    @State private var message: String?
    @State private var isLoaded = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $urlText, prompt: Text(Florida.defaultServerURL.absoluteString))
                    .autocorrectionDisabled()
                SecureField("API token", text: $token)
                HStack {
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Sync now") {
                        model.perform(.sync)
                    }
                    .disabled(model.syncClient == nil)
                    Spacer()
                    SyncStatusLabel()
                        .font(.caption)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            urlText = model.config?.baseURL.absoluteString ?? ""
            token = model.config?.token ?? ""
        }
    }

    private func save() {
        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = trimmedURL.isEmpty ? Florida.defaultServerURL.absoluteString : trimmedURL
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else {
            message = "Enter a full URL such as \(Florida.defaultServerURL.absoluteString)"
            return
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            message = "Enter the API token"
            return
        }
        do {
            try model.saveServerConfig(ServerConfig(baseURL: url, token: trimmedToken))
            message = nil
            model.statusMessage = "Server settings saved"
        } catch {
            message = "Could not save to the keychain: \(error.localizedDescription)"
        }
    }
}
