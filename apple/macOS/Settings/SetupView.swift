import SwiftUI

/// Fills the main window until a server token is saved.
struct SetupView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Florida")
                .font(.largeTitle.weight(.semibold))
            Text("Enter your server's URL and API token to start syncing. You can change them later with ⌘,")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ServerSettingsForm()
                .frame(maxWidth: 520)
                .frame(height: 220)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
