import SwiftUI

/// Fills the main window until a server token is saved.
struct SetupView: View {
    var body: some View {
        VStack(spacing: 20) {
            FloridaWordmark(height: 50)
                .padding(.bottom, 12)
            Text("Enter your server's URL and API token to start syncing. You can change them later with ⌘,")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ServerSettingsForm()
                .frame(maxWidth: 520)
                .frame(height: 220)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloridaStyle.paper)
    }
}
